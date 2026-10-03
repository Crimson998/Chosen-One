--!strict
-- The Armory window: a catalogue of weapons, gear (armor and anti-bullet
-- field generators) and supplies. Purchases land in your inventory; equip
-- them there (Tab). Opens from the Armory counter prompt or B inside Haven.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local Audio = require(ReplicatedStorage.Shared.Audio)
local Create = require(script.Parent.Parent.UI.Create)
local Format = require(ReplicatedStorage.Shared.Format)
local HUDController = require(script.Parent.HUDController)
local Inventory = require(ReplicatedStorage.Shared.Inventory)
local Items = require(ReplicatedStorage.Shared.Config.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local State = require(script.Parent.Parent.State)
local Theme = require(script.Parent.Parent.UI.Theme)
local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

type WeaponDef = Weapons.WeaponDef
type ItemDef = Items.ItemDef
type ActionResult = Types.ActionResult

type StatSpec = {
	Name: string,
	Value: (WeaponDef) -> number,
}

type Tab = string -- "Weapons" | "Gear" | "Supplies"

local ShopController = {}

local MENU = "Armory"
local TABS: { Tab } = { "Weapons", "Gear", "Supplies" }

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
			return (def.MoveSpeedMultiplier - 0.7) / 0.4
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

local gui: ScreenGui
local list: ScrollingFrame
local header: TextLabel
local tabButtons: { [string]: TextButton } = {}
local nameLabel: TextLabel
local classLabel: TextLabel
local descriptionLabel: TextLabel
local statsFrame: Frame
local statFills: { [string]: Frame } = {}
local infoLabel: TextLabel
local numbersLabel: TextLabel
local buyButton: TextButton
local buyFiveButton: TextButton
local messageLabel: TextLabel

local currentTab: Tab = "Weapons"
local selectedId: string? = nil
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

local function tabOf(def: ItemDef): Tab?
	if def.Category == "Weapon" then
		return "Weapons"
	elseif def.Category == "Armor" or def.Category == "Gadget" then
		return "Gear"
	elseif def.Category == "Consumable" then
		return "Supplies"
	end
	return nil
end

-- Items sold in a tab, in display order.
local function catalogue(tab: Tab): { ItemDef }
	local result: { ItemDef } = {}
	for _, def in Items.List do
		if def.BuyPrice and tabOf(def) == tab then
			table.insert(result, def)
		end
	end
	local function group(def: ItemDef): number
		if def.Category == "Weapon" then
			local weapon = Weapons.Get(def.WeaponId)
			return if weapon and weapon.Slot == "Primary" then 1 else 2
		end
		return if def.Category == "Armor" then 1 else 2
	end
	table.sort(result, function(a: ItemDef, b: ItemDef)
		if group(a) ~= group(b) then
			return group(a) < group(b)
		end
		if a.LevelRequired ~= b.LevelRequired then
			return a.LevelRequired < b.LevelRequired
		end
		return a.Name < b.Name
	end)
	return result
end

local function groupLabel(def: ItemDef): string
	if def.Category == "Weapon" then
		local weapon = Weapons.Get(def.WeaponId)
		return if weapon then string.upper(weapon.Slot) else "WEAPONS"
	end
	return if def.Category == "Armor"
		then "ARMOR"
		elseif def.Category == "Gadget" then "ANTI-BULLET FIELDS"
		else "SUPPLIES"
end

local refresh: () -> ()

local function refreshList()
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local profile = State.Profile
	local order = 0
	local lastGroup = ""
	for _, def in catalogue(currentTab) do
		local groupName = groupLabel(def)
		if groupName ~= lastGroup then
			lastGroup = groupName
			order += 1
			text({
				LayoutOrder = order,
				Size = UDim2.new(1, -8, 0, 22),
				Font = Theme.FontHeavy,
				TextSize = 13,
				TextColor3 = Theme.Muted,
				Text = groupName,
				Parent = list,
			})
		end
		order += 1
		local locked = profile ~= nil and profile.Level < def.LevelRequired
		local owned = if profile then Inventory.Count(profile, def.Id) else 0
		local selected = def.Id == selectedId
		local row: TextButton = Create("TextButton", {
			LayoutOrder = order,
			Size = UDim2.new(1, -8, 0, 46),
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
		Create("Frame", {
			Position = UDim2.fromOffset(0, 8),
			Size = UDim2.fromOffset(4, 30),
			BackgroundColor3 = def.Color,
			BorderSizePixel = 0,
			Parent = row,
		})
		text({
			Position = UDim2.fromOffset(12, 5),
			Size = UDim2.new(1, -130, 0, 20),
			TextSize = 15,
			TextColor3 = if locked then Theme.Muted else Theme.Text,
			Text = def.Name,
			Parent = row,
		})
		text({
			Position = UDim2.fromOffset(12, 25),
			Size = UDim2.new(1, -130, 0, 16),
			TextSize = 12,
			TextColor3 = Theme.Muted,
			Text = if owned > 0 then `Owned x{owned}` else def.Category,
			Parent = row,
		})
		local status = if locked then `LV {def.LevelRequired}` else `¢ {Format.Commas(def.BuyPrice or 0)}`
		local affordable = profile ~= nil and profile.Credits >= (def.BuyPrice or 0)
		text({
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(110, 20),
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = if locked then Theme.Bad elseif affordable then Theme.Credits else Theme.Warn,
			Text = status,
			Parent = row,
		})
		row.Activated:Connect(function()
			selectedId = def.Id
			messageLabel.Text = ""
			refresh()
		end)
	end
end

local function gearInfo(def: ItemDef): string
	if def.Category == "Armor" then
		return `Blocks {math.floor(Items.ArmorReduction(def, "Common") * 100 + 0.5)}% of solid damage (half against explosions).\nRarer drops block more.`
	elseif def.Category == "Gadget" then
		return `Absorbs {math.floor(Items.FieldStrength(def, "Common") * 100 + 0.5)}% of optical (laser) damage.\nRarer drops absorb more.`
	end
	local grenade = def.Grenade
	if grenade then
		return `{grenade.Damage} damage in a {grenade.Radius}-stud blast after {grenade.Fuse}s. Throw with G.`
	end
	return `Heals {math.floor((def.HealFraction or 0) * 100 + 0.5)}% HP over {def.HealTime or 0}s. Use with F.`
end

local function refreshDetail()
	local def = Items.Get(selectedId)
	local profile = State.Profile
	if profile then
		header.Text = `LV {profile.Level}   •   ¢ {Format.Commas(profile.Credits)}`
	end
	if not def then
		nameLabel.Text = "Select an item"
		classLabel.Text = ""
		descriptionLabel.Text = ""
		infoLabel.Text = ""
		numbersLabel.Text = ""
		statsFrame.Visible = false
		buyButton.Visible = false
		buyFiveButton.Visible = false
		return
	end

	nameLabel.Text = def.Name
	descriptionLabel.Text = def.Description
	local weapon = Weapons.Get(def.WeaponId)
	statsFrame.Visible = weapon ~= nil
	if weapon then
		classLabel.Text = `{weapon.Class}  •  {weapon.Slot}  •  {weapon.FireMode}`
		for _, spec in STATS do
			statFills[spec.Name].Size = UDim2.fromScale(math.clamp(spec.Value(weapon), 0.04, 1), 1)
		end
		local strength = if profile then profile.Attributes.STR else Attributes.Base
		infoLabel.Text = if strength < weapon.RequiredSTR
			then `Your STR ({strength}) is below {weapon.RequiredSTR}: heavy recoil and a wide bullet circle.`
			else ""
		local damageText = if weapon.Melee
			then `{weapon.Damage} melee`
			elseif weapon.Pellets > 1 then `{weapon.Damage}x{weapon.Pellets}`
			else tostring(weapon.Damage)
		local magazineText = if weapon.Melee then "" else `   •   MAG {weapon.MagSize}`
		numbersLabel.Text =
			`{string.upper(weapon.Ammo)}   •   DMG {damageText}   •   {weapon.RPM} RPM{magazineText}   •   {weapon.Weight} kg   •   STR {weapon.RequiredSTR}`
	else
		classLabel.Text = def.Category
		infoLabel.Text = gearInfo(def)
		numbersLabel.Text = `{def.Weight} kg   •   LV {def.LevelRequired}   •   sells back for ¢{def.SellValue}`
	end

	local price = def.BuyPrice or 0
	local locked = profile ~= nil and profile.Level < def.LevelRequired
	buyButton.Visible = true
	if locked then
		buyButton.Text = `REQUIRES LEVEL {def.LevelRequired}`
		buyButton.BackgroundColor3 = Theme.PanelLight
	else
		buyButton.Text = `BUY  •  ¢ {Format.Commas(price)}`
		buyButton.BackgroundColor3 = if profile and profile.Credits >= price then Theme.Good else Theme.PanelLight
	end
	buyFiveButton.Visible = def.MaxStack > 1 and not locked
	buyFiveButton.Text = `BUY 5  •  ¢ {Format.Commas(price * 5)}`
end

refresh = function()
	if not isOpen then
		return
	end
	for tab, tabButton in tabButtons do
		tabButton.BackgroundColor3 = if tab == currentTab then Theme.Accent else Theme.PanelLight
	end
	refreshList()
	refreshDetail()
end

local function buy(count: number)
	local def = Items.Get(selectedId)
	if busy or not def then
		return
	end
	busy = true
	messageLabel.Text = "..."
	messageLabel.TextColor3 = Theme.Muted
	task.spawn(function()
		local ok, result = pcall(function(): ActionResult
			return purchaseRemote:InvokeServer(def.Id, count)
		end)
		busy = false
		if not ok or typeof(result) ~= "table" then
			messageLabel.Text = "The Armory is unavailable right now"
			messageLabel.TextColor3 = Theme.Bad
			return
		end
		messageLabel.Text = result.Message
		messageLabel.TextColor3 = if result.Success then Theme.Good else Theme.Bad
		if result.Success then
			Audio.Play("Purchase", 0.7)
		end
		refresh()
	end)
end

local function selectTab(tab: Tab)
	currentTab = tab
	local first = catalogue(tab)[1]
	selectedId = if first then first.Id else nil
	messageLabel.Text = ""
	refresh()
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
		Size = UDim2.fromOffset(800, 520),
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

	for index, tab in TABS do
		local tabButton: TextButton = Create("TextButton", {
			Position = UDim2.fromOffset(16 + (index - 1) * 106, 52),
			Size = UDim2.fromOffset(100, 28),
			BackgroundColor3 = Theme.PanelLight,
			Font = Theme.FontHeavy,
			TextSize = 13,
			TextColor3 = Theme.Text,
			Text = string.upper(tab),
			Parent = window,
		}, { corner(6) })
		tabButton.Activated:Connect(function()
			selectTab(tab)
		end)
		tabButtons[tab] = tabButton
	end

	list = Create("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 88),
		Size = UDim2.fromOffset(320, 416),
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
		Position = UDim2.fromOffset(350, 52),
		Size = UDim2.fromOffset(434, 452),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.4,
		Parent = window,
	}, { corner(8) })
	nameLabel = text({
		Position = UDim2.fromOffset(18, 14),
		Size = UDim2.fromOffset(398, 32),
		Font = Theme.FontHeavy,
		TextSize = 28,
		Text = "",
		Parent = detail,
	})
	classLabel = text({
		Position = UDim2.fromOffset(18, 48),
		Size = UDim2.fromOffset(398, 18),
		TextSize = 14,
		TextColor3 = Theme.Muted,
		Text = "",
		Parent = detail,
	})
	descriptionLabel = text({
		Position = UDim2.fromOffset(18, 72),
		Size = UDim2.fromOffset(398, 42),
		Font = Theme.FontBody,
		TextScaled = true,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = detail,
	})
	Create("UITextSizeConstraint", { MaxTextSize = 14, Parent = descriptionLabel })

	statsFrame = Create("Frame", {
		Position = UDim2.fromOffset(0, 118),
		Size = UDim2.fromOffset(434, 160),
		BackgroundTransparency = 1,
		Parent = detail,
	})
	for index, spec in STATS do
		local y = (index - 1) * 26
		text({
			Position = UDim2.fromOffset(18, y),
			Size = UDim2.fromOffset(100, 18),
			TextSize = 13,
			TextColor3 = Theme.Muted,
			Text = string.upper(spec.Name),
			Parent = statsFrame,
		})
		local back: Frame = Create("Frame", {
			Position = UDim2.fromOffset(120, y + 5),
			Size = UDim2.fromOffset(296, 8),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			Parent = statsFrame,
		}, { corner(4) })
		statFills[spec.Name] = Create("Frame", {
			Size = UDim2.fromScale(0.5, 1),
			BackgroundColor3 = Theme.Accent,
			BorderSizePixel = 0,
			Parent = back,
		}, { corner(4) })
	end

	infoLabel = text({
		Position = UDim2.fromOffset(18, 280),
		Size = UDim2.fromOffset(398, 44),
		Font = Theme.FontBody,
		TextSize = 13,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Theme.Warn,
		Text = "",
		Parent = detail,
	})
	numbersLabel = text({
		Position = UDim2.fromOffset(18, 326),
		Size = UDim2.fromOffset(398, 18),
		TextSize = 12,
		TextColor3 = Theme.Muted,
		Text = "",
		Parent = detail,
	})
	buyButton = Create("TextButton", {
		Position = UDim2.fromOffset(18, 352),
		Size = UDim2.fromOffset(250, 44),
		BackgroundColor3 = Theme.Good,
		Font = Theme.FontHeavy,
		TextSize = 18,
		TextColor3 = Theme.Text,
		Text = "",
		Parent = detail,
	}, { corner(8) })
	buyButton.Activated:Connect(function()
		buy(1)
	end)
	buyFiveButton = Create("TextButton", {
		Position = UDim2.fromOffset(276, 352),
		Size = UDim2.fromOffset(140, 44),
		BackgroundColor3 = Theme.PanelLight,
		Font = Theme.FontHeavy,
		TextSize = 14,
		TextColor3 = Theme.Text,
		Text = "",
		Parent = detail,
	}, { corner(8) })
	buyFiveButton.Activated:Connect(function()
		buy(5)
	end)
	messageLabel = text({
		Position = UDim2.fromOffset(18, 404),
		Size = UDim2.fromOffset(398, 40),
		TextSize = 14,
		TextWrapped = true,
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
	State.SetMenuOpen(MENU, true)
	messageLabel.Text = ""
	gui.Enabled = true
	if not selectedId then
		selectTab(currentTab)
	else
		refresh()
	end
end

function ShopController.Close()
	if not isOpen then
		return
	end
	isOpen = false
	State.SetMenuOpen(MENU, false)
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
