--!strict
-- Hold P for the server scoreboard (replaces the core player list).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Create = require(script.Parent.Parent.UI.Create)
local Theme = require(script.Parent.Parent.UI.Theme)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

local ScoreboardController = {}

local player = Players.LocalPlayer
local gui: ScreenGui
local rows: Frame
local visible = false

type Row = {
	Player: Player,
	Level: number,
	Kills: number,
	Deaths: number,
	Zone: string,
}

local COLUMNS = {
	{ Title = "OPERATIVE", Width = 0.4 },
	{ Title = "ZONE", Width = 0.24 },
	{ Title = "LEVEL", Width = 0.12 },
	{ Title = "KILLS", Width = 0.12 },
	{ Title = "DEATHS", Width = 0.12 },
}

local function stat(target: Player, name: string): number
	local leaderstats = target:FindFirstChild("leaderstats")
	local value = leaderstats and leaderstats:FindFirstChild(name)
	if value and value:IsA("IntValue") then
		return value.Value
	end
	return 0
end

local function rowFrame(order: number, values: { string }, color: Color3, font: Enum.Font): Frame
	local frame: Frame = Create("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = if order % 2 == 0 then 0.6 else 1,
		BorderSizePixel = 0,
		Parent = rows,
	})
	local x = 0
	for index, column in COLUMNS do
		Create("TextLabel", {
			Position = UDim2.new(x, 10, 0, 0),
			Size = UDim2.new(column.Width, -10, 1, 0),
			BackgroundTransparency = 1,
			Font = font,
			TextSize = 15,
			TextColor3 = color,
			TextXAlignment = if index == 1 then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = values[index],
			Parent = frame,
		})
		x += column.Width
	end
	return frame
end

local function refresh()
	for _, child in rows:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local titles = {}
	for _, column in COLUMNS do
		table.insert(titles, column.Title)
	end
	rowFrame(0, titles, Theme.Muted, Theme.FontHeavy)

	local entries: { Row } = {}
	for _, target in Players:GetPlayers() do
		local character = target.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local zone = if root and root:IsA("BasePart") then Zones.GetZoneAt(root.Position) else nil
		table.insert(entries, {
			Player = target,
			Level = stat(target, "Level"),
			Kills = stat(target, "Kills"),
			Deaths = stat(target, "Deaths"),
			Zone = if zone then zone.DisplayName else "—",
		})
	end
	table.sort(entries, function(a: Row, b: Row)
		if a.Level ~= b.Level then
			return a.Level > b.Level
		end
		return a.Kills > b.Kills
	end)
	for index, entry in entries do
		rowFrame(index, {
			entry.Player.DisplayName,
			entry.Zone,
			tostring(entry.Level),
			tostring(entry.Kills),
			tostring(entry.Deaths),
		}, if entry.Player == player then Theme.Accent else Theme.Text, Theme.Font)
	end
end

function ScoreboardController.Init()
	gui = Create("ScreenGui", {
		Name = "Scoreboard",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		Enabled = false,
		DisplayOrder = 4,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local window: Frame = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 90),
		Size = UDim2.fromOffset(640, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.15,
		Parent = gui,
	}, {
		Create("UICorner", { CornerRadius = UDim.new(0, 8) }),
		Create("UIPadding", {
			PaddingTop = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
		}),
	})
	rows = Create("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = window,
	}, {
		Create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.P then
			visible = true
			gui.Enabled = true
			refresh()
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.P then
			visible = false
			gui.Enabled = false
		end
	end)
end

function ScoreboardController.Start()
	task.spawn(function()
		while true do
			task.wait(1)
			if visible then
				refresh()
			end
		end
	end)
end

return ScoreboardController
