--!strict
-- The INVENTORY window (I): equipped gear, an item grid with rarity borders,
-- item details and Equip / Use / Sell / Drop actions. Also owns the
-- consumable hotkeys (F med kit, G plasma grenade) and grenade explosions.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local Create = require(script.Parent.Parent.UI.Create)
local Effects = require(script.Parent.Effects)
local Format = require(ReplicatedStorage.Shared.Format)
local HUDController = require(script.Parent.HUDController)
local Inventory = require(ReplicatedStorage.Shared.Inventory)
local Items = require(ReplicatedStorage.Shared.Config.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local State = require(script.Parent.Parent.State)
local Theme = require(script.Parent.Parent.UI.Theme)
local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

type ItemInstance = Types.ItemInstance
type ItemDef = Items.ItemDef
type ActionResult = Types.ActionResult

local InventoryController = {}

local MENU = "Inventory"
local CATEGORY_ORDER = { Weapon = 1, Armor = 2, Gadget = 3, Consumable = 4, Material = 5 }
local SLOT_LABELS = { Primary = "PRIMARY", Secondary = "SECONDARY", Armor = "ARMOR", Gadget = "FIELD" }

local player = Players.LocalPlayer
local actionRemote = Net.Function("InventoryAction")
local useRemote = Net.Function("UseConsumable")
local throwRemote = Net.Event("ThrowGrenade")

local gui: ScreenGui
local header: TextLabel
local grid: ScrollingFrame
local slotButtons: { [string]: TextButton } = {}
local detailName: TextLabel
local detailKind: TextLabel
local detailDescription: TextLabel
local detailStats: TextLabel
local primaryButton: TextButton
local sellButton: TextButton
local dropButton: TextButton
local messageLabel: TextLabel

local selectedUid: string? = nil
local isOpen = false
local busy = false

local function text(props: { [string]: any }): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		TextColor3 = Theme.Text,
		TextSize = 14,
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
		TextSize = 14,
		AutoButtonColor = true,
	}
	for key, value in props do
		defaults[key] = value
	end
	return Create("TextButton", defaults, { Create("UICorner", { CornerRadius = UDim.new(0, 6) }) })
end

local function percent(value: number): string
	return `{math.floor(value * 100 + 0.5)}%`
end

local function inHaven(): boolean
	local zone = State.Zone
	return zone ~= nil and zone.Safe
end

local function displayName(item: ItemInstance, def: ItemDef): string
	if def.MaxStack == 1 and item.Rarity ~= "Common" then
		return `{item.Rarity} {def.Name}`
	end
	return def.Name
end

local function shortTag(def: ItemDef): string
	if def.Category == "Weapon" then
		local weapon = Weapons.Get(def.WeaponId)
		return if weapon then string.upper(weapon.Slot) else "WEAPON"
	elseif def.Category == "Gadget" then
		return "FIELD"
	elseif def.Category == "Consumable" then
		return if def.Grenade then "GRENADE" else "MEDICAL"
	end
	return string.upper(def.Category)
end

local function statsText(item: ItemInstance, def: ItemDef): string
	if def.Category == "Weapon" then
		local weapon = Weapons.Get(def.WeaponId)
		if not weapon then
			return ""
		end
		local multiplier = Items.DamageMultiplier(item.Rarity)
		local damage = math.floor(weapon.Damage * multiplier + 0.5)
		local bonus = if multiplier > 1 then `  (+{math.floor((multiplier - 1) * 100 + 0.5)}%)` else ""
		local pellets = if weapon.Pellets > 1 and not weapon.Melee then ` x{weapon.Pellets}` else ""
		local magazine = if weapon.Melee then "MELEE" else `MAG {weapon.MagSize}`
		return table.concat({
			`{weapon.Class}  •  {weapon.Slot}`,
			`DMG {damage}{pellets}{bonus}  •  {weapon.RPM} RPM`,
			`{magazine}  •  {string.upper(weapon.Ammo)}`,
			`{def.Weight} kg  •  STR {weapon.RequiredSTR}  •  LV {def.LevelRequired}`,
		}, "\n")
	elseif def.Category == "Armor" then
		return `Blocks {percent(Items.ArmorReduction(def, item.Rarity))} of solid damage\n(half as much against explosions)\n{def.Weight} kg  •  LV {def.LevelRequired}`
	elseif def.Category == "Gadget" then
		return `Absorbs {percent(Items.FieldStrength(def, item.Rarity))} of optical damage\n{def.Weight} kg  •  LV {def.LevelRequired}`
	elseif def.Category == "Consumable" then
		local grenade = def.Grenade
		if grenade then
			return `{grenade.Damage} damage, {grenade.Radius}-stud blast\nThrow with G  •  {def.Weight} kg each`
		end
		return `Heals {percent(def.HealFraction or 0)} HP over {def.HealTime or 0}s\nUse with F  •  {def.Weight} kg each`
	end
	return `Sells for ¢{Format.Commas(Items.SellPrice(def, item.Rarity, 1))} each\n{def.Weight} kg each`
