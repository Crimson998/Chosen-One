--!strict
-- Cross-server leaderboard of lifetime XP, shown on the board in Haven.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local Format = require(ReplicatedStorage.Shared.Format)
local Progression = require(ReplicatedStorage.Shared.Config.Progression)
local WorldService = require(script.Parent.WorldService)

local LeaderboardService = {}

local STORE_NAME = "ChosenOne_TotalXP_v1"
local UPDATE_INTERVAL = 120
local ROW_COUNT = 10

type Entry = {
	Name: string,
	TotalXP: number,
}

local nameCache: { [number]: string } = {}

local function resolveName(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = if ok and typeof(name) == "string" then name else `User {userId}`
	nameCache[userId] = resolved
	return resolved
end

local function render(entries: { Entry }, message: string?)
	local rows = WorldService.GetLeaderboardRows()
	if not rows then
		return
	end
	for _, child in rows:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	local function row(order: number, text: string, color: Color3)
		local label = Instance.new("TextLabel")
		label.LayoutOrder = order
		label.Size = UDim2.fromScale(1, 1 / ROW_COUNT)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = color
		label.Text = text
		label.Parent = rows
	end

	if message then
		row(1, message, Color3.fromRGB(200, 200, 200))
		return
	end
	for rank, entry in entries do
		local color = if rank == 1
			then Color3.fromRGB(255, 215, 80)
			elseif rank <= 3 then Color3.fromRGB(220, 225, 235)
			else Color3.fromRGB(170, 175, 185)
		local level = Progression.LevelFromTotalXP(entry.TotalXP)
		row(rank, `#{rank}   {entry.Name}   —   Lv {level}   ({Format.Commas(entry.TotalXP)} XP)`, color)
	end
	if #entries == 0 then
		row(1, "No operatives ranked yet. Be the first.", Color3.fromRGB(200, 200, 200))
	end
end

local function update(store: OrderedDataStore)
	for _, player in Players:GetPlayers() do
		local profile = DataService.GetProfile(player)
		if profile and profile.Stats.TotalXP > 0 then
			nameCache[player.UserId] = player.Name
			local ok, err = pcall(function()
				store:SetAsync(tostring(player.UserId), math.floor(profile.Stats.TotalXP))
			end)
			if not ok then
				warn(`[LeaderboardService] Failed to submit {player.Name}: {err}`)
			end
		end
	end

	local ok, result = pcall(function()
		return store:GetSortedAsync(false, ROW_COUNT):GetCurrentPage()
	end)
	if not ok then
		warn(`[LeaderboardService] Failed to read leaderboard: {result}`)
		return
	end

	local entries: { Entry } = {}
	for _, item in result :: { any } do
		local userId = tonumber(item.key)
		if userId then
			table.insert(entries, { Name = resolveName(userId), TotalXP = item.value })
		end
	end
	render(entries)
end

function LeaderboardService.Init() end

function LeaderboardService.Start()
	if DataService.IsMock() then
		render({}, "Leaderboard offline (enable Studio API access)")
		return
	end
	render({}, "Loading…")
	local store = DataStoreService:GetOrderedDataStore(STORE_NAME)
	task.spawn(function()
		task.wait(10)
		while true do
			update(store)
			task.wait(UPDATE_INTERVAL)
		end
	end)
end

return LeaderboardService
