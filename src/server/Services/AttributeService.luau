--!strict
-- Spending stat points (STR/AGI/VIT/DEX/LUK) and paid resets in Haven.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local DataService = require(script.Parent.DataService)
local Net = require(ReplicatedStorage.Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type AttributeName = Attributes.AttributeName

export type Result = {
	Success: boolean,
	Message: string,
}

local AttributeService = {}

local limiter = RateLimiter.new(10, 20)

-- Pushes derived stats onto the live character (max HP from VIT), keeping the
-- current health percentage.
function AttributeService.ApplyToCharacter(player: Player)
	local profile = DataService.GetProfile(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not profile or not humanoid or humanoid.Health <= 0 then
		return
	end
	local ratio = humanoid.Health / math.max(humanoid.MaxHealth, 1)
	local maxHealth = Attributes.MaxHealth(profile.Attributes.VIT)
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth * ratio
end

local function allocate(player: Player, name: any, amount: any): Result
	if not limiter:Allow(player) then
		return { Success = false, Message = "Slow down" }
	end
	local profile = DataService.GetProfile(player)
	if not profile or not Attributes.IsName(name) then
		return { Success = false, Message = "Unknown stat" }
	end
	local stat = name :: AttributeName
	local requested = if typeof(amount) == "number" and amount == amount then math.floor(amount) else 1
	requested = math.clamp(requested, 1, 50)

	local current = Attributes.Get(profile.Attributes, stat)
	local points = math.min(requested, profile.AttributePoints, Attributes.Max - current)
	if current >= Attributes.Max then
		return { Success = false, Message = `{stat} is already maxed` }
	end
	if points <= 0 then
		return { Success = false, Message = "No stat points left. Level up to earn more." }
	end

	Attributes.Set(profile.Attributes, stat, current + points)
	profile.AttributePoints -= points
	if stat == "VIT" then
		AttributeService.ApplyToCharacter(player)
	end
	ProgressionService.Replicate(player)
	return { Success = true, Message = `{stat} +{points}` }
end

local function reset(player: Player): Result
	if not limiter:Allow(player) then
		return { Success = false, Message = "Slow down" }
	end
	local profile = DataService.GetProfile(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not profile then
		return { Success = false, Message = "Profile not loaded" }
	end
	if not root or not root:IsA("BasePart") or not Zones.IsSafeAt(root.Position) then
		return { Success = false, Message = "Stats can only be reset in Haven" }
	end
	local earned = Attributes.TotalPoints(profile.Level)
	if profile.AttributePoints >= earned then
		return { Success = false, Message = "No points to reset" }
	end
	local cost = Attributes.RespecCost(profile.Level)
	if not ProgressionService.SpendCredits(player, cost) then
		return { Success = false, Message = `Resetting costs ¢{cost}` }
	end
	profile.Attributes = Attributes.Default()
	profile.AttributePoints = earned
	AttributeService.ApplyToCharacter(player)
	ProgressionService.Replicate(player)
	return { Success = true, Message = `Stats reset (¢{cost})` }
end

function AttributeService.Init()
	Net.Function("AllocateAttribute").OnServerInvoke = allocate
	Net.Function("ResetAttributes").OnServerInvoke = reset
end

return AttributeService
