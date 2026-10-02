--!strict
-- Server-side inventory: adding and removing items, equipping gear anywhere,
-- selling in Haven and dropping items on the ground (which is also how
-- players trade).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local Inventory = require(ReplicatedStorage.Shared.Inventory)
local Items = require(ReplicatedStorage.Shared.Config.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponService = require(script.Parent.WeaponService)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type Profile = Types.Profile
type ItemInstance = Types.ItemInstance
type ActionResult = Types.ActionResult
type ItemDef = Items.ItemDef

local InventoryService = {}

-- Fired when a player drops items: (player: Player, item: ItemInstance, position: Vector3)
InventoryService.Dropped = Signal.new()

local limiter = RateLimiter.new(8, 12)

local function fail(message: string): ActionResult
	return { Success = false, Message = message }
end

local function succeed(message: string): ActionResult
	return { Success = true, Message = message }
end

local function newUid(profile: Profile): string
	local uid = `i{profile.NextItemId}`
	profile.NextItemId += 1
	return uid
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- How many of `count` units of an item would fit right now.
function InventoryService.SpaceFor(player: Player, itemId: string, count: number): number
	local profile = DataService.GetProfile(player)
	local def = Items.Get(itemId)
	if not profile or not def then
		return 0
	end
	local free = Inventory.MaxSlots - #profile.Inventory
	if def.MaxStack == 1 then
		return math.max(0, math.min(count, free))
	end
	local room = math.max(0, free) * def.MaxStack
	for _, item in profile.Inventory do
		if item.Id == def.Id then
			room += def.MaxStack - item.Count
		end
	end
	return math.min(count, room)
end

-- Adds items, topping up existing stacks first. Returns how many fit.
function InventoryService.AddItem(player: Player, itemId: string, count: number, rarity: string?): number
	local profile = DataService.GetProfile(player)
	local def = Items.Get(itemId)
	if not profile or not def or count <= 0 then
		return 0
	end
	local remaining = math.floor(count)
	if def.MaxStack > 1 then
		for _, item in profile.Inventory do
			if remaining <= 0 then
				break
			end
			if item.Id == def.Id and item.Count < def.MaxStack then
				local add = math.min(remaining, def.MaxStack - item.Count)
				item.Count += add
				remaining -= add
			end
		end
	end
	local itemRarity: Items.Rarity = if def.MaxStack == 1 and Items.IsRarity(rarity) then rarity :: any else "Common"
	while remaining > 0 and #profile.Inventory < Inventory.MaxSlots do
		local add = math.min(remaining, def.MaxStack)
		table.insert(profile.Inventory, { Uid = newUid(profile), Id = def.Id, Count = add, Rarity = itemRarity })
		remaining -= add
	end
	local added = math.floor(count) - remaining
	if added > 0 then
		ProgressionService.Replicate(player)
	end
	return added
end

-- Removes up to `count` units from one entry. Returns what was removed.
function InventoryService.RemoveUid(player: Player, uid: string, count: number): ItemInstance?
	local profile = DataService.GetProfile(player)
	if not profile then
		return nil
	end
	local index = Inventory.IndexOf(profile, uid)
	if not index then
		return nil
	end
	local item = profile.Inventory[index]
	local taken = math.clamp(math.floor(count), 1, item.Count)
	item.Count -= taken
	if item.Count <= 0 then
		table.remove(profile.Inventory, index)
	end
	ProgressionService.Replicate(player)
	return { Uid = item.Uid, Id = item.Id, Count = taken, Rarity = item.Rarity }
end

-- Consumes `count` of an item across stacks; changes nothing if short.
function InventoryService.ConsumeById(player: Player, itemId: string, count: number): boolean
	local profile = DataService.GetProfile(player)
	if not profile or Inventory.Count(profile, itemId) < count then
		return false
	end
	local remaining = count
	for index = #profile.Inventory, 1, -1 do
		local item = profile.Inventory[index]
		if remaining > 0 and item.Id == itemId and not Inventory.SlotOf(profile, item.Uid) then
			local take = math.min(remaining, item.Count)
			item.Count -= take
			remaining -= take
			if item.Count <= 0 then
				table.remove(profile.Inventory, index)
			end
		end
	end
	ProgressionService.Replicate(player)
	return true
end

-- Takes a random unequipped item (half of a stack) for the PvP death penalty.
function InventoryService.TakeRandomUnequipped(player: Player): ItemInstance?
	local profile = DataService.GetProfile(player)
	if not profile then
		return nil
	end
	local candidates: { ItemInstance } = {}
	for _, item in profile.Inventory do
		if not Inventory.SlotOf(profile, item.Uid) then
			table.insert(candidates, item)
		end
	end
	if #candidates == 0 then
		return nil
	end
	local item = candidates[math.random(1, #candidates)]
	return InventoryService.RemoveUid(player, item.Uid, math.ceil(item.Count / 2))
end

local function equip(player: Player, profile: Profile, item: ItemInstance, def: ItemDef): ActionResult
	if profile.Level < def.LevelRequired then
		return fail(`{def.Name} requires level {def.LevelRequired}`)
	end
	local loadout = profile.Loadout :: any
	if def.Category == "Weapon" then
		local weapon = Weapons.Get(def.WeaponId)
		if not weapon then
			return fail("Unknown weapon")
		end
		if loadout[weapon.Slot] == item.Uid then
			return fail("Already equipped")
		end
		loadout[weapon.Slot] = item.Uid
		WeaponService.EquipFromInventory(player, weapon.Slot)
	elseif def.Category == "Armor" or def.Category == "Gadget" then
		if loadout[def.Category] == item.Uid then
			return fail("Already equipped")
		end
		loadout[def.Category] = item.Uid
	else
		return fail("That can't be equipped")
	end
	ProgressionService.Replicate(player)
	return succeed(`Equipped {def.Name}`)
end

local function onAction(player: Player, action: any, uid: any): ActionResult
	if not limiter:Allow(player) then
		return fail("Slow down")
	end
	local profile = DataService.GetProfile(player)
	if not profile or typeof(uid) ~= "string" then
		return fail("Item not found")
	end
	local item = Inventory.Find(profile, uid)
	local def = if item then Items.Get(item.Id) else nil
	if not item or not def then
		return fail("Item not found")
	end

	if action == "Equip" then
		return equip(player, profile, item, def)
	elseif action == "Unequip" then
		local slot = Inventory.SlotOf(profile, uid)
		if slot ~= "Armor" and slot ~= "Gadget" then
			return fail("Weapons can only be swapped, not removed")
		end
		(profile.Loadout :: any)[slot] = nil
		ProgressionService.Replicate(player)
		return succeed(`Unequipped {def.Name}`)
	end

	-- Selling and dropping never touch equipped gear.
	if Inventory.SlotOf(profile, uid) then
		return fail("Unequip it first")
	end
	if action == "Sell" then
		local root = rootOf(player)
		if not root or not Zones.IsSafeAt(root.Position) then
			return fail("Traders only buy in Haven")
		end
		local price = Items.SellPrice(def, item.Rarity, item.Count)
		local count = item.Count
		InventoryService.RemoveUid(player, uid, count)
		ProgressionService.AwardCredits(player, price)
		return succeed(`Sold {def.Name}{if count > 1 then ` x{count}` else ""} for ¢{price}`)
	elseif action == "Drop" then
		local root = rootOf(player)
		if not root then
			return fail("You can't do that right now")
		end
		local removed = InventoryService.RemoveUid(player, uid, item.Count)
		if removed then
			InventoryService.Dropped:Fire(player, removed, root.Position + root.CFrame.LookVector * 3)
		end
		return succeed(`Dropped {def.Name}`)
	end
	return fail("Unknown action")
end

function InventoryService.Init()
	Net.Function("InventoryAction").OnServerInvoke = onAction
end

return InventoryService
