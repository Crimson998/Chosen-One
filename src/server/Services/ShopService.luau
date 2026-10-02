--!strict
-- The Armory: buy weapons, gear and supplies with credits. Purchases go into
-- your inventory (equip them from there). Only usable inside Haven; selling
-- happens from the inventory, also in Haven.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local Items = require(ReplicatedStorage.Shared.Config.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldService = require(script.Parent.WorldService)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type ActionResult = Types.ActionResult

local ShopService = {}

local MAX_BATCH = 20

local limiter = RateLimiter.new(4, 6)

local function inHaven(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root ~= nil and root:IsA("BasePart") and Zones.IsSafeAt(root.Position)
end

local function purchase(player: Player, itemId: any, count: any): ActionResult
	if not limiter:Allow(player) then
		return { Success = false, Message = "Slow down" }
	end
	local def = Items.Get(itemId)
	local profile = DataService.GetProfile(player)
	if not def or not profile then
		return { Success = false, Message = "Unknown item" }
	end
	local price = def.BuyPrice
	if not price then
		return { Success = false, Message = `{def.Name} can only be found as loot` }
	end
	if not inHaven(player) then
		return { Success = false, Message = "Visit the Armory in Haven" }
	end
	if profile.Level < def.LevelRequired then
		return { Success = false, Message = `Requires level {def.LevelRequired}` }
	end

	local requested = if typeof(count) == "number" and count == count then math.floor(count) else 1
	local amount = math.clamp(requested, 1, if def.MaxStack > 1 then MAX_BATCH else 1)
	if InventoryService.SpaceFor(player, def.Id, amount) < amount then
		return { Success = false, Message = "Not enough inventory space" }
	end
	if not ProgressionService.SpendCredits(player, price * amount) then
		return { Success = false, Message = "Not enough credits" }
	end
	InventoryService.AddItem(player, def.Id, amount, "Common")
	local suffix = if amount > 1 then ` x{amount}` else ""
	return { Success = true, Message = `Bought {def.Name}{suffix}. Equip it from your inventory (I).` }
end

function ShopService.Init()
	Net.Function("ShopPurchase").OnServerInvoke = purchase

	local openShop = Net.Event("OpenShop")
	WorldService.ArmoryRequested:Connect(function(player: Player)
		openShop:FireClient(player)
	end)
end

return ShopService
