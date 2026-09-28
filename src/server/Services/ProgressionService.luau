--!strict
-- XP, levels, credits, stats and leaderstats. Owns replication of the
-- profile to its player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local Net = require(ReplicatedStorage.Shared.Net)
local Progression = require(ReplicatedStorage.Shared.Config.Progression)
local Types = require(ReplicatedStorage.Shared.Types)

type Profile = Types.Profile
type Notification = Types.Notification

local ProgressionService = {}

local profileUpdate = Net.Event("ProfileUpdate")
local notify = Net.Event("Notify")

local pendingReplication: { [Player]: boolean } = {}

function ProgressionService.Notify(player: Player, notification: Notification)
	notify:FireClient(player, notification)
end

function ProgressionService.NotifyAll(notification: Notification)
	notify:FireAllClients(notification)
end

-- Sends the profile to its owner at the end of the frame. Multiple changes in
-- one frame collapse into a single update.
function ProgressionService.Replicate(player: Player)
	if pendingReplication[player] then
		return
	end
	pendingReplication[player] = true
	task.defer(function()
		pendingReplication[player] = nil
		local profile = DataService.GetProfile(player)
		if profile and player.Parent then
			profileUpdate:FireClient(player, profile)
		end
	end)
end

local function setLeaderstat(player: Player, name: string, value: number)
	local leaderstats = player:FindFirstChild("leaderstats")
	local stat = leaderstats and leaderstats:FindFirstChild(name)
	if stat and stat:IsA("IntValue") then
		stat.Value = value
	end
end

local function refreshLeaderstats(player: Player, profile: Profile)
	setLeaderstat(player, "Level", profile.Level)
	setLeaderstat(player, "Kills", profile.Stats.Kills)
	setLeaderstat(player, "Deaths", profile.Stats.Deaths)
	player:SetAttribute("Level", profile.Level)
end

local function createLeaderstats(player: Player, profile: Profile)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	for _, name in { "Level", "Kills", "Deaths" } do
		local value = Instance.new("IntValue")
		value.Name = name
		value.Parent = folder
	end
	folder.Parent = player
	refreshLeaderstats(player, profile)
end

function ProgressionService.AwardXP(player: Player, amount: number, reason: string?)
	local profile = DataService.GetProfile(player)
	if not profile or amount <= 0 then
		return
	end
	amount = math.floor(amount)
	profile.Stats.TotalXP += amount
	if profile.Level < Progression.MaxLevel then
		profile.XP += amount
	end

	while profile.Level < Progression.MaxLevel and profile.XP >= Progression.XPForLevel(profile.Level) do
		profile.XP -= Progression.XPForLevel(profile.Level)
		profile.Level += 1
		local bonus = Progression.LevelUpCredits(profile.Level)
		profile.Credits += bonus
		ProgressionService.Notify(player, {
			Kind = "LevelUp",
			Text = `LEVEL {profile.Level}`,
			Amount = bonus,
		})
	end
	if profile.Level >= Progression.MaxLevel then
		profile.XP = 0
	end

	ProgressionService.Notify(player, {
		Kind = "XP",
		Text = reason or "",
		Amount = amount,
	})
	refreshLeaderstats(player, profile)
	ProgressionService.Replicate(player)
end

function ProgressionService.AwardCredits(player: Player, amount: number)
	local profile = DataService.GetProfile(player)
	if not profile or amount <= 0 then
		return
	end
	profile.Credits += math.floor(amount)
	ProgressionService.Notify(player, { Kind = "Credits", Text = "", Amount = math.floor(amount) })
	ProgressionService.Replicate(player)
end

-- Returns false (and changes nothing) if the player can't afford it.
function ProgressionService.SpendCredits(player: Player, amount: number): boolean
	local profile = DataService.GetProfile(player)
	if not profile or amount < 0 or profile.Credits < amount then
		return false
	end
	profile.Credits -= amount
	ProgressionService.Replicate(player)
	return true
end

function ProgressionService.AddStat(player: Player, stat: string, amount: number)
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	local stats = profile.Stats :: any
	if typeof(stats[stat]) ~= "number" then
		warn(`[ProgressionService] Unknown stat "{stat}"`)
		return
	end
	stats[stat] += amount
	if stat == "Kills" or stat == "Deaths" then
		refreshLeaderstats(player, profile)
		ProgressionService.Replicate(player)
	end
end

function ProgressionService.GetLevel(player: Player): number
	local profile = DataService.GetProfile(player)
	return if profile then profile.Level else 1
end

function ProgressionService.Init()
	DataService.ProfileLoaded:Connect(function(player: Player, profile: Profile)
		createLeaderstats(player, profile)
		ProgressionService.Replicate(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		pendingReplication[player] = nil
	end)

	Net.Function("GetProfile").OnServerInvoke = function(player: Player)
		return DataService.WaitForProfile(player, 30)
	end
end

return ProgressionService
