--!strict
-- Server-authoritative weapons. The server owns every player's loadout, ammo,
-- fire rate and reload timing. Clients raycast locally for responsiveness and
-- send hit claims, which are validated here before any damage is dealt:
--   * the shot origin must be near the shooter's head
--   * fire rate is enforced with a token bucket (tolerates network jitter)
--   * each claimed hit must lie on the claimed ray, within weapon range,
--     near the claimed part (with latency leeway) and with clear line of
--     sight through world geometry.
--
-- It also relays bullet lines: while a player aims at someone in a PvP zone,
-- the target sees a red prediction line. A shooter who has not fired for a
-- while stays hidden, so the first shot from an unseen sniper has no line.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Inventory = require(ReplicatedStorage.Shared.Inventory)
local Items = require(ReplicatedStorage.Shared.Config.Items)
local CombatService = require(script.Parent.CombatService)
local DataService = require(script.Parent.DataService)
local Net = require(ReplicatedStorage.Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponModel = require(ReplicatedStorage.Shared.WeaponModel)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local WorldService = require(script.Parent.WorldService)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type WeaponDef = Weapons.WeaponDef
type Slot = Weapons.Slot
type AmmoState = Types.AmmoState
type HitInfo = Types.HitInfo
type ShotReplication = Types.ShotReplication
type BulletLine = Types.BulletLine

type WeaponState = {
	Def: WeaponDef,
	Uid: string, -- inventory item
	Rarity: string,
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

local function statsOf(player: Player): Attributes.AttributeSet
	local profile = DataService.GetProfile(player)
	return if profile then profile.Attributes else Attributes.Default()
end

local WeaponService = {}

local MAX_ORIGIN_OFFSET = 8 -- studs between claimed origin and the shooter's head
local HIT_TOLERANCE = 3 -- studs of slack around the claimed hit part
local LATENCY_LEAD = 0.3 -- seconds of target movement tolerated
local RELOAD_GRACE = 0.2 -- server finishes reloads early to absorb latency
local FIRE_RATE_SLACK = 1.1
local REPLICATION_RADIUS = 1000
local REVEAL_TIME = 8 -- seconds after firing during which your aim shows a bullet line
local AIM_LINE_RADIUS = 3.5 -- studs from the aim ray that count as "aimed at"
local AIM_LINE_DURATION = 0.35

local loadouts: { [Player]: Loadout } = {}
-- Ammo left in weapons swapped out this life, by inventory Uid, so swapping
-- guns back and forth can't refill them.
local ammoMemory: { [Player]: { [string]: AmmoMemory } } = {}
local lastFired: { [Player]: number } = {}
local rng = Random.new()

local ammoUpdate = Net.Event("AmmoUpdate")
local hitConfirm = Net.Event("HitConfirm")
local shotReplicated = Net.Unreliable("ShotReplicated")
local bulletLineRemote = Net.Event("BulletLine")

local fireLimiter = RateLimiter.new(40, 20)
local actionLimiter = RateLimiter.new(15, 10)
local aimLimiter = RateLimiter.new(12, 12)

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

type AmmoMemory = {
	Mag: number,
	Reserve: number,
}

local function newState(def: WeaponDef, uid: string, rarity: string, ammo: AmmoMemory?): WeaponState
	local _, capacity = fireBudget(def)
	return {
		Def = def,
		Uid = uid,
		Rarity = rarity,
		Mag = if ammo then ammo.Mag else def.MagSize,
		Reserve = if ammo then ammo.Reserve else def.ReserveAmmo,
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
		Primary = {
			Id = loadout.Primary.Def.Id,
			Mag = loadout.Primary.Mag,
			Reserve = loadout.Primary.Reserve,
			Rarity = loadout.Primary.Rarity,
		},
		Secondary = {
			Id = loadout.Secondary.Def.Id,
			Mag = loadout.Secondary.Mag,
			Reserve = loadout.Secondary.Reserve,
			Rarity = loadout.Secondary.Rarity,
		},
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

	local melee = def.Melee == true
	if state.ReloadingUntil > 0 and not melee then
		if now >= state.ReloadingUntil - 0.1 then
			completeReload(player, state)
		else
			sendAmmo(player)
			return
		end
	end
	if (state.Mag <= 0 and not melee) or not consumeFireToken(state, now) then
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

	if not melee then
		state.Mag -= 1
	end
	lastFired[player] = now

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
					damage *= Items.DamageMultiplier(state.Rarity)
					local entry = pending[targetHumanoid]
					if entry and melee then
						-- A swing's rays fan out; count the best one, not all of them.
						entry.Damage = math.max(entry.Damage, damage)
						entry.Headshot = entry.Headshot or headshot
					elseif entry then
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
	local critChance = Attributes.CritChance(statsOf(player).LUK)
	for targetHumanoid, entry in pending do
		local critical = rng:NextNumber() < critChance
		local damage = if critical then entry.Damage * Attributes.CritMultiplier else entry.Damage
		local dealt, killed = CombatService.DamageHumanoid(player, targetHumanoid, damage, {
			WeaponId = def.Id,
			Headshot = entry.Headshot,
			SourcePosition = originVector,
			DamageType = def.Ammo,
		})
		if dealt > 0 then
			table.insert(hits, {
				Position = entry.Position,
				Damage = math.floor(dealt + 0.5),
				Headshot = entry.Headshot,
				Critical = critical,
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
	if def.Melee or state.ReloadingUntil > 0 or state.Mag >= def.MagSize or state.Reserve <= 0 then
		return
	end
	state.ReloadToken += 1
	local token = state.ReloadToken
	local reloadTime = def.ReloadTime * Attributes.ReloadMultiplier(statsOf(player).DEX)
	local duration = math.max(0.3, reloadTime - RELOAD_GRACE)
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
	loadout.Character:SetAttribute("Guarding", nil)
	loadout.Equipped = slot
	attachWorldModel(loadout)
end

-- Guarding with a blade: CombatService deflects bullets from the front.
local function onGuard(player: Player, guarding: any)
	if not actionLimiter:Allow(player) then
		return
	end
	local loadout = loadouts[player]
	if not loadout then
		return
	end
	local def = getSlot(loadout, loadout.Equipped).Def
	loadout.Character:SetAttribute("Guarding", if guarding == true and def.Melee then true else nil)
end

-- While a revealed player aims at someone in a PvP zone, show that target a
-- bullet line.
local function onAimLine(player: Player, payload: any)
	if not aimLimiter:Allow(player) or typeof(payload) ~= "table" then
		return
	end
	local loadout = loadouts[player]
	local fired = lastFired[player]
	if not loadout or not fired or os.clock() - fired > REVEAL_TIME then
		return
	end
	local def = getSlot(loadout, loadout.Equipped).Def
	local character = loadout.Character
	local head = character:FindFirstChild("Head")
	local root = character:FindFirstChild("HumanoidRootPart")
	if def.Melee or not head or not head:IsA("BasePart") or not root or not root:IsA("BasePart") then
		return
	end
	local origin, direction = payload.Origin, payload.Dir
	if not Ballistics.IsFiniteVector(origin) or not Ballistics.IsFiniteVector(direction) then
		return
	end
	local originVector = origin :: Vector3
	local dir = direction :: Vector3
	if math.abs(dir.Magnitude - 1) > 0.02 or (originVector - head.Position).Magnitude > MAX_ORIGIN_OFFSET * 2 then
		return
	end
	if not Zones.IsPvPAt(root.Position) then
		return
	end
	dir = dir.Unit

	local params = worldOnlyParams()
	for _, target in Players:GetPlayers() do
		if target == player then
			continue
		end
		local targetCharacter = target.Character
		local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
		if not targetRoot or not targetRoot:IsA("BasePart") or not Zones.IsPvPAt(targetRoot.Position) then
			continue
		end
		local offset = targetRoot.Position - originVector
		local along = offset:Dot(dir)
		if along <= 0 or along > def.Range or (offset - dir * along).Magnitude > AIM_LINE_RADIUS then
			continue
		end
		if workspace:Raycast(originVector, offset.Unit * math.max(0, offset.Magnitude - 2), params) then
			continue -- no line through walls
		end
		local line: BulletLine = {
			Id = `P{player.UserId}`,
			Shooter = player,
			From = originVector,
			To = originVector + dir * math.min(def.Range, along + 25),
			Duration = AIM_LINE_DURATION,
			TargetsYou = true,
		}
		bulletLineRemote:FireClient(target, line)
	end
end

-- The weapon equipped in a loadout slot, falling back to the default gun.
local function equippedWeapon(player: Player, slot: Slot): (WeaponDef, string, string)
	local profile = DataService.GetProfile(player)
	local item = if profile then Inventory.Equipped(profile, slot) else nil
	local def = if item then Weapons.Get(item.Id) else nil
	if item and def and def.Slot == slot then
		return def, item.Uid, item.Rarity
	end
	local fallback = if slot == "Primary" then Weapons.DefaultLoadout.Primary else Weapons.DefaultLoadout.Secondary
	return Weapons.ById[fallback], "", "Common"
end

-- Called by PlayerService for every new character. Gives full ammo.
function WeaponService.SetupCharacter(player: Player, character: Model)
	if not DataService.GetProfile(player) then
		return
	end
	local previous = loadouts[player]
	if previous and previous.WorldModel then
		previous.WorldModel:Destroy()
	end
	character:SetAttribute("Guarding", nil)
	ammoMemory[player] = {}

	local primary, primaryUid, primaryRarity = equippedWeapon(player, "Primary")
	local secondary, secondaryUid, secondaryRarity = equippedWeapon(player, "Secondary")
	local loadout: Loadout = {
		Character = character,
		Primary = newState(primary, primaryUid, primaryRarity),
		Secondary = newState(secondary, secondaryUid, secondaryRarity),
		Equipped = "Primary",
	}
	loadouts[player] = loadout
	attachWorldModel(loadout)
	sendAmmo(player)
end

-- Swaps the live weapon in a slot after the profile loadout changed. A gun
-- swapped back in keeps the ammo it had; a fresh gun comes fully loaded in
-- Haven but with only two magazines out in the field.
function WeaponService.EquipFromInventory(player: Player, slot: Slot)
	local loadout = loadouts[player]
	local character = player.Character
	if not loadout or loadout.Character ~= character or not character then
		return
	end
	local def, uid, rarity = equippedWeapon(player, slot)
	local old = getSlot(loadout, slot)
	if old.Uid == uid and old.Def == def then
		old.Rarity = rarity
		sendAmmo(player)
		return
	end

	cancelReload(old)
	local memory = ammoMemory[player] or {}
	ammoMemory[player] = memory
	if old.Uid ~= "" then
		memory[old.Uid] = { Mag = old.Mag, Reserve = old.Reserve }
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local inHaven = root ~= nil and root:IsA("BasePart") and Zones.IsSafeAt(root.Position)
	local ammo: AmmoMemory? = memory[uid]
	if not ammo and not inHaven then
		ammo = { Mag = def.MagSize, Reserve = if def.Melee then 0 else def.MagSize }
	end
	(memory :: any)[uid] = nil

	local state = newState(def, uid, rarity, ammo)
	if slot == "Primary" then
		loadout.Primary = state
	else
		loadout.Secondary = state
	end
	if loadout.Equipped == slot then
		character:SetAttribute("Guarding", nil)
		attachWorldModel(loadout)
	end
	sendAmmo(player)
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
	Net.Event("WeaponGuard").OnServerEvent:Connect(onGuard)
	Net.Unreliable("AimLine").OnServerEvent:Connect(onAimLine)

	WorldService.ResupplyRequested:Connect(function(player: Player)
		WeaponService.RefillAll(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		loadouts[player] = nil
		lastFired[player] = nil
		ammoMemory[player] = nil
	end)
end

return WeaponService
