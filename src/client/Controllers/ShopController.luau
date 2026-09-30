--!strict
-- The Armory window: browse every weapon, buy with credits, equip owned
-- guns. Opens from the Armory counter prompt or the B key inside Haven.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local Audio = require(ReplicatedStorage.Shared.Audio)
local Create = require(script.Parent.Parent.UI.Create)
local Format = require(ReplicatedStorage.Shared.Format)
local HUDController = require(script.Parent.HUDController)
local Net = require(ReplicatedStorage.Shared.Net)
local State = require(script.Parent.Parent.State)
local Theme = require(script.Parent.Parent.UI.Theme)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

type WeaponDef = Weapons.WeaponDef

type StatSpec = {
	Name: string,
	Value: (WeaponDef) -> number,
}

type ShopResult = {
	Success: boolean,
	Message: string,
}

local ShopController = {}

local STATS: { StatSpec } = {
	{
		Name = "Damage",
		Value = function(def)
			return def.Damage * def.Pellets / 120
		end,
	},
	{
		Name = "Fire Rate",
		Value = function(def)
			return def.RPM / 1000
		end,
	},
	{
		Name = "Range",
		Value = function(def)
			return def.FalloffEnd / 1000
		end,
	},
	{
		Name = "Accuracy",
		Value = function(def)
			return 1 - def.AimSpread / 4.5
		end,
	},
	{
		Name = "Mobility",
		Value = function(def)
			return (def.MoveSpeedMultiplier - 0.8) / 0.2
		end,
	},
	{
		Name = "Magazine",
		Value = function(def)
			return def.MagSize / 100
		end,
	},
}

local player = Players.LocalPlayer
local purchaseRemote = Net.Function("ShopPurchase")
local equipRemote = Net.Function("ShopEquip")

local gui: ScreenGui
local list: ScrollingFrame
local header: TextLabel
local nameLabel: TextLabel
local classLabel: TextLabel
local descriptionLabel: TextLabel
local numbersLabel: TextLabel
local statFills: { [string]: Frame } = {}
local actionButton: TextButton
local messageLabel: TextLabel

local selectedId = Weapons.List[1].Id
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

local function corner(radius: number): UICorner
	return Create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

type Status = {
	Owned: boolean,
	Equipped: boolean,
	Locked: boolean,
	Affordable: boolean,
}

local function statusOf(def: WeaponDef): Status
	local profile = State.Profile
	if not profile then
		return { Owned = false, Equipped = false, Locked = true, Affordable = false }
	end
	local equippedId = if def.Slot == "Primary" then profile.Loadout.Primary else profile.Loadout.Secondary
	return {
		Owned = profile.OwnedWeapons[def.Id] == true,
		Equipped = equippedId == def.Id,
		Locked = profile.Level < def.LevelRequired,
		Affordable = profile.Credits >= def.Price,
	}
end

local refresh: () -> ()

local function refreshList()
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local order = 0
	for _, slot in { "Primary", "Secondary" } do
		order += 1
		text({
			LayoutOrder = order,
			Size = UDim2.new(1, -8, 0, 24),
			Font = Theme.FontHeavy,
			TextSize = 14,
			TextColor3 = Theme.Muted,
			Text = string.upper(slot),
			Parent = list,
		})
		for _, def in Weapons.List do
			if def.Slot ~= slot then
				continue
			end
			order += 1
			local status = statusOf(def)
			local selected = def.Id == selectedId
			local row: TextButton = Create("TextButton", {
				LayoutOrder = order,
				Size = UDim2.new(1, -8, 0, 48),
				BackgroundColor3 = if selected then Theme.PanelLight else Theme.Panel,
				AutoButtonColor = true,
				Text = "",
				Parent = list,
			}, {
				corner(6),
				Create("UIStroke", {
					Color = Theme.Accent,
					Thickness = if selected then 1.5 else 0,
					Transparency = if selected then 0 else 1,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}),
			})
			text({
				Position = UDim2.fromOffset(10, 6),
				Size = UDim2.new(1, -120, 0, 20),
				Text = def.DisplayName,
				TextColor3 = if status.Locked then Theme.Muted else Theme.Text,
				Parent = row,
			})
			text({
				Position = UDim2.fromOffset(10, 26),
				Size = UDim2.new(1, -120, 0, 16),
				TextSize = 12,
				TextColor3 = Theme.Muted,
				Text = def.Class,
				Parent = row,
			})
			local statusText: string
			local statusColor: Color3
			if status.Equipped then
				statusText, statusColor = "EQUIPPED", Theme.Accent
			elseif status.Owned then
				statusText, statusColor = "OWNED", Theme.Good
			elseif status.Locked then
				statusText, statusColor = `LV {def.LevelRequired}`, Theme.Bad
			else
				statusText, statusColor =
					`¢ {Format.Commas(def.Price)}`, if status.Affordable then Theme.Credits else Theme.Warn
			end
			text({
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0),
				Size = UDim2.fromOffset(110, 20),
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = statusColor,
				Text = statusText,
				Parent = row,
			})
			row.Activated:Connect(function()
				selectedId = def.Id
				messageLabel.Text = ""
				refresh()
			end)
		end
	end
