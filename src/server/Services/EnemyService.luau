--!strict
-- Spawns and drives every NPC. A single throttled loop runs all enemy AI:
-- wander near the spawn anchor, acquire visible players (or whoever shot
-- them), chase until in range with line of sight, then strafe and fire.
-- Enemies leash back to their anchor if pulled too far and never enter the
-- safe zone.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local CombatService = require(script.Parent.CombatService)
local EnemyRig = require(script.Parent.Parent.Util.EnemyRig)
local Enemies = require(ReplicatedStorage.Shared.Config.Enemies)
local Net = require(ReplicatedStorage.Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponService = require(script.Parent.WeaponService)
local WorldService = require(script.Parent.WorldService)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type EnemyDef = Enemies.EnemyDef
type ZoneDef = Zones.ZoneDef
type Rig = EnemyRig.Rig
type ShotReplication = Types.ShotReplication

type Enemy = {
	Def: EnemyDef,
	Rig: Rig,
	Zone: ZoneDef,
	Anchor: CFrame,
	FixedAnchor: boolean,
	Target: Player?,
	LastShot: number,
	NextWander: number,
	NextStrafe: number,
	LastPosition: Vector3,
	StuckTime: number,
	Returning: boolean,
	Alive: boolean,
}

local EnemyService = {}

local TICK = 0.15
local WALK_ANIMATION = "rbxassetid://180426354" -- default R6 walk
local IDLE_ANIMATION = "rbxassetid://180435571" -- default R6 idle
local TRACER_RADIUS = 600
local CORPSE_TIME = 4

local enemies: { Enemy } = {}
local rng = Random.new()
local shotReplicated = Net.Unreliable("ShotReplicated")
local shotParams = RaycastParams.new()

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function characterRoot(player: Player): (Model?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil, nil
	end
	return character, root
end

local function isValidTarget(player: Player): (Model?, BasePart?)
	local character, root = characterRoot(player)
	if not character or not root or Zones.IsSafeAt(root.Position) then
		return nil, nil
	end
	return character, root
end

local function hasLineOfSight(from: Vector3, character: Model, to: Vector3): boolean
	local result = workspace:Raycast(from, to - from, shotParams)
	return result == nil or result.Instance:IsDescendantOf(character)
end

local function pickSpawnPoint(zone: ZoneDef): Vector3
	local points = WorldService.GetSpawnPoints(zone.Id)
	if #points == 0 then
		return zone.Center
	end
	local best, bestDistance = points[1], -1
	for _ = 1, 6 do
		local candidate = points[rng:NextInteger(1, #points)]
		local nearest = math.huge
		for _, player in Players:GetPlayers() do
			local _, root = characterRoot(player)
			if root then
				nearest = math.min(nearest, (root.Position - candidate).Magnitude)
			end
		end
		if nearest > 90 then
			return candidate
		end
		if nearest > bestDistance then
			best, bestDistance = candidate, nearest
		end
	end
	return best
end

local function replicateTracer(payload: ShotReplication)
	for _, player in Players:GetPlayers() do
		local _, root = characterRoot(player)
		if root and (root.Position - payload.Origin).Magnitude <= TRACER_RADIUS then
			shotReplicated:FireClient(player, payload)
		end
	end
end

local function loadAnimations(rig: Rig)
	local animator = rig.Humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local function load(id: string): AnimationTrack?
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		return if ok then track else nil
	end
	local walk = load(WALK_ANIMATION)
	local idle = load(IDLE_ANIMATION)
	if idle then
		idle.Looped = true
		idle:Play()
	end
	rig.Humanoid.Running:Connect(function(speed: number)
		if not walk then
			return
		end
		if speed > 0.5 then
			if not walk.IsPlaying then
				walk.Looped = true
				walk:Play(0.2)
			end
			walk:AdjustSpeed(speed / 14)
		elseif walk.IsPlaying then
			walk:Stop(0.2)
		end
	end)
end

local spawnEnemy: (def: EnemyDef, zone: ZoneDef, anchor: CFrame?) -> ()

local function onEnemyGone(enemy: Enemy, killed: boolean)
	if not enemy.Alive then
		return
	end
	enemy.Alive = false
	local index = table.find(enemies, enemy)
	if index then
		table.remove(enemies, index)
	end

	local def = enemy.Def
	if killed then
		if rng:NextNumber() < def.AmmoDropChance then
			WeaponService.SpawnAmmoDrop(enemy.Rig.Root.Position)
		end
		task.delay(CORPSE_TIME, function()
			enemy.Rig.Model:Destroy()
		end)
	else
		enemy.Rig.Model:Destroy()
	end

	task.delay(def.RespawnTime, function()
		spawnEnemy(def, enemy.Zone, if enemy.FixedAnchor then enemy.Anchor else nil)
	end)
end

spawnEnemy = function(def: EnemyDef, zone: ZoneDef, anchor: CFrame?)
	local rig = EnemyRig.Create(def)
	local fixed = anchor ~= nil
	local spot = anchor or CFrame.new(pickSpawnPoint(zone)) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	rig.Model:PivotTo(spot + Vector3.new(0, 3 * def.Scale + 0.2, 0))
	rig.Model.Parent = WorldService.GetFolder("Enemies")

	if def.Passive then
		rig.Root.Anchored = true
	else
		-- Server-owned physics: no player client can move enemies around.
		pcall(function()
			rig.Root:SetNetworkOwner(nil)
		end)
		loadAnimations(rig)
	end

	local enemy: Enemy = {
		Def = def,
		Rig = rig,
		Zone = zone,
		Anchor = spot,
		FixedAnchor = fixed,
		Target = nil,
		LastShot = 0,
		NextWander = 0,
		NextStrafe = 0,
		LastPosition = rig.Root.Position,
		StuckTime = 0,
		Returning = false,
		Alive = true,
	}
	table.insert(enemies, enemy)

	local humanoid = rig.Humanoid
	humanoid.HealthChanged:Connect(function(health: number)
		rig.HealthFill.Size = UDim2.fromScale(math.clamp(health / humanoid.MaxHealth, 0, 1), 1)
	end)
	humanoid.Died:Once(function()
		onEnemyGone(enemy, true)
	end)
	rig.Model.AncestryChanged:Connect(function()
		-- Fell out of the world or was removed some other way.
		if enemy.Alive and not rig.Model:IsDescendantOf(workspace) then
			onEnemyGone(enemy, false)
		end
	end)

	if def.Boss then
		ProgressionService.NotifyAll({
			Kind = "Boss",
			Text = `{def.DisplayName} has emerged in {zone.DisplayName}!`,
		})
	end
end

local function acquireTarget(enemy: Enemy): Player?
	local def = enemy.Def
	local rootPosition = enemy.Rig.Root.Position

	-- Retaliate against whoever shot us, even from outside aggro range.
	local attack = CombatService.GetLastAttack(enemy.Rig.Humanoid, 8)
	if attack and typeof(attack.Attacker) == "Instance" and attack.Attacker:IsA("Player") then
		local attacker = attack.Attacker :: Player
		local _, root = isValidTarget(attacker)
		if root and (root.Position - rootPosition).Magnitude <= def.AggroRange * 2.5 then
			return attacker
		end
	end

	local best: Player? = nil
	local bestDistance = def.AggroRange
	for _, player in Players:GetPlayers() do
		local character, root = isValidTarget(player)
		if character and root then
			local distance = (root.Position - rootPosition).Magnitude
			if distance < bestDistance and hasLineOfSight(enemy.Rig.Head.Position, character, root.Position) then
				best, bestDistance = player, distance
			end
		end
	end
	return best
end

local function updateStuck(enemy: Enemy)
	local position = enemy.Rig.Root.Position
	local humanoid = enemy.Rig.Humanoid
	if humanoid.MoveDirection.Magnitude > 0.1 and (position - enemy.LastPosition).Magnitude < 0.3 then
		enemy.StuckTime += TICK
		if enemy.StuckTime > 0.8 then
			humanoid.Jump = true
			enemy.StuckTime = 0
		end
	else
		enemy.StuckTime = 0
	end
	enemy.LastPosition = position
end

local function faceTowards(root: BasePart, point: Vector3)
	local target = Vector3.new(point.X, root.Position.Y, point.Z)
	if (target - root.Position).Magnitude > 0.1 then
		root.CFrame = CFrame.lookAt(root.Position, target)
	end
end

local function fireAt(enemy: Enemy, character: Model, targetRoot: BasePart)
	local def = enemy.Def
	local rig = enemy.Rig
	local origin = if rig.Muzzle then rig.Muzzle.WorldPosition else rig.Head.Position
	local head = character:FindFirstChild("Head")
	local aimPart: BasePart = if head and head:IsA("BasePart") and rng:NextNumber() < 0.15 then head else targetRoot
	local toTarget = aimPart.Position - origin
	local distance = toTarget.Magnitude
	if distance < 0.1 then
		return
	end

	-- Accuracy drops with range and against fast-moving targets.
	local rangeFactor = math.clamp(1 - 0.5 * distance / math.max(def.AttackRange, 1), 0.35, 1)
	local speedFactor = math.clamp(1 - targetRoot.AssemblyLinearVelocity.Magnitude / 60, 0.6, 1)
	local hitChance = def.Accuracy * rangeFactor * speedFactor
	local direction = if rng:NextNumber() < hitChance
		then toTarget.Unit
		else Ballistics.ConeDirection(toTarget, rng:NextNumber(2.5, 6), rng)

	local range = def.AttackRange * 1.5
	local result = workspace:Raycast(origin, direction * range, shotParams)
	local endPosition = if result then result.Position else origin + direction * range
	if result then
		local _, humanoid = CombatService.FindHumanoid(result.Instance)
		if humanoid then
			CombatService.DamageHumanoid(rig.Model, humanoid, def.Damage, {
				WeaponId = def.Id,
				SourcePosition = origin,
			})
		end
	end

	replicateTracer({
		Shooter = rig.Model,
		Weapon = "Enemy",
		Origin = origin,
		Ends = { endPosition },
	})
end

local function updateEnemy(enemy: Enemy, now: number)
	local def = enemy.Def
	local rig = enemy.Rig
	local humanoid = rig.Humanoid
	if humanoid.Health <= 0 then
		return
	end

	if def.Passive then
		-- Training dummies heal to full a few seconds after the last hit.
		local last = humanoid:GetAttribute("LastDamaged")
		if typeof(last) == "number" and os.clock() - last > 4 and humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = humanoid.MaxHealth
		end
		return
	end

	local position = rig.Root.Position
	local anchor = enemy.Anchor.Position
	local fromAnchor = flat(position - anchor).Magnitude

	if fromAnchor > def.LeashRange or Zones.IsSafeAt(position) then
		enemy.Returning = true
		enemy.Target = nil
	end
	if enemy.Returning then
		humanoid.AutoRotate = true
		humanoid.WalkSpeed = def.WalkSpeed * 1.3
		humanoid:MoveTo(anchor)
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + humanoid.MaxHealth * 0.03)
		if fromAnchor < 12 then
			enemy.Returning = false
		end
		updateStuck(enemy)
		return
	end

	local target = enemy.Target
	if target then
		local _, root = isValidTarget(target)
		if not root or (root.Position - position).Magnitude > def.AggroRange * 2.5 then
			target = nil
		end
	end
	if not target then
		target = acquireTarget(enemy)
		if target then
			-- Brief reaction time before the first shot.
			enemy.LastShot = now - def.FireInterval + 0.5
		end
	end
	enemy.Target = target

	if not target then
		humanoid.AutoRotate = true
		if now >= enemy.NextWander then
			enemy.NextWander = now + rng:NextNumber(4, 9)
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = rng:NextNumber(5, 25)
			humanoid.WalkSpeed = def.WalkSpeed * 0.5
			humanoid:MoveTo(anchor + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
		end
		updateStuck(enemy)
		return
	end

	local character, targetRoot = isValidTarget(target)
	if not character or not targetRoot then
		return
	end
	humanoid.WalkSpeed = def.WalkSpeed
	local distance = (targetRoot.Position - position).Magnitude
	local visible = hasLineOfSight(rig.Head.Position, character, targetRoot.Position)

	if distance > def.AttackRange or not visible then
		humanoid.AutoRotate = true
		humanoid:MoveTo(targetRoot.Position)
		enemy.NextStrafe = 0
	else
		humanoid.AutoRotate = false
		if now >= enemy.NextStrafe then
			enemy.NextStrafe = now + rng:NextNumber(1.2, 2.6)
			local toTarget = flat(targetRoot.Position - position)
			if toTarget.Magnitude > 0.1 then
				humanoid:MoveTo(position + toTarget.Unit:Cross(Vector3.yAxis) * rng:NextNumber(-10, 10))
			end
		end
		faceTowards(rig.Root, targetRoot.Position)

		if now - enemy.LastShot > def.FireInterval * 3 then
			enemy.LastShot = now - def.FireInterval
		end
		local shots = 0
		while now - enemy.LastShot >= def.FireInterval and shots < 3 do
			enemy.LastShot += def.FireInterval
			shots += 1
			fireAt(enemy, character, targetRoot)
		end
	end
	updateStuck(enemy)
end

function EnemyService.GetEnemyCount(): number
	return #enemies
end

function EnemyService.Init()
	shotParams.FilterType = Enum.RaycastFilterType.Exclude
	shotParams.FilterDescendantsInstances = { WorldService.GetFolder("Enemies"), WorldService.GetFolder("Drops") }
	shotParams.IgnoreWater = true
end

function EnemyService.Start()
	for _, spot in WorldService.GetDummySpots() do
		spawnEnemy(Enemies.ById.Dummy, Zones.ById[Zones.HubId], spot)
	end

	for _, zone in Zones.List do
		for _, entry in zone.Enemies do
			local def = Enemies.Get(entry.Id)
			if not def then
				warn(`[EnemyService] Unknown enemy "{entry.Id}" in zone {zone.Id}`)
				continue
			end
			local bossSpot = if def.Boss then WorldService.GetBossSpot(zone.Id) else nil
			for _ = 1, entry.Count do
				spawnEnemy(def, zone, if bossSpot then CFrame.new(bossSpot) else nil)
			end
		end
	end

	task.spawn(function()
		while true do
			task.wait(TICK)
			local now = os.clock()
			for _, enemy in table.clone(enemies) do
				if enemy.Alive then
					local ok, err: any = pcall(updateEnemy, enemy, now)
					if not ok then
						warn(`[EnemyService] AI error on {enemy.Def.Id}: {err}`)
					end
				end
			end
		end
	end)
end

return EnemyService
