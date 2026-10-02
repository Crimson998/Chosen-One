--!strict
-- Consumables: med kits heal over a few seconds; plasma grenades are thrown,
-- bounce, and detonate in a blue plasma burst after a short fuse.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local CombatService = require(script.Parent.CombatService)
local InventoryService = require(script.Parent.InventoryService)
local Items = require(ReplicatedStorage.Shared.Config.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldService = require(script.Parent.WorldService)

type ActionResult = Types.ActionResult
type ItemDef = Items.ItemDef

local ConsumableService = {}

local GRENADE_ID = "PlasmaGrenade"
local THROW_SPEED = 70
local THROW_LIFT = 14

local healing: { [Player]: boolean } = {}
local useLimiter = RateLimiter.new(4, 4)
local throwLimiter = RateLimiter.new(1, 1)
local explosionRemote = Net.Event("Explosion")

local function aliveParts(player: Player): (Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local head = character and character:FindFirstChild("Head")
	if humanoid and humanoid.Health > 0 and head and head:IsA("BasePart") then
		return humanoid, head
	end
	return nil, nil
end

local function useMedKit(player: Player, def: ItemDef): ActionResult
	local humanoid = aliveParts(player)
	if not humanoid then
		return { Success = false, Message = "You can't do that right now" }
	end
	if healing[player] then
		return { Success = false, Message = "Already healing" }
	end
	if humanoid.Health >= humanoid.MaxHealth then
		return { Success = false, Message = "Already at full health" }
	end
	if not InventoryService.ConsumeById(player, def.Id, 1) then
		return { Success = false, Message = `No {def.Name} left` }
	end

	healing[player] = true
	local total = humanoid.MaxHealth * (def.HealFraction or 0)
	local duration = def.HealTime or 1
	task.spawn(function()
		local elapsed = 0
		while elapsed < duration and humanoid.Parent and humanoid.Health > 0 do
			local step = math.min(task.wait(0.1), duration - elapsed)
			elapsed += step
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + total * step / duration)
		end
		healing[player] = nil
	end)
	return { Success = true, Message = `Using {def.Name}` }
end

local function onUse(player: Player, itemId: any): ActionResult
	if not useLimiter:Allow(player) then
		return { Success = false, Message = "Slow down" }
	end
	local def = Items.Get(itemId)
	if not def or def.Category ~= "Consumable" then
		return { Success = false, Message = "That can't be used" }
	end
	if def.HealFraction then
		return useMedKit(player, def)
	end
	if def.Grenade then
		return { Success = false, Message = "Press G to throw grenades" }
	end
	return { Success = false, Message = "That can't be used" }
end

local function worldOnlyParams(): RaycastParams
	local exclude: { Instance } = { WorldService.GetFolder("Enemies"), WorldService.GetFolder("Drops") }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	return params
end

local function explode(thrower: Player, position: Vector3, stats: Items.GrenadeStats)
	explosionRemote:FireAllClients({ Position = position, Radius = stats.Radius } :: Types.Explosion)

	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { WorldService.GetFolder("Drops") }
	local walls = worldOnlyParams()
	local hit: { [Humanoid]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(position, stats.Radius, overlap) do
		local model, humanoid = CombatService.FindHumanoid(part)
		if not model or not humanoid or hit[humanoid] then
			continue
		end
		hit[humanoid] = true
		local root = model:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			continue
		end
		local offset = root.Position - position
		-- Solid cover shields you from the blast.
		if offset.Magnitude > 0.5 and workspace:Raycast(position, offset, walls) then
			continue
		end
		local falloff = math.clamp(1 - (offset.Magnitude / stats.Radius) ^ 1.5, 0.15, 1)
		CombatService.DamageHumanoid(thrower, humanoid, stats.Damage * falloff, {
			WeaponId = GRENADE_ID,
			SourcePosition = position,
			DamageType = "Explosive",
		})
	end
end

local function onThrow(player: Player, direction: any)
	if not throwLimiter:Allow(player) or not Ballistics.IsFiniteVector(direction) then
		return
	end
	local dir = direction :: Vector3
	if dir.Magnitude < 0.5 then
		return
	end
	dir = dir.Unit
	local humanoid, head = aliveParts(player)
	local def = Items.Get(GRENADE_ID)
	local stats = def and def.Grenade
	if not humanoid or not head or not stats then
		return
	end
	if not InventoryService.ConsumeById(player, GRENADE_ID, 1) then
		ProgressionService.Notify(player, { Kind = "Warning", Text = "No plasma grenades. Buy them at the Armory." })
		return
	end

	local grenade = Instance.new("Part")
	grenade.Name = "PlasmaGrenade"
	grenade.Shape = Enum.PartType.Ball
	grenade.Size = Vector3.new(0.8, 0.8, 0.8)
	grenade.Color = Color3.fromRGB(80, 160, 255)
	grenade.Material = Enum.Material.Neon
	grenade.CanQuery = false
	grenade.CanTouch = false
	grenade.CFrame = CFrame.new(head.Position + dir * 2.5)
	local light = Instance.new("PointLight")
	light.Color = grenade.Color
	light.Range = 6
	light.Parent = grenade
	grenade.Parent = WorldService.GetFolder("Drops")
	pcall(function()
		grenade:SetNetworkOwner(nil)
	end)
	grenade.AssemblyLinearVelocity = dir * THROW_SPEED + Vector3.new(0, THROW_LIFT, 0)

	task.delay(stats.Fuse, function()
		if grenade.Parent then
			local position = grenade.Position
			grenade:Destroy()
			explode(player, position, stats)
		end
	end)
end

function ConsumableService.Init()
	Net.Function("UseConsumable").OnServerInvoke = onUse
	Net.Event("ThrowGrenade").OnServerEvent:Connect(onThrow)
	Players.PlayerRemoving:Connect(function(player)
		healing[player] = nil
	end)
end

return ConsumableService