end

local function refreshDetail()
	local def = Weapons.Get(selectedId)
	if not def then
		return
	end
	local status = statusOf(def)
	nameLabel.Text = def.DisplayName
	classLabel.Text = `{def.Class}  •  {def.Slot}  •  {def.FireMode}`
	local profile = State.Profile
	local strength = if profile then profile.Attributes.STR else Attributes.Base
	local strengthNote = if strength < def.RequiredSTR
		then `\nYour STR ({strength}) is below {def.RequiredSTR}: expect heavy recoil and a wide bullet circle.`
		else ""
	descriptionLabel.Text = def.Description .. strengthNote
	local damageText = if def.Melee
		then `{def.Damage} melee`
		elseif def.Pellets > 1 then `{def.Damage}x{def.Pellets}`
		else tostring(def.Damage)
	local magazineText = if def.Melee then "" else `   •   MAG {def.MagSize}`
	numbersLabel.Text =
		`{string.upper(def.Ammo)}   •   DMG {damageText}   •   {def.RPM} RPM{magazineText}   •   {def.Weight} kg   •   STR {def.RequiredSTR}`

	for _, spec in STATS do
		local fill = statFills[spec.Name]
		fill.Size = UDim2.fromScale(math.clamp(spec.Value(def), 0.04, 1), 1)
	end

	if status.Equipped then
		actionButton.Text = "EQUIPPED"
		actionButton.BackgroundColor3 = Theme.PanelLight
	elseif status.Owned then
		actionButton.Text = "EQUIP"
		actionButton.BackgroundColor3 = Theme.Accent
	elseif status.Locked then
		actionButton.Text = `REQUIRES LEVEL {def.LevelRequired}`
		actionButton.BackgroundColor3 = Theme.PanelLight
	else
		actionButton.Text = `BUY  •  ¢ {Format.Commas(def.Price)}`
		actionButton.BackgroundColor3 = if status.Affordable then Theme.Good else Theme.PanelLight
	end

	if profile then
		header.Text = `LV {profile.Level}   •   ¢ {Format.Commas(profile.Credits)}`
	end
end

refresh = function()
	if not isOpen then
		return
	end
	refreshList()
	refreshDetail()
end

local function onAction()
	local def = Weapons.Get(selectedId)
	if busy or not def then
		return
	end
	local status = statusOf(def)
	if status.Equipped or status.Locked then
		return
	end
	busy = true
	messageLabel.Text = "..."
	messageLabel.TextColor3 = Theme.Muted
	task.spawn(function()
		local ok, result = pcall(function(): ShopResult
			if status.Owned then
				return equipRemote:InvokeServer(def.Id)
			end
			return purchaseRemote:InvokeServer(def.Id)
		end)
		busy = false
		if not ok or typeof(result) ~= "table" then
			messageLabel.Text = "The Armory is unavailable right now"
			messageLabel.TextColor3 = Theme.Bad
			return
		end
		messageLabel.Text = result.Message
		messageLabel.TextColor3 = if result.Success then Theme.Good else Theme.Bad
		if result.Success and not status.Owned then
			Audio.Play("Purchase", 0.7)
		end
		refresh()
	end)
end

