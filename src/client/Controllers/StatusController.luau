--!strict
-- The STATUS window (C): spend stat points on STR/AGI/VIT/DEX/LUK, see what
-- each stat does to your character, and reset them in Haven for credits.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local Create = require(script.Parent.Parent.UI.Create)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local State = require(script.Parent.Parent.State)
local Theme = require(script.Parent.Parent.UI.Theme)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

type Result = {
	Success: boolean,
	Message: string,
}

type Row = {
	Value: TextLabel,
	Plus: TextButton,
	PlusFive: TextButton,
}

local StatusController = {}

local MENU = "Status"

local player = Players.LocalPlayer
local allocateRemote = Net.Function("AllocateAttribute")
local resetRemote = Net.Function("ResetAttributes")

local gui: ScreenGui
local header: TextLabel
local pointsLabel: TextLabel
local derivedLabel: TextLabel
local messageLabel: TextLabel
local resetButton: TextButton
local rows: { [string]: Row } = {}
local isOpen = false
local busy = false

local function text(props: { [string]: any }): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		TextColor3 = Theme.Text,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for key, value in props do
		defaults[key] = value
	end
	return Create("TextLabel", defaults)
end

local function button(props: { [string]: any }): TextButton
	local defaults: { [string]: any } = {
		BackgroundColor3 = Theme.PanelLight,
		Font = Theme.FontHeavy,
		TextColor3 = Theme.Text,
		TextSize = 16,
		AutoButtonColor = true,
	}
	for key, value in props do
		defaults[key] = value
	end
	return Create("TextButton", defaults, { Create("UICorner", { CornerRadius = UDim.new(0, 6) }) })
end

local function percent(multiplier: number): string
	local value = math.floor((multiplier - 1) * 100 + 0.5)
	return if value >= 0 then `+{value}%` else `{value}%`
end

local function refresh()
	local profile = State.Profile
	if not isOpen or not profile then
		return
	end
	local attributes = profile.Attributes
	header.Text = `{player.DisplayName}   •   LV {profile.Level}`
	pointsLabel.Text = `{profile.AttributePoints} point{if profile.AttributePoints == 1 then "" else "s"} to spend`
	pointsLabel.TextColor3 = if profile.AttributePoints > 0 then Theme.XP else Theme.Muted

	for _, info in Attributes.List do
		local row = rows[info.Id]
		local value = Attributes.Get(attributes, info.Id)
		row.Value.Text = tostring(value)
		local canSpend = profile.AttributePoints > 0 and value < Attributes.Max
		row.Plus.Visible = canSpend
		row.PlusFive.Visible = canSpend and profile.AttributePoints >= 5
	end

	local carried = Weapons.LoadoutWeight(profile.Loadout.Primary, profile.Loadout.Secondary)
	local capacity = Attributes.CarryCapacity(attributes.STR)
	local lines = {
		`Max HP  {Attributes.MaxHealth(attributes.VIT)}`,
		`Move speed  {percent(Attributes.SpeedMultiplier(attributes.AGI))}`,
		`Bullet circle  {percent(Attributes.SpreadMultiplier(attributes.DEX))}   •   Reload time  {percent(
			Attributes.ReloadMultiplier(attributes.DEX)
		)}`,
		`Carry  {string.format("%.1f", carried)} / {string.format("%.1f", capacity)} kg{if carried > capacity
			then "  (OVERWEIGHT)"
			else ""}`,
		`Critical chance  {math.floor(Attributes.CritChance(attributes.LUK) * 1000 + 0.5) / 10}%   •   Credits  {percent(
			Attributes.LootMultiplier(attributes.LUK)
		)}`,
	}
	derivedLabel.Text = table.concat(lines, "\n")
	resetButton.Text = `RESET  •  ¢ {Format.Commas(Attributes.RespecCost(profile.Level))}`
end

local function run(action: () -> Result)
	if busy then
		return
	end
	busy = true
	task.spawn(function()
		local ok, result = pcall(action)
		busy = false
		if not ok or typeof(result) ~= "table" then
			messageLabel.Text = "Couldn't reach the server"
			messageLabel.TextColor3 = Theme.Bad
			return
		end
		messageLabel.Text = result.Message
		messageLabel.TextColor3 = if result.Success then Theme.Good else Theme.Bad
		refresh()
	end)
end