end

local refresh: () -> ()

local function select(uid: string?)
	selectedUid = uid
	messageLabel.Text = ""
	refresh()
end

local function run(action: () -> ActionResult)
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

local function sortedItems(profile: Types.Profile): { ItemInstance }
	local list = table.clone(profile.Inventory)
	table.sort(list, function(a: ItemInstance, b: ItemInstance)
		local defA, defB = Items.Get(a.Id), Items.Get(b.Id)
		local orderA = if defA then CATEGORY_ORDER[defA.Category] or 9 else 9
		local orderB = if defB then CATEGORY_ORDER[defB.Category] or 9 else 9
		if orderA ~= orderB then
			return orderA < orderB
		end
		local rarityA, rarityB = Items.RarityInfo(a.Rarity).Order, Items.RarityInfo(b.Rarity).Order
		if rarityA ~= rarityB then
			return rarityA > rarityB
		end
		return (if defA then defA.Name else a.Id) < (if defB then defB.Name else b.Id)
	end)
	return list
end

local function buildTile(profile: Types.Profile, item: ItemInstance, def: ItemDef, order: number)
	local rarity = Items.RarityInfo(item.Rarity)
	local selected = item.Uid == selectedUid
	local tile = button({
		LayoutOrder = order,
		BackgroundColor3 = if selected then Theme.PanelLight:Lerp(Color3.new(1, 1, 1), 0.08) else Theme.PanelLight,
		Text = "",
		Parent = grid,
	})
	Create("UIStroke", {
		Color = rarity.Color,
		Thickness = if selected then 3 else 1.5,
		Transparency = if item.Rarity == "Common" and not selected then 0.6 else 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = tile,
	})
	Create("Frame", {
		Size = UDim2.new(1, 0, 0, 4),
		BackgroundColor3 = def.Color,
		BorderSizePixel = 0,
		Parent = tile,
	})
	text({
		Position = UDim2.fromOffset(5, 6),
		Size = UDim2.new(1, -10, 0, 12),
		TextSize = 10,
		TextColor3 = Theme.Muted,
		Text = shortTag(def),
		Parent = tile,
	})
	text({
		Position = UDim2.fromOffset(5, 22),
		Size = UDim2.new(1, -10, 0, 46),
		TextScaled = true,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = if item.Rarity == "Common" then Theme.Text else rarity.Color,
		Text = def.Name,
		Parent = tile,
	})
	if item.Count > 1 then
		text({
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -5, 1, -3),
			Size = UDim2.fromOffset(50, 14),
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = `x{item.Count}`,
			Parent = tile,
		})
	end
	if Inventory.SlotOf(profile, item.Uid) then
		text({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -5, 0, 6),
			Size = UDim2.fromOffset(14, 12),
			TextSize = 11,
			Font = Theme.FontHeavy,
			TextColor3 = Theme.Accent,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "E",
			Parent = tile,
		})
	end
	tile.Activated:Connect(function()
		select(item.Uid)
	end)
end

