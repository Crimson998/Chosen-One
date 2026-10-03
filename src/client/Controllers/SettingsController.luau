--!strict
-- The SETTINGS window (M, or the button in the inventory): mouse and aim
-- sensitivity sliders. Changes apply straight away and are saved to the
-- profile shortly after you let go.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Create = require(script.Parent.Parent.UI.Create)
local Net = require(ReplicatedStorage.Shared.Net)
local Settings = require(ReplicatedStorage.Shared.Config.Settings)
local State = require(script.Parent.Parent.State)
local Theme = require(script.Parent.Parent.UI.Theme)

type Option = Settings.Option

type Slider = {
	Option: Option,
	Track: TextButton,
	Fill: Frame,
	Knob: Frame,
	Value: TextLabel,
}

local SettingsController = {}

local MENU = "Settings"
local SAVE_DELAY = 0.6

local player = Players.LocalPlayer
local saveRemote = Net.Event("SaveSettings")

local gui: ScreenGui
local sliders: { Slider } = {}
local dragging: Slider? = nil
local isOpen = false
local adopted = false -- profile settings loaded
local dirty = false -- changed since the last save
local saveToken = 0

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

local function current(): Settings.Settings
	local settings = State.Settings
	if settings then
		return settings
	end
	local defaults = Settings.Default()
	State.Settings = defaults
	return defaults
end

local function valueOf(option: Option): number
	return (current() :: any)[option.Id] :: number
end

local function refresh()
	for _, slider in sliders do
		local option = slider.Option
		local value = valueOf(option)
		local alpha = math.clamp((value - option.Min) / (option.Max - option.Min), 0, 1)
		slider.Fill.Size = UDim2.fromScale(alpha, 1)
		slider.Knob.Position = UDim2.fromScale(alpha, 0.5)
		slider.Value.Text = string.format("%.2fx", value)
	end
end

local function save()
	if dirty then
		dirty = false
		saveRemote:FireServer(current())
	end
end

local function queueSave()
	dirty = true
	saveToken += 1
	local token = saveToken
	task.delay(SAVE_DELAY, function()
		if token == saveToken then
			save()
		end
	end)
end

local function setValue(option: Option, value: number)
	local clamped = Settings.Clamp(option, value)
	if valueOf(option) == clamped then
		return
	end
	(current() :: any)[option.Id] = clamped
	refresh()
	queueSave()
end

local function dragTo(slider: Slider, x: number)
	local track = slider.Track
	local alpha = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
	local option = slider.Option
	setValue(option, option.Min + alpha * (option.Max - option.Min))
end

local function isPointer(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function buildSlider(option: Option, index: number, window: Frame)
	local row: Frame = Create("Frame", {
		Position = UDim2.fromOffset(16, 60 + (index - 1) * 96),
		Size = UDim2.fromOffset(488, 88),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.4,
		Parent = window,
	}, { Create("UICorner", { CornerRadius = UDim.new(0, 6) }) })
	text({
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.fromOffset(300, 22),
		Font = Theme.FontHeavy,
		TextSize = 17,
		Text = option.Name,
		Parent = row,
	})
	local value = text({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 6),
		Size = UDim2.fromOffset(100, 22),
		Font = Theme.FontHeavy,
		TextSize = 17,
		TextColor3 = Theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
		Parent = row,
	})
	text({
		Position = UDim2.fromOffset(12, 28),
		Size = UDim2.fromOffset(464, 16),
		Font = Theme.FontBody,
		TextSize = 12,
		TextColor3 = Theme.Muted,
		Text = option.Description,
		Parent = row,
	})

	local minus = button({
		Position = UDim2.fromOffset(12, 52),
		Size = UDim2.fromOffset(28, 28),
		Text = "-",
		TextSize = 18,
		Parent = row,
	})
	local plus = button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 52),
		Size = UDim2.fromOffset(28, 28),
		Text = "+",
		TextSize = 18,
		Parent = row,
	})
	-- A tall invisible hit area around a thin bar, so it's easy to grab.
	local track: TextButton = Create("TextButton", {
		Position = UDim2.fromOffset(52, 52),
		Size = UDim2.new(1, -104, 0, 28),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Parent = row,
	})
	local bar: Frame = Create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, 8),
		BackgroundColor3 = Theme.Panel,
		Parent = track,
	}, { Create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	local fill: Frame = Create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Accent,
		Parent = bar,
	}, { Create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	local knob: Frame = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = Theme.Text,
		Parent = track,
	}, { Create("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local slider: Slider = { Option = option, Track = track, Fill = fill, Knob = knob, Value = value }
	table.insert(sliders, slider)

	track.InputBegan:Connect(function(input: InputObject)
		if isPointer(input) then
			dragging = slider
			dragTo(slider, input.Position.X)
		end
	end)
	minus.Activated:Connect(function()
		setValue(option, valueOf(option) - option.Step)
	end)
	plus.Activated:Connect(function()
		setValue(option, valueOf(option) + option.Step)
	end)
end

local function build()
	gui = Create("ScreenGui", {
		Name = "Settings",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		Enabled = false,
		DisplayOrder = 6,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local height = 60 + #Settings.Options * 96 + 52
	local window: Frame = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(520, height),
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
		Text = "SETTINGS",
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
		SettingsController.Close()
	end)

	for index, option in Settings.Options do
		buildSlider(option, index, window)
	end

	local reset = button({
		Position = UDim2.new(0, 16, 1, -44),
		Size = UDim2.fromOffset(180, 30),
		TextSize = 14,
		Text = "RESET TO DEFAULT",
		Parent = window,
	})
	reset.Activated:Connect(function()
		for _, option in Settings.Options do
			setValue(option, option.Default)
		end
	end)
	text({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 1, -44),
		Size = UDim2.fromOffset(290, 30),
		Font = Theme.FontBody,
		TextSize = 12,
		TextColor3 = Theme.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "Saved to your profile automatically",
		Parent = window,
	})
end

function SettingsController.Open()
	if isOpen then
		return
	end
	isOpen = true
	gui.Enabled = true
	State.SetMenuOpen(MENU, true)
	refresh()
end

function SettingsController.Close()
	if not isOpen then
		return
	end
	isOpen = false
	dragging = nil
	gui.Enabled = false
	State.SetMenuOpen(MENU, false)
	save()
end

function SettingsController.Toggle()
	if isOpen then
		SettingsController.Close()
	else
		SettingsController.Open()
	end
end

function SettingsController.Init()
	build()
	State.ProfileChanged:Connect(function(profile)
		-- Later profile updates carry whatever was saved last; the window
		-- is the source of truth once the first one has loaded.
		if adopted then
			return
		end
		adopted = true
		if not dirty then
			State.Settings = Settings.Sanitize(profile.Settings)
			refresh()
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.M then
			SettingsController.Toggle()
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local slider = dragging
		if
			slider
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			dragTo(slider, input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if isPointer(input) then
			dragging = nil
		end
	end)
end

function SettingsController.Start() end

return SettingsController
