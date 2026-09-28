--!strict
-- Server-authoritative weapons. The server owns every player's loadout, ammo,
-- fire rate and reload timing. Clients raycast locally for responsiveness and
-- send hit claims, which are validated here before any damage is dealt:
--   * the shot origin must be near the shooter's head
--   * fire rate is enforced with a token bucket (tolerates network jitter)
--   * each claimed hit must lie on the claimed ray, within weapon range,
--     near the claimed part (with latency leeway) and with clear line of
--     sight through world geometry.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local CombatService = require(script.Parent.CombatService)
local DataService = require(script.Parent.DataService)
local Net = require(ReplicatedStorage.Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponModel = require(ReplicatedStorage.Shared.WeaponModel)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local WorldService = require(script.Parent.WorldService)

type WeaponDef = Weapons.WeaponDef
type Slot = Weapons.Slot
type AmmoState = Types.AmmoState
type HitInfo = Types.HitInfo
type ShotReplication = Types.ShotReplication

type WeaponState = {
	Def: WeaponDef,
	Mag: number,
	Reserve: number,
	ReloadToken: number,
	ReloadingUntil: number, -- 0 when not reloading
	Tokens: number,
	TokenTime: number,
}

type Loadout = {
	Character: Model,
	Primary: WeaponState,
	Secondary: WeaponState,
	Equipped: Slot,
	WorldModel: Model?,
}

type PendingHit = {
	Damage: number,
	Headshot: boolean,
	Position: Vector3,
}

local WeaponService = {}

local MAX_ORIGIN_OFFSET = 8 -- studs between claimed origin and the shooter's head
local HIT_TOLERANCE = 3 -- studs of slack around the claimed hit part
local LATENCY_LEAD = 0.3 -- seconds of target movement tolerated
local RELOAD_GRACE = 0.2 -- server finishes reloads early to absorb latency
local FIRE_RATE_SLACK = 1.1
local REPLICATION_RADIUS = 1000

local loadouts: { [Player]: Loadout } = {}

local ammoUpdate = Net.Event("AmmoUpdate")
local hitConfirm = Net.Event("HitConfirm")
local shotReplicated = Net.Unreliable("ShotReplicated")

local fireLimiter = RateLimiter.new(40, 20)
local actionLimiter = RateLimiter.new(15, 10)

local function getSlot(loadout: Loadout, slot: Slot): WeaponState
	return if slot == "Primary" then loadout.Primary else loadout.Secondary
end

-- Sustained shots/second and burst capacity for the fire-rate token bucket.
local function fireBudget(def: WeaponDef): (number, number)
	local interval = Weapons.FireInterval(def)
	if def.FireMode == "Burst" then
		local count = def.BurstCount or 3
		local cycle = (count - 1) * interval + (def.BurstDelay or 0.3)
		return count / cycle * FIRE_RATE_SLACK, count + 1
	end
	return (1 / interval) * FIRE_RATE_SLACK, 3
end

local function newState(def: WeaponDef): WeaponState
	local _, capacity = fireBudget(def)
	return {
		Def = def,
		Mag = def.MagSize,
		Reserve = def.ReserveAmmo,
		ReloadToken = 0,
		ReloadingUntil = 0,
		Tokens = capacity,
		TokenTime = os.clock(),
	}
end

local function consumeFireToken(state: WeaponState, now: number): boolean
	local rate, capacity = fireBudget(state.Def)
	state.Tokens = math.min(capacity, state.Tokens + (now - state.TokenTime) * rate)
	state.TokenTime = now
	if state.Tokens >= 1 then
		state.Tokens -= 1
		return true
	end
	return false
end

local function sendAmmo(player: Player)
	local loadout = loadouts[player]
	if not loadout then
		return
	end
	local payload: AmmoState = {
		Primary = { Id = loadout.Primary.Def.Id, Mag = loadout.Primary.Mag, Reserve = loadout.Primary.Reserve },
		Secondary = { Id = loadout.Secondary.Def.Id, Mag = loadout.Secondary.Mag, Reserve = loadout.Secondary.Reserve },
		Equipped = loadout.Equipped,
	}
	ammoUpdate:FireClient(player, payload)
end

local function cancelReload(state: WeaponState)
	state.ReloadingUntil = 0
	state.ReloadToken += 1
end

local function completeReload(player: Player, state: WeaponState)
	cancelReload(state)
	local take = math.min(state.Def.MagSize - state.Mag, state.Reserve)
	state.Mag += take
	state.Reserve -= take
	sendAmmo(player)
end

-- Third-person gun other players see. Welded to the torso rather than the
-- hand so it stays sensible regardless of which animation is playing.
local function attachWorldModel(loadout: Loadout)
	if loadout.WorldModel then
		loadout.WorldModel:Destroy()
		loadout.WorldModel = nil
	end
	local character = loadout.Character
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not torso or not torso:IsA("BasePart") then
		return
	end
	local isR15 = torso.Name == "UpperTorso"
	local model = WeaponModel.Build(getSlot(loadout, loadout.Equipped).Def)
	model.Name = "WorldWeapon"
	local handle = model.PrimaryPart :: BasePart
	local weld = Instance.new("Weld")
	weld.Part0 = torso
	weld.Part1 = handle
	weld.C0 = if isR15 then CFrame.new(0.9, 0.35, -1.5) else CFrame.new(1.1, 0.6, -1.6)
	weld.Parent = handle
	model.Parent = character
	loadout.WorldModel = model
end

-- Raycast params that only see world geometry (no characters or enemies).
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
	params.IgnoreWater = true
	return params
end

local function isHeadshot(part: BasePart): boolean
	if part.Name == "Head" then
		return true
	end
	local accessory = part.Parent
	if accessory and accessory:IsA("Accessory") then
		local weld = part:FindFirstChild("AccessoryWeld")
		if weld and (weld:IsA("JointInstance") or weld:IsA("WeldConstraint")) then
			local joint = weld :: any
			local p0: BasePart? = joint.Part0
			local p1: BasePart? = joint.Part1
			return (p0 ~= nil and p0.Name == "Head") or (p1 ~= nil and p1.Name == "Head")
		end
	end
	return false
end

local function validateHit(
	def: WeaponDef,
	origin: Vector3,
	direction: Vector3,
	hit: BasePart,
	position: Vector3,
	params: RaycastParams
): boolean
	local offset = position - origin
	local distance = offset.Magnitude
	if distance > def.Range + 5 then
		return false
	end

	-- The hit point must lie on the ray the client says it fired.
	local along = offset:Dot(direction)
	if along < 0 or (offset - direction * along).Magnitude > 2 then
		return false
	end

	-- The hit point must be on (or near) the claimed part. Moving targets get
	-- extra room because the client saw them slightly in the past.
	local tolerance = HIT_TOLERANCE + hit.AssemblyLinearVelocity.Magnitude * LATENCY_LEAD
	local localPosition = hit.CFrame:PointToObjectSpace(position)
	local half = hit.Size / 2
	if
		math.abs(localPosition.X) > half.X + tolerance
		or math.abs(localPosition.Y) > half.Y + tolerance
		or math.abs(localPosition.Z) > half.Z + tolerance
	then
		return false
	end

	-- No world geometry between the muzzle and the hit point.
	if distance > 1 then
		local blocked = workspace:Raycast(origin, offset.Unit * (distance - 0.5), params)
		if blocked and blocked.Instance ~= hit then
			return false
		end
	end
	return true
end

local function replicateShot(shooter: Player, payload: ShotReplication)
	for _, other in Players:GetPlayers() do
		if other ~= shooter then
			local character = other.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and (root.Position - payload.Origin).Magnitude <= REPLICATION_RADIUS then
				shotReplicated:FireClient(other, payload)
			end
		end
	end
end

local function onFire(player: Player, payload: any)
	if not fireLimiter:Allow(player) then
		return
	end
	local loadout = loadouts[player]
	if not loadout or typeof(payload) ~= "table" then
		return
	end
	local character = player.Character
	if character ~= loadout.Character or character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head")
	local root = character:FindFirstChild("HumanoidRootPart")
	if
		not humanoid
		or humanoid.Health <= 0
		or not head
		or not head:IsA("BasePart")
		or not root
		or not root:IsA("BasePart")
	then
		return
	end

	if payload.Slot ~= loadout.Equipped then
		sendAmmo(player)
		return
	end
	local state = getSlot(loadout, loadout.Equipped)
	local def = state.Def
	local now = os.clock()

	if state.ReloadingUntil > 0 then
		if now >= state.ReloadingUntil - 0.1 then
			completeReload(player, state)
		else
			sendAmmo(player)
			return
		end
	end
	if state.Mag <= 0 or not consumeFireToken(state, now) then
		sendAmmo(player)
		return
	end

	local origin = payload.Origin
	local shots = payload.Shots
	if not Ballistics.IsFiniteVector(origin) or typeof(shots) ~= "table" then
		return
	end
	local originVector = origin :: Vector3
	local maxOffset = MAX_ORIGIN_OFFSET + root.AssemblyLinearVelocity.Magnitude * LATENCY_LEAD
	local shotCount = #shots
	if (originVector - head.Position).Magnitude > maxOffset or shotCount < 1 or shotCount > def.Pellets then
		sendAmmo(player)
		return
	end

	state.Mag -= 1

	-- Shooting ends spawn protection.
	local forceField = character:FindFirstChildOfClass("ForceField")
	if forceField then
		forceField:Destroy()
	end

	local profile = DataService.GetProfile(player)
	if profile then
		profile.Stats.ShotsFired += 1
	end

	local params = worldOnlyParams()
	local pending: { [Humanoid]: PendingHit } = {}
	local ends: { Vector3 } = {}

	for index = 1, shotCount do
		local shot = shots[index]
		if typeof(shot) ~= "table" then
			continue
		end
		local direction = shot.Dir
		if not Ballistics.IsFiniteVector(direction) or math.abs((direction :: Vector3).Magnitude - 1) > 0.02 then
			continue
		end
		local dir = (direction :: Vector3).Unit
		local endPosition = originVector + dir * def.Range

		local hit = shot.Hit
		local position = shot.Pos
		if
			typeof(hit) == "Instance"
			and hit:IsA("BasePart")
			and hit:IsDescendantOf(workspace)
			and Ballistics.IsFiniteVector(position)
		then
			local hitPart = hit :: BasePart
			local hitPosition = position :: Vector3
			if validateHit(def, originVector, dir, hitPart, hitPosition, params) then
				endPosition = hitPosition
				local _, targetHumanoid = CombatService.FindHumanoid(hitPart)
				if targetHumanoid and targetHumanoid ~= humanoid then
					local headshot = isHeadshot(hitPart)
					local damage = Ballistics.DamageAt(def, (hitPosition - originVector).Magnitude)
					if headshot then
						damage *= def.HeadshotMultiplier
					end
					local entry = pending[targetHumanoid]
					if entry then
						entry.Damage += damage
						entry.Headshot = entry.Headshot or headshot
						entry.Position = hitPosition
					else
						pending[targetHumanoid] = { Damage = damage, Headshot = headshot, Position = hitPosition }
					end
				end
			end
		end
		table.insert(ends, endPosition)
	end

	local hits: { HitInfo } = {}
	for targetHumanoid, entry in pending do
		local dealt, killed = CombatService.DamageHumanoid(player, targetHumanoid, entry.Damage, {
			WeaponId = def.Id,
			Headshot = entry.Headshot,
			SourcePosition = originVector,
		})
		if dealt > 0 then
			table.insert(hits, {
				Position = entry.Position,
				Damage = math.floor(dealt + 0.5),
				Headshot = entry.Headshot,
				Killed = killed,
			})
		end
	end
	if #hits > 0 then
		if profile then
			profile.Stats.ShotsHit += 1
		end
		hitConfirm:FireClient(player, hits)
	end

	replicateShot(player, {
		Shooter = player,
		Weapon = def.Id,
		Origin = originVector,
		Ends = ends,
	})
end

local function onReload(player: Player)
	if not actionLimiter:Allow(player) then
		return
	end
	local loadout = loadouts[player]
	if not loadout then
		return
	end
	local state = getSlot(loadout, loadout.Equipped)
	local def = state.Def
	if state.ReloadingUntil > 0 or state.Mag >= def.MagSize or state.Reserve <= 0 then
		return
	end
	state.ReloadToken += 1
	local token = state.ReloadToken
	local duration = math.max(0.3, def.ReloadTime - RELOAD_GRACE)
	state.ReloadingUntil = os.clock() + duration
	task.delay(duration, function()
		if loadouts[player] == loadout and state.ReloadToken == token and state.ReloadingUntil > 0 then
			completeReload(player, state)
		end
	end)
end

local function onEquip(player: Player, slot: any)
	if not actionLimiter:Allow(player) then
		return
	end
	if slot ~= "Primary" and slot ~= "Secondary" then
		return
	end
	local loadout = loadouts[player]
	if not loadout or loadout.Equipped == slot then
		return
	end
	cancelReload(getSlot(loadout, loadout.Equipped))
	loadout.Equipped = slot
	attachWorldModel(loadout)
end

-- Called by PlayerService for every new character. Gives full ammo.
function WeaponService.SetupCharacter(player: Player, character: Model, keepEquipped: boolean?)
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	local primary = Weapons.Get(profile.Loadout.Primary) or Weapons.ById[Weapons.DefaultLoadout.Primary]
	local secondary = Weapons.Get(profile.Loadout.Secondary) or Weapons.ById[Weapons.DefaultLoadout.Secondary]
	local previous = loadouts[player]
	local equipped: Slot = if keepEquipped and previous then previous.Equipped else "Primary"
	if previous and previous.WorldModel then
		previous.WorldModel:Destroy()
	end

	local loadout: Loadout = {
		Character = character,
		Primary = newState(primary),
		Secondary = newState(secondary),
		Equipped = equipped,
	}
	loadouts[player] = loadout
	attachWorldModel(loadout)
	sendAmmo(player)
end

-- Re-reads the profile loadout (after buying/equipping in the Armory).
function WeaponService.RefreshLoadout(player: Player)
	local character = player.Character
	if character and loadouts[player] then
		WeaponService.SetupCharacter(player, character, true)
	end
end

function WeaponService.RefillAll(player: Player)
	local loadout = loadouts[player]
	if not loadout then
		return
	end
	for _, state in { loadout.Primary, loadout.Secondary } do
		cancelReload(state)
		state.Mag = state.Def.MagSize
		state.Reserve = state.Def.ReserveAmmo
	end
	sendAmmo(player)
	ProgressionService.Notify(player, { Kind = "Info", Text = "Ammo fully restocked" })
end

-- Adds `magazines` worth of reserve ammo to both weapons.
function WeaponService.GiveAmmo(player: Player, magazines: number)
	local loadout = loadouts[player]
	if not loadout then
		return
	end
	for _, state in { loadout.Primary, loadout.Secondary } do
		local amount = math.ceil(state.Def.MagSize * magazines)
		state.Reserve = math.min(state.Def.ReserveAmmo, state.Reserve + amount)
	end
	sendAmmo(player)
	ProgressionService.Notify(player, { Kind = "Info", Text = "+ Ammo" })
end

function WeaponService.SpawnAmmoDrop(position: Vector3)
	local ground = workspace:Raycast(position + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), worldOnlyParams())
	local base = if ground then ground.Position else position

	local box = Instance.new("Part")
	box.Name = "AmmoBox"
	box.Size = Vector3.new(1.6, 1, 1.1)
	box.CFrame = CFrame.new(base + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
	box.Color = Color3.fromRGB(70, 90, 50)
	box.Material = Enum.Material.Metal
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false

	local stripe = Instance.new("Part")
	stripe.Name = "Stripe"
	stripe.Size = Vector3.new(1.62, 0.2, 1.12)
	stripe.CFrame = box.CFrame
	stripe.Color = Color3.fromRGB(255, 220, 60)
	stripe.Material = Enum.Material.Neon
	stripe.Anchored = true
	stripe.CanCollide = false
	stripe.CanQuery = false
	stripe.CanTouch = false
	stripe.Parent = box

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 220, 60)
	light.Range = 8
	light.Brightness = 1.5
	light.Parent = box

	local taken = false
	box.Touched:Connect(function(other: BasePart)
		if taken then
			return
		end
		local model = other:FindFirstAncestorOfClass("Model")
		local player = model and Players:GetPlayerFromCharacter(model)
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if player and humanoid and humanoid.Health > 0 and loadouts[player] then
			taken = true
			WeaponService.GiveAmmo(player, 1)
			box:Destroy()
		end
	end)

	box.Parent = WorldService.GetFolder("Drops")
	Debris:AddItem(box, 45)
end

function WeaponService.Init()
	Net.Event("WeaponFire").OnServerEvent:Connect(onFire)
	Net.Event("WeaponReload").OnServerEvent:Connect(onReload)
	Net.Event("WeaponEquip").OnServerEvent:Connect(onEquip)

	WorldService.ResupplyRequested:Connect(function(player: Player)
		WeaponService.RefillAll(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		loadouts[player] = nil
	end)
end

return WeaponService