local function build()
	gui = Create("ScreenGui", {
		Name = "Armory",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		Enabled = false,
		DisplayOrder = 5,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	Create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.5,
		Parent = gui,
	})
	local window: Frame = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(780, 480),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		Parent = gui,
	}, {
		corner(10),
		Create("UIStroke", { Color = Theme.Accent, Transparency = 0.5, Thickness = 1 }),
	})

	text({
		Position = UDim2.fromOffset(20, 12),
		Size = UDim2.fromOffset(300, 32),
		Font = Theme.FontHeavy,
		TextSize = 28,
		TextColor3 = Theme.Accent,
		Text = "ARMORY",
		Parent = window,
	})
	header = text({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -64, 0, 16),
		Size = UDim2.fromOffset(300, 24),
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Theme.Credits,
		Text = "",
		Parent = window,
	})
	-- Modal releases the first-person mouse lock while the window is open.
	local close: TextButton = Create("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 12),
		Size = UDim2.fromOffset(36, 32),
		BackgroundColor3 = Theme.PanelLight,
		Font = Theme.FontHeavy,
		TextSize = 18,
		TextColor3 = Theme.Text,
		Text = "X",
		Modal = true,
		Parent = window,
	}, { corner(6) })
	close.Activated:Connect(function()
		ShopController.Close()
	end)

	list = Create("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 56),
		Size = UDim2.fromOffset(310, 408),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = window,
	}, {
		Create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
	})

	local detail: Frame = Create("Frame", {
		Position = UDim2.fromOffset(340, 56),
		Size = UDim2.fromOffset(424, 408),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.4,
		Parent = window,
	}, { corner(8) })
	nameLabel = text({
		Position = UDim2.fromOffset(18, 14),
		Size = UDim2.fromOffset(388, 32),
		Font = Theme.FontHeavy,
		TextSize = 28,
		Text = "",
		Parent = detail,
	})
	classLabel = text({
		Position = UDim2.fromOffset(18, 48),
		Size = UDim2.fromOffset(388, 18),
		TextSize = 14,
		TextColor3 = Theme.Muted,
		Text = "",
		Parent = detail,
	})
	descriptionLabel = text({
		Position = UDim2.fromOffset(18, 72),
		Size = UDim2.fromOffset(388, 42),
		Font = Theme.FontBody,
		TextScaled = true,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = detail,
	})
	Create("UITextSizeConstraint", { MaxTextSize = 14, Parent = descriptionLabel })
	for index, spec in STATS do
		local y = 118 + (index - 1) * 26
		text({
			Position = UDim2.fromOffset(18, y),
			Size = UDim2.fromOffset(100, 18),
			TextSize = 13,
			TextColor3 = Theme.Muted,
			Text = string.upper(spec.Name),
			Parent = detail,
		})
		local back: Frame = Create("Frame", {
			Position = UDim2.fromOffset(120, y + 5),
			Size = UDim2.fromOffset(286, 8),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			Parent = detail,
		}, { corner(4) })
		statFills[spec.Name] = Create("Frame", {
			Size = UDim2.fromScale(0.5, 1),
			BackgroundColor3 = Theme.Accent,
			BorderSizePixel = 0,
			Parent = back,
		}, { corner(4) })
	end
	numbersLabel = text({
		Position = UDim2.fromOffset(18, 280),
		Size = UDim2.fromOffset(388, 18),
		TextSize = 12,
		TextColor3 = Theme.Muted,
		Text = "",
		Parent = detail,
	})
	actionButton = Create("TextButton", {
		Position = UDim2.fromOffset(18, 312),
		Size = UDim2.fromOffset(388, 46),
		BackgroundColor3 = Theme.Accent,
		Font = Theme.FontHeavy,
		TextSize = 20,
		TextColor3 = Theme.Text,
		Text = "",
		Parent = detail,
	}, { corner(8) })
	actionButton.Activated:Connect(onAction)
	messageLabel = text({
		Position = UDim2.fromOffset(18, 366),
		Size = UDim2.fromOffset(388, 24),
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		Parent = detail,
	})
end

function ShopController.Open()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if isOpen or not humanoid or humanoid.Health <= 0 then
		return
	end
	isOpen = true
	State.SetMenuOpen("Armory", true)
	messageLabel.Text = ""
	gui.Enabled = true
	refresh()
end

function ShopController.Close()
	if not isOpen then
		return
	end
	isOpen = false
	State.SetMenuOpen("Armory", false)
	gui.Enabled = false
end

function ShopController.Init()
	build()
	Net.Event("OpenShop").OnClientEvent:Connect(ShopController.Open)
	State.ProfileChanged:Connect(refresh)
	State.ZoneChanged:Connect(function(zone)
		if isOpen and (zone == nil or not zone.Safe) then
			ShopController.Close()
		end
	end)
	Net.Event("Died").OnClientEvent:Connect(ShopController.Close)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.KeyCode ~= Enum.KeyCode.B then
			return
		end
		if isOpen then
			ShopController.Close()
		elseif State.Zone and State.Zone.Safe then
			ShopController.Open()
		else
			HUDController.Toast("The Armory is only reachable from Haven", Theme.Warn)
		end
	end)
end

function ShopController.Start() end

return ShopController