local function refreshDetail(profile: Types.Profile)
	local item = Inventory.Find(profile, selectedUid)
	local def = if item then Items.Get(item.Id) else nil
	if not item or not def then
		selectedUid = nil
		detailName.Text = "Select an item"
		detailName.TextColor3 = Theme.Muted
		detailKind.Text = ""
		detailDescription.Text = ""
		detailStats.Text = ""
		primaryButton.Visible = false
		sellButton.Visible = false
		dropButton.Visible = false
		return
	end

	local rarity = Items.RarityInfo(item.Rarity)
	local slot = Inventory.SlotOf(profile, item.Uid)
	detailName.Text = displayName(item, def) .. (if item.Count > 1 then ` x{item.Count}` else "")
	detailName.TextColor3 = if item.Rarity == "Common" then Theme.Text else rarity.Color
	detailKind.Text = if def.MaxStack == 1 then `{item.Rarity} {def.Category}` else def.Category
	detailDescription.Text = def.Description
	detailStats.Text = statsText(item, def)

	primaryButton.Visible = true
	primaryButton.BackgroundColor3 = Theme.Accent
	if def.Category == "Material" then
		primaryButton.Visible = false
	elseif def.Category == "Consumable" then
		primaryButton.Text = if def.Grenade then "THROW WITH G" else "USE"
		primaryButton.BackgroundColor3 = if def.Grenade then Theme.PanelLight else Theme.Good
	elseif slot then
		local removable = slot == "Armor" or slot == "Gadget"
		primaryButton.Text = if removable then "UNEQUIP" else "EQUIPPED"
		primaryButton.BackgroundColor3 = if removable then Theme.Warn else Theme.PanelLight
	elseif profile.Level < def.LevelRequired then
		primaryButton.Text = `REQUIRES LV {def.LevelRequired}`
		primaryButton.BackgroundColor3 = Theme.PanelLight
	else
		primaryButton.Text = "EQUIP"
	end

	sellButton.Visible = slot == nil
	sellButton.Text = `SELL  •  ¢{Format.Commas(Items.SellPrice(def, item.Rarity, item.Count))}`
	sellButton.BackgroundColor3 = if inHaven() then Theme.Credits:Lerp(Theme.Panel, 0.35) else Theme.PanelLight
	dropButton.Visible = slot == nil
end

refresh = function()
	local profile = State.Profile
	if not isOpen or not profile then
		return
	end
	local capacity = Attributes.CarryCapacity(profile.Attributes.STR)
	local weight = Inventory.Weight(profile)
	local weightText = `{string.format("%.1f", weight)} / {string.format("%.1f", capacity)} kg`
	header.Text = `{#profile.Inventory} / {Inventory.MaxSlots} slots   •   {weightText}{if weight > capacity
		then " (OVERWEIGHT)"
		else ""}   •   ¢ {Format.Commas(profile.Credits)}`
	header.TextColor3 = if weight > capacity then Theme.Warn else Theme.Muted

	for slot, slotButton in slotButtons do
		local item = Inventory.Equipped(profile, slot)
		local def = if item then Items.Get(item.Id) else nil
		local nameLabel = slotButton:FindFirstChild("ItemName") :: TextLabel
		if item and def then
			nameLabel.Text = displayName(item, def)
			nameLabel.TextColor3 = if item.Rarity == "Common" then Theme.Text else Items.RarityInfo(item.Rarity).Color
		else
			nameLabel.Text = "Empty"
			nameLabel.TextColor3 = Theme.Muted
		end
	end

	for _, child in grid:GetChildren() do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
	for order, item in sortedItems(profile) do
		local def = Items.Get(item.Id)
		if def then
			buildTile(profile, item, def, order)
		end
	end
	refreshDetail(profile)
end

local function onPrimary()
	local profile = State.Profile
	local item = if profile then Inventory.Find(profile, selectedUid) else nil
	local def = if item then Items.Get(item.Id) else nil
	if not profile or not item or not def then
		return
	end
	local uid = item.Uid
	if def.Category == "Consumable" then
		if not def.Grenade then
			run(function(): ActionResult
				return useRemote:InvokeServer(def.Id)
			end)
		end
		return
	end
	local slot = Inventory.SlotOf(profile, uid)
	if slot == "Armor" or slot == "Gadget" then
		run(function(): ActionResult
			return actionRemote:InvokeServer("Unequip", uid)
		end)
	elseif not slot then
		run(function(): ActionResult
			return actionRemote:InvokeServer("Equip", uid)
		end)
	end