local function build()
	gui = Create("ScreenGui", {
		Name = "Status",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		Enabled = false,
		DisplayOrder = 5,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local window: Frame = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(560, 470),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		Parent = gui,
	}, {
		Create("UICorner", { CornerRadius = UDim.new(0, 10) }),
		Create("UIStroke", { Color = Theme.Accent, Transparency = 0.5, Thickness = 1 }),
	})

	text({
		Position = UDim2.fromOffset(20, 12),
		Size = UDim2.fromOffset(200, 32),
		Font = Theme.FontHeavy,
		TextSize = 28,
		TextColor3 = Theme.Accent,
		Text = "STATUS",
		Parent = window,
	})
	header = text({
		Position = UDim2.fromOffset(170, 18),
		Size = UDim2.fromOffset(300, 22),
		TextSize = 16,
		TextColor3 = Theme.Muted,
		Text = "",
		Parent = window,
	})
	-- Modal releases the first-person mouse lock while the window is open.
	local close = button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 12),
		Size = UDim2.fromOffset(36, 32),
		Text = "X",
		Modal = true,
		Parent = window,
	})
	close.Activated:Connect(function()
		StatusController.Close()
	end)

	pointsLabel = text({
		Position = UDim2.fromOffset(20, 52),
		Size = UDim2.fromOffset(520, 22),
		Font = Theme.FontHeavy,
		TextSize = 18,
		Text = "",
		Parent = window,
	})

	for index, info in Attributes.List do
		local y = 82 + (index - 1) * 52
		local rowFrame: Frame = Create("Frame", {
			Position = UDim2.fromOffset(16, y),
			Size = UDim2.fromOffset(528, 46),
			BackgroundColor3 = Theme.PanelLight,
			BackgroundTransparency = 0.4,
			Parent = window,
		}, { Create("UICorner", { CornerRadius = UDim.new(0, 6) }) })
		text({
			Position = UDim2.fromOffset(12, 4),
			Size = UDim2.fromOffset(60, 22),
			Font = Theme.FontHeavy,
			TextSize = 20,
			TextColor3 = Theme.Accent,
			Text = info.Id,
			Parent = rowFrame,
		})
		text({
			Position = UDim2.fromOffset(12, 26),
			Size = UDim2.fromOffset(340, 16),
			Font = Theme.FontBody,
			TextSize = 12,
			TextColor3 = Theme.Muted,
			Text = `{info.Name}: {info.Description}`,
			Parent = rowFrame,
		})
		local value = text({
			Position = UDim2.fromOffset(360, 0),
			Size = UDim2.fromOffset(60, 46),
			Font = Theme.FontHeavy,
			TextSize = 24,
			TextXAlignment = Enum.TextXAlignment.Center,
			Text = "5",
			Parent = rowFrame,
		})
		local plus = button({
			Position = UDim2.fromOffset(426, 8),
			Size = UDim2.fromOffset(40, 30),
			BackgroundColor3 = Theme.Good,
			Text = "+1",
			Parent = rowFrame,
		})
		local plusFive = button({
			Position = UDim2.fromOffset(472, 8),
			Size = UDim2.fromOffset(46, 30),
			BackgroundColor3 = Theme.Good,
			Text = "+5",
			Parent = rowFrame,
		})
		plus.Activated:Connect(function()
			run(function(): Result
				return allocateRemote:InvokeServer(info.Id, 1)
			end)
		end)
		plusFive.Activated:Connect(function()
			run(function(): Result
				return allocateRemote:InvokeServer(info.Id, 5)
			end)
		end)
		rows[info.Id] = { Value = value, Plus = plus, PlusFive = plusFive }
	end

	derivedLabel = text({
		Position = UDim2.fromOffset(20, 346),
		Size = UDim2.fromOffset(520, 80),
		Font = Theme.FontBody,
		TextSize = 13,
		TextColor3 = Theme.Text,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = window,
	})
	resetButton = button({
		Position = UDim2.fromOffset(20, 428),
		Size = UDim2.fromOffset(200, 30),
		BackgroundColor3 = Theme.PanelLight,
		TextSize = 14,
		Text = "RESET",
		Parent = window,
	})
	resetButton.Activated:Connect(function()
		run(function(): Result
			return resetRemote:InvokeServer()
		end)
	end)
	messageLabel = text({
		Position = UDim2.fromOffset(230, 428),
		Size = UDim2.fromOffset(310, 30),
		TextSize = 14,
		Text = "",
		Parent = window,
	})
end

function StatusController.Open()
	if isOpen then
		return
	end
	isOpen = true
	messageLabel.Text = ""
	gui.Enabled = true
	State.SetMenuOpen(MENU, true)
	refresh()
end

function StatusController.Close()
	if not isOpen then
		return
	end
	isOpen = false
	gui.Enabled = false
	State.SetMenuOpen(MENU, false)
end

function StatusController.Init()
	build()
	State.ProfileChanged:Connect(refresh)
	Net.Event("Died").OnClientEvent:Connect(StatusController.Close)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.KeyCode ~= Enum.KeyCode.C then
			return
		end
		if isOpen then
			StatusController.Close()
		else
			StatusController.Open()
		end
	end)
end

function StatusController.Start() end

return StatusController
