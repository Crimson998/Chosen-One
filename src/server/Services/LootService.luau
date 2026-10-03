--!strict
-- Ground loot. Enemies drop personal loot for every player credited with the
-- kill (reserved for its owner for a short time, then free for all). Players
-- killed by other players in PvP zones drop a random unequipped item, and
-- dropped items land here too. Each drop is a small model with a light beam
-- coloured by rarity and a pick-up prompt.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatService = require(script.Parent.CombatService)
local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local Items = require(ReplicatedStorage.Shared.Config.Items)
local Loot = require(ReplicatedStorage.Shared.Config.Loot)
local ProgressionService = require(script.Parent.ProgressionService)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponModel = require(ReplicatedStorage.Shared.WeaponModel)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local WorldService = require(script.Parent.WorldService)

type ItemInstance = Types.ItemInstance
type ItemDef = Items.ItemDef
type PoolRoll = Loot.PoolRoll

type Drop = {
	Id: string,
	Count: number,
	Rarity: string,
	Owner: number?, -- UserId with first claim
	OwnedUntil: number,
	Model: Model,
	Label: TextLabel,
	Prompt: ProximityPrompt,
	Taken: boolean,
}

local LootService = {}

local rng = Random.new()

local function displayName(def: ItemDef, rarity: string, count: number): string
	local prefix = if def.MaxStack == 1 and rarity ~= "Common" then `{rarity} ` else ""
	local suffix = if count > 1 then ` x{count}` else ""
	return prefix .. def.Name .. suffix
end

local function groundParams(): RaycastParams
	local exclude: { Instance } = { WorldService.GetFolder("Enemies"), WorldService.GetFolder("Drops") }
	for _, player in game:GetService("Players"):GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	return params
end

local function groundBelow(position: Vector3): Vector3
	local result = workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -60, 0), groundParams())
	return if result then result.Position else Vector3.new(position.X, 0, position.Z)
end

local function lootPart(name: string, size: Vector3, color: Color3, material: Enum.Material, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- The item itself: the actual gun model for weapons, a coloured case otherwise.
local function buildModel(def: ItemDef, rarityColor: Color3, ground: Vector3): (Model, BasePart)
	local yaw = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	local weapon = Weapons.Get(def.WeaponId)
	if weapon then
		local gun = WeaponModel.Build(weapon)
		local handle = gun.PrimaryPart :: BasePart
		handle.Anchored = true
		gun:ScaleTo(1.3)
		-- Lying on its side.
		gun:PivotTo(CFrame.new(ground + Vector3.new(0, 0.35, 0)) * yaw * CFrame.Angles(0, 0, math.rad(90)))
		return gun, handle
	end

	local model = Instance.new("Model")
	local size = if def.Category == "Consumable" then Vector3.new(0.9, 0.6, 0.9) else Vector3.new(1.3, 0.8, 1.1)
	local case = lootPart("Case", size, def.Color, Enum.Material.Metal, model)
	case.CFrame = CFrame.new(ground + Vector3.new(0, size.Y / 2, 0)) * yaw
	local stripe =
		lootPart("Stripe", size + Vector3.new(0.02, -size.Y + 0.14, 0.02), rarityColor, Enum.Material.Neon, model)
	stripe.CFrame = case.CFrame
	model.PrimaryPart = case
	return model, case
end

local function removeDrop(drop: Drop)
	if not drop.Taken then
		drop.Taken = true
		drop.Model:Destroy()
	end
end

local function pickUp(player: Player, drop: Drop)
	if drop.Taken then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local now = os.clock()
	if drop.Owner and drop.Owner ~= player.UserId and now < drop.OwnedUntil then
		ProgressionService.Notify(player, {
			Kind = "Warning",
			Text = `That loot is reserved for another player for {math.ceil(drop.OwnedUntil - now)}s`,
		})
		return
	end
	local def = Items.Get(drop.Id)
	if not def then
		removeDrop(drop)
		return
	end
	local added = InventoryService.AddItem(player, drop.Id, drop.Count, drop.Rarity)
	if added <= 0 then
		ProgressionService.Notify(player, { Kind = "Warning", Text = "Inventory full. Sell or drop something (Tab)." })
		return
	end
	ProgressionService.Notify(player, { Kind = "Loot", Text = def.Name, Amount = added, Rarity = drop.Rarity })
	drop.Count -= added
	if drop.Count <= 0 then
		removeDrop(drop)
	else
		local name = displayName(def, drop.Rarity, drop.Count)
		drop.Label.Text = name
		drop.Prompt.ObjectText = name
	end
end

-- Places an item on the ground. With an owner, only they can take it until
-- the ownership window ends.
function LootService.SpawnDrop(id: string, count: number, rarity: string, position: Vector3, owner: Player?)
	local def = Items.Get(id)
	if not def or count <= 0 then
		return
	end
	local rarityInfo = Items.RarityInfo(rarity)
	local scatter = Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-3, 3))
	local ground = groundBelow(position + scatter)
	local model, anchor = buildModel(def, rarityInfo.Color, ground)
	model.Name = `Loot_{def.Id}`

	-- Light beam: taller and brighter for rarer items.
	local beamHeight = 4 + rarityInfo.Order * 2
	local beam = lootPart("Beam", Vector3.new(beamHeight, 0.22, 0.22), rarityInfo.Color, Enum.Material.Neon, model)
	beam.Shape = Enum.PartType.Cylinder
	beam.Transparency = 0.45
	beam.CFrame = CFrame.new(ground + Vector3.new(0, beamHeight / 2, 0)) * CFrame.Angles(0, 0, math.rad(90))

	-- Lights are reserved for better-than-common loot to keep piles cheap.
	if rarityInfo.Order >= 2 then
		local light = Instance.new("PointLight")
		light.Color = rarityInfo.Color
		light.Range = 6 + rarityInfo.Order * 2
		light.Brightness = 1.5
		light.Parent = anchor
	end

	local name = displayName(def, rarity, count)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(200, 22)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.2, 0)
	gui.MaxDistance = 45
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = rarityInfo.Color
	label.TextStrokeTransparency = 0.3
	label.Text = name
	label.Parent = gui
	gui.Parent = anchor

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick up"
	prompt.ObjectText = name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	local drop: Drop = {
		Id = def.Id,
		Count = count,
		Rarity = rarity,
		Owner = if owner then owner.UserId else nil,
		OwnedUntil = os.clock() + Loot.OwnershipTime,
		Model = model,
		Label = label,
		Prompt = prompt,
		Taken = false,
	}
	prompt.Triggered:Connect(function(player: Player)
		pickUp(player, drop)
	end)
	model.Parent = WorldService.GetFolder("Drops")
	task.delay(Loot.Lifetime, function()
		removeDrop(drop)
	end)
