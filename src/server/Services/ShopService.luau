--!strict
-- The Armory: buying and equipping weapons. Only usable inside Haven.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local Net = require(ReplicatedStorage.Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local WeaponService = require(script.Parent.WeaponService)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local WorldService = require(script.Parent.WorldService)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type WeaponDef = Weapons.WeaponDef

export type ShopResult = {
	Success: boolean,
	Message: string,
}

local ShopService = {}

local limiter = RateLimiter.new(4, 6)

local function inHaven(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root ~= nil and root:IsA("BasePart") and Zones.IsSafeAt(root.Position)
end

local function equip(player: Player, def: WeaponDef)
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	if def.Slot == "Primary" then
		profile.Loadout.Primary = def.Id
	else
		profile.Loadout.Secondary = def.Id
	end
	WeaponService.RefreshLoadout(player)
	ProgressionService.Replicate(player)
end

local function purchase(player: Player, weaponId: any): ShopResult
	if not limiter:Allow(player) then
		return { Success = false, Message = "Slow down" }
	end
	local def = Weapons.Get(weaponId)
	local profile = DataService.GetProfile(player)
	if not def or not profile then
		return { Success = false, Message = "Unknown weapon" }
	end
	if profile.OwnedWeapons[def.Id] then
		return { Success = false, Message = "Already owned" }
	end
	if not inHaven(player) then
		return { Success = false, Message = "Visit the Armory in Haven" }
	end
	if profile.Level < def.LevelRequired then
		return { Success = false, Message = `Requires level {def.LevelRequired}` }
	end
	if not ProgressionService.SpendCredits(player, def.Price) then
		return { Success = false, Message = "Not enough credits" }
	end
	profile.OwnedWeapons[def.Id] = true
	equip(player, def)
	return { Success = true, Message = `Purchased {def.DisplayName}` }
end

local function equipRequest(player: Player, weaponId: any): ShopResult
	if not limiter:Allow(player) then
		return { Success = false, Message = "Slow down" }
	end
	local def = Weapons.Get(weaponId)
	local profile = DataService.GetProfile(player)
	if not def or not profile or not profile.OwnedWeapons[def.Id] then
		return { Success = false, Message = "You don't own that weapon" }
	end
	if not inHaven(player) then
		return { Success = false, Message = "Loadouts can only be changed in Haven" }
	end
	equip(player, def)
	return { Success = true, Message = `Equipped {def.DisplayName}` }
end

function ShopService.Init()
	Net.Function("ShopPurchase").OnServerInvoke = purchase
	Net.Function("ShopEquip").OnServerInvoke = equipRequest

	local openShop = Net.Event("OpenShop")
	WorldService.ArmoryRequested:Connect(function(player: Player)
		openShop:FireClient(player)
	end)
end

return ShopService