end

local function build()
	gui = Create("ScreenGui", {
		Name = "Inventory",
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
		Size = UDim2.fromOffset(880, 520),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		Parent = gui,
	}, {
		Create("UICorner", { CornerRadius = UDim.new(0, 10) }),
		Create("UIStroke", { Color = Theme.Accent, Transparency = 0.5, Thickness = 1 }),
	})

	text({
		Position = UDim2.fromOffset(20, 12),
		Size = UDim2.fromOffset(220, 32),
		Font = Theme.FontHeavy,
		TextSize = 28,
		TextColor3 = Theme.Accent,
		Text = "INVENTORY",
		Parent = window,
	})
	header = text({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -64, 0, 18),
		Size = UDim2.fromOffset(560, 22),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Right,
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
		TextSize = 18,
		Modal = true,
		Parent = window,
	})
	close.Activated:Connect(function()
		InventoryController.Close()
	end)

	-- Equipped gear.
	text({
		Position = UDim2.fromOffset(16, 56),
		Size = UDim2.fromOffset(200, 18),
		Font = Theme.FontHeavy,
		TextSize = 13,
		TextColor3 = Theme.Muted,
		Text = "EQUIPPED",
		Parent = window,
	})
	for index, slot in Inventory.GearSlots do
		local slotButton = button({
			Position = UDim2.fromOffset(16, 78 + (index - 1) * 76),
			Size = UDim2.fromOffset(200, 68),
			Text = "",
			Parent = window,
		})
		text({
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.fromOffset(180, 14),
			TextSize = 11,
			TextColor3 = Theme.Muted,
			Text = SLOT_LABELS[slot] or slot,
			Parent = slotButton,
		})
		text({
			Name = "ItemName",
			Position = UDim2.fromOffset(10, 22),
			Size = UDim2.fromOffset(180, 38),
			TextScaled = true,
			TextWrapped = true,
			Font = Theme.FontHeavy,
			Text = "",
			Parent = slotButton,
		})
		slotButton.Activated:Connect(function()
			local profile = State.Profile
			local item = if profile then Inventory.Equipped(profile, slot) else nil
			if item then
				select(item.Uid)
			end
		end)
		slotButtons[slot] = slotButton
	end

	-- Item grid.
	grid = Create("ScrollingFrame", {
		Position = UDim2.fromOffset(232, 56),
		Size = UDim2.fromOffset(402, 450),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = window,
	}, {
		Create("UIGridLayout", {
			CellSize = UDim2.fromOffset(92, 92),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Create("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, 3) }),
	})

	-- Details.
	local detail: Frame = Create("Frame", {
		Position = UDim2.fromOffset(648, 56),
		Size = UDim2.fromOffset(216, 450),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.4,
		Parent = window,
	}, { Create("UICorner", { CornerRadius = UDim.new(0, 8) }) })
	detailName = text({
		Position = UDim2.fromOffset(12, 10),
		Size = UDim2.fromOffset(192, 44),
		Font = Theme.FontHeavy,
		TextScaled = true,
		TextWrapped = true,
		Text = "",
		Parent = detail,
	})
	detailKind = text({
		Position = UDim2.fromOffset(12, 56),
		Size = UDim2.fromOffset(192, 16),
		TextSize = 12,
		TextColor3 = Theme.Muted,
		Text = "",
		Parent = detail,
	})
	detailDescription = text({
		Position = UDim2.fromOffset(12, 78),
		Size = UDim2.fromOffset(192, 80),
		Font = Theme.FontBody,
		TextSize = 13,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = detail,
	})
	detailStats = text({
		Position = UDim2.fromOffset(12, 162),
		Size = UDim2.fromOffset(192, 110),
		Font = Theme.FontBody,
		TextSize = 13,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Theme.Accent,
		Text = "",
		Parent = detail,
	})
	primaryButton = button({
		Position = UDim2.fromOffset(12, 282),
		Size = UDim2.fromOffset(192, 38),
		BackgroundColor3 = Theme.Accent,
		Text = "EQUIP",
		Parent = detail,
	})
	primaryButton.Activated:Connect(onPrimary)
	sellButton = button({
		Position = UDim2.fromOffset(12, 328),
		Size = UDim2.fromOffset(192, 34),
		Text = "SELL",
		Parent = detail,
	})
	sellButton.Activated:Connect(function()
		local uid = selectedUid
		if uid then
			run(function(): ActionResult
				return actionRemote:InvokeServer("Sell", uid)
			end)
		end
	end)
	dropButton = button({
		Position = UDim2.fromOffset(12, 370),
		Size = UDim2.fromOffset(192, 30),
		BackgroundColor3 = Theme.Bad:Lerp(Theme.Panel, 0.4),
		Text = "DROP",
		Parent = detail,
	})
	dropButton.Activated:Connect(function()
		local uid = selectedUid
		if uid then
			run(function(): ActionResult
				return actionRemote:InvokeServer("Drop", uid)
			end)
		end
	end)
	messageLabel = text({
		Position = UDim2.fromOffset(12, 406),
		Size = UDim2.fromOffset(192, 36),
		TextSize = 12,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		Parent = detail,
	})
end

function InventoryController.Open()
	if isOpen then
		return
	end
	isOpen = true
	messageLabel.Text = ""
	gui.Enabled = true
	State.SetMenuOpen(MENU, true)
	refresh()
end

function InventoryController.Close()
	if not isOpen then
		return
	end
	isOpen = false
	gui.Enabled = false
	State.SetMenuOpen(MENU, false)
end

local function alive(): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function useMedKit()
	local profile = State.Profile
	if not profile or not alive() then
		return
	end
	local itemId = if Inventory.Count(profile, "MedKit") > 0
		then "MedKit"
		elseif Inventory.Count(profile, "MedKitPlus") > 0 then "MedKitPlus"
		else nil
	if not itemId then
		HUDController.Toast("No med kits. Buy them at the Armory or find them as loot.", Theme.Warn)
		return
	end
	task.spawn(function()
		local ok, result = pcall(function(): ActionResult
			return useRemote:InvokeServer(itemId)
		end)
		if ok and typeof(result) == "table" then
			HUDController.Toast(result.Message, if result.Success then Theme.Good else Theme.Warn)
		end
	end)
end

local function throwGrenade()
	local profile = State.Profile
	if not profile or not alive() then
		return
	end
	if Inventory.Count(profile, "PlasmaGrenade") <= 0 then
		HUDController.Toast("No plasma grenades.", Theme.Warn)
		return
	end
	throwRemote:FireServer(workspace.CurrentCamera.CFrame.LookVector)
end

function InventoryController.Init()
	build()
	State.ProfileChanged:Connect(refresh)
	State.ZoneChanged:Connect(refresh)
	Net.Event("Died").OnClientEvent:Connect(InventoryController.Close)
	Net.Event("Explosion").OnClientEvent:Connect(function(explosion: Types.Explosion)
		if typeof(explosion) == "table" and typeof(explosion.Position) == "Vector3" then
			Effects.Explosion(explosion.Position, explosion.Radius)
		end
	end)

	-- Roblox's default camera script binds I (zoom in) through
	-- ContextActionService and sinks it, so UserInputService reports the key
	-- as processed. Bind above the camera's priority instead. Actions don't
	-- fire while the player is typing in a text box.
	ContextActionService:BindActionAtPriority(
		"ToggleInventory",
		function(_action: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				if isOpen then
					InventoryController.Close()
				else
					InventoryController.Open()
				end
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.I
	)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or State.UIOpen then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.F or key == Enum.KeyCode.DPadUp then
			useMedKit()
		elseif key == Enum.KeyCode.G or key == Enum.KeyCode.DPadRight then
			throwGrenade()
		end
	end)
end

function InventoryController.Start() end

return InventoryController