end

local function rollPool(roll: PoolRoll?, luck: number, position: Vector3, owner: Player)
	if not roll or #roll.Pool == 0 then
		return
	end
	for _ = 1, roll.Rolls or 1 do
		if rng:NextNumber() < roll.Chance then
			local id = roll.Pool[rng:NextInteger(1, #roll.Pool)]
			LootService.SpawnDrop(id, 1, Items.RollRarity(rng, luck), position, owner)
		end
	end
end

-- Rolls an enemy's loot table for one player.
function LootService.RollEnemyLoot(enemyId: string, position: Vector3, owner: Player)
	local tbl = Loot.Tables[enemyId]
	if not tbl then
		return
	end
	local profile = DataService.GetProfile(owner)
	local luck = tbl.RarityLuck + (if profile then profile.Attributes.LUK * Loot.LuckPerLuk else 0)
	for _, entry in tbl.Entries do
		if rng:NextNumber() < entry.Chance then
			local low = entry.Min or 1
			local count = rng:NextInteger(low, math.max(low, entry.Max or low))
			LootService.SpawnDrop(entry.Item, count, "Common", position, owner)
		end
	end
	rollPool(tbl.Weapons, luck, position, owner)
	rollPool(tbl.Gear, luck, position, owner)
end

local function rootPosition(model: Instance?): Vector3?
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

function LootService.Init()
	CombatService.Killed:Connect(function(humanoid: Humanoid, attacker: any, _info: any, credited: { Player })
		local model = humanoid.Parent
		local position = rootPosition(model)
		if not model or not position then
			return
		end

		local def = CombatService.GetEnemyDef(humanoid)
		if def then
			if not def.Passive then
				for _, player in credited do
					LootService.RollEnemyLoot(def.Id, position, player)
				end
			end
			return
		end

		-- GGO's death penalty: killed by a player, you drop something.
		local victim = game:GetService("Players"):GetPlayerFromCharacter(model)
		if victim and typeof(attacker) == "Instance" and attacker:IsA("Player") then
			local item = InventoryService.TakeRandomUnequipped(victim)
			local itemDef = if item then Items.Get(item.Id) else nil
			if item and itemDef then
				LootService.SpawnDrop(item.Id, item.Count, item.Rarity, position, nil)
				ProgressionService.Notify(victim, {
					Kind = "Warning",
					Text = `You dropped {displayName(itemDef, item.Rarity, item.Count)}!`,
				})
			end
		end
	end)

	InventoryService.Dropped:Connect(function(_player: Player, item: ItemInstance, position: Vector3)
		LootService.SpawnDrop(item.Id, item.Count, item.Rarity, position, nil)
	end)
end

return LootService
