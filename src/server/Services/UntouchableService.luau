--!strict
-- UNTOUCHABLE: a dodge game in Haven. Pay the entry fee, then run down the
-- lane to the gunslinger. He fires telegraphed shots (bullet lines) that get
-- faster and fan out as you close in. Reach him untouched and you win the
-- jackpot, which grows with every entry fee paid.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EnemyRig = require(script.Parent.Parent.Util.EnemyRig)
local Enemies = require(ReplicatedStorage.Shared.Config.Enemies)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldService = require(script.Parent.WorldService)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type BulletLine = Types.BulletLine
type ShotReplication = Types.ShotReplication

type Run = {
	Player: Player,
	GoTime: number, -- when the countdown ends
	NextShot: number,
}

local UntouchableService = {}

local ENTRY_FEE = 300
local BASE_JACKPOT = 3000
local TIME_LIMIT = 20
local LANE_TOLERANCE = 1.5
local TRACER_RADIUS = 300

local GUNSLINGER: Enemies.EnemyDef = {
	Id = "Gunslinger",
	DisplayName = "The Gunslinger",
	Level = 99,
	Health = 1,
	WalkSpeed = 0,
	Damage = 0,
	TelegraphTime = 0,
	Burst = 0,
	FireInterval = 0,
	AttackCooldown = 0,
	Spread = 0,
	Pellets = 1,
	Lead = 0,
	AttackRange = 0,
	AggroRange = 0,
	LeashRange = 0,
	XP = 0,
	Credits = 0,
	AmmoDropChance = 0,
	RespawnTime = 0,
	Scale = 1.1,
	Colors = {
		Skin = Color3.fromRGB(190, 140, 105),
		Torso = Color3.fromRGB(120, 60, 40),
		Legs = Color3.fromRGB(50, 44, 40),
		Visor = Color3.fromRGB(255, 200, 60),
	},
	Weapon = "Revolver",
}

local jackpot = BASE_JACKPOT
local current: Run? = nil
local lane: WorldService.UntouchableLane
local gunslinger: Model
local muzzle: Attachment?

local bulletLineRemote = Net.Event("BulletLine")
local shotReplicated = Net.Unreliable("ShotReplicated")
local rng = Random.new()

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function updateSign()
	lane.Sign.Text = `UNTOUCHABLE\nJACKPOT  ¢{Format.Commas(jackpot)}`
end

local function aliveRoot(player: Player): (Model?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character and humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return character, root
	end
	return nil, nil
end

local function clearLines(player: Player)
	for index = 1, 3 do
		bulletLineRemote:FireClient(
			player,
			{
				Id = `U{index}`,
				From = Vector3.zero,
				To = Vector3.zero,
				Duration = 0,
				TargetsYou = false,
			} :: BulletLine
		)
	end
end

local function finish(won: boolean, message: string)
	local run = current
	if not run then
		return
	end
	current = nil
	local player = run.Player
	if not player.Parent then
		return
	end
	clearLines(player)

	if won then
		local prize = jackpot
		jackpot = BASE_JACKPOT
		ProgressionService.AwardCredits(player, prize)
		ProgressionService.Notify(
			player,
			{ Kind = "Jackpot", Text = `You won ¢{Format.Commas(prize)}!`, Amount = prize }
		)
		for _, other in Players:GetPlayers() do
			if other ~= player then
				ProgressionService.Notify(other, {
					Kind = "Info",
					Text = `{player.DisplayName} beat UNTOUCHABLE and won ¢{Format.Commas(prize)}!`,
				})
			end
		end
	else
		ProgressionService.Notify(player, { Kind = "Warning", Text = message })
	end

	local character = aliveRoot(player)
	if character then
		task.delay(if won then 1.5 else 0.8, function()
			if player.Character == character then
				character:PivotTo(lane.Exit)
			end
		end)
	end
	updateSign()
end

local function faceGunslinger(point: Vector3)
	local pivot = gunslinger:GetPivot()
	local target = Vector3.new(point.X, pivot.Position.Y, point.Z)
	if (target - pivot.Position).Magnitude > 0.5 then
		gunslinger:PivotTo(CFrame.lookAt(pivot.Position, target))
	end
end

local function fire(run: Run, root: BasePart, telegraph: number, pattern: number)
	local player = run.Player
	faceGunslinger(root.Position)
	local origin = if muzzle then muzzle.WorldPosition else gunslinger:GetPivot().Position + Vector3.new(0, 1.5, 0)

	-- Aim ahead of a moving runner; extra lines fan out to either side.
	local velocity = root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
	local base = root.Position + velocity * telegraph * 0.6
	local offsets: { number } = if pattern == 1
		then { 0 }
		elseif pattern == 2 then { 0, if rng:NextNumber() < 0.5 then -3.5 else 3.5 }
		else { -4.5, 0, 4.5 }

	for index, offset in offsets do
		local z = math.clamp(base.Z + offset, lane.Z - lane.HalfWidth, lane.Z + lane.HalfWidth)
		local point = Vector3.new(base.X, root.Position.Y + 0.3, z)
		local direction = (point - origin).Unit
		local length = (point - origin).Magnitude + 20
		bulletLineRemote:FireClient(
			player,
			{
				Id = `U{index}`,
				Shooter = gunslinger,
				From = origin,
				To = origin + direction * length,
				Duration = telegraph + 0.15,
				TargetsYou = true,
			} :: BulletLine
		)

		task.delay(telegraph, function()
			if current ~= run then
				return
			end
			local character = player.Character
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = if character then { character } else {}
			local result = workspace:Raycast(origin, direction * length, params)

			local tracer: ShotReplication = {
				Shooter = gunslinger,
				Weapon = "Enemy",
				Origin = origin,
				Ends = { if result then result.Position else origin + direction * length },
			}
			for _, other in Players:GetPlayers() do
				local _, otherRoot = aliveRoot(other)
				if otherRoot and (otherRoot.Position - origin).Magnitude <= TRACER_RADIUS then
					shotReplicated:FireClient(other, tracer)
				end
			end
			if result then
				finish(false, `HIT! The gunslinger keeps your ¢{ENTRY_FEE}.`)
			end
		end)
	end
end

local function update()
	local run = current
	if not run then
		return
	end
	local player = run.Player
	local character, root = aliveRoot(player)
	if not player.Parent or not character or not root then
		finish(false, "Run over.")
		return
	end
	local now = os.clock()

	if now < run.GoTime then
		-- No head starts during the countdown.
		if (root.Position - lane.Start.Position).Magnitude > 4 then
			character:PivotTo(lane.Start)
		end
		return
	end

	local position = root.Position
	if position.X >= lane.GoalX then
		finish(true, "")
		return
	end
	local outside = position.X < lane.StartX - 4
		or math.abs(position.Z - lane.Z) > lane.HalfWidth + LANE_TOLERANCE
		or position.Y > 14
	if outside then
		finish(false, "You left the lane. Entry fee lost.")
		return
	end
	if now - run.GoTime > TIME_LIMIT then
		finish(false, "Time's up!")
		return
	end

	if now >= run.NextShot then
		local progress = math.clamp((position.X - lane.StartX) / (lane.GoalX - lane.StartX), 0, 1)
		local telegraph = lerp(0.6, 0.32, progress)
		local interval = lerp(1.1, 0.5, progress)
		local pattern = if progress < 0.35 then 1 elseif progress < 0.7 then 2 else 3
		fire(run, root, telegraph, pattern)
		run.NextShot = now + telegraph + interval
	end
end

local function start(player: Player)
	local character, root = aliveRoot(player)
	if not character or not root or not Zones.IsSafeAt(root.Position) then
		return
	end
	if current then
		ProgressionService.Notify(player, { Kind = "Warning", Text = "Someone is running the lane. Wait your turn." })
		return
	end
	if not ProgressionService.SpendCredits(player, ENTRY_FEE) then
		ProgressionService.Notify(player, { Kind = "Warning", Text = `UNTOUCHABLE costs ¢{ENTRY_FEE} to play.` })
		return
	end
	jackpot += ENTRY_FEE
	updateSign()

	local now = os.clock()
	local run: Run = { Player = player, GoTime = now + 3, NextShot = now + 3.4 }
	current = run
	character:PivotTo(lane.Start)
	for step = 0, 3 do
		task.delay(step, function()
			if current == run and player.Parent then
				ProgressionService.Notify(player, {
					Kind = "Info",
					Text = if step < 3 then `UNTOUCHABLE in {3 - step}...` else "GO! Dodge the bullet lines!",
				})
			end
		end)
	end
end

function UntouchableService.Init()
	local found = WorldService.GetUntouchableLane()
	if not found then
		warn("[UntouchableService] No lane in the world; minigame disabled")
		return
	end
	lane = found

	local rig = EnemyRig.Create(GUNSLINGER)
	rig.Humanoid:Destroy()
	local bar = rig.Head:FindFirstChild("HealthBar")
	if bar then
		bar:Destroy()
	end
	rig.Root.Anchored = true
	rig.Model.Name = "Gunslinger"
	rig.Model:PivotTo(lane.Gunslinger + Vector3.new(0, 3 * GUNSLINGER.Scale, 0))
	rig.Model.Parent = WorldService.GetFolder("World")
	gunslinger = rig.Model
	muzzle = rig.Muzzle

	updateSign()
	WorldService.UntouchableRequested:Connect(start)
	RunService.Heartbeat:Connect(update)
	Players.PlayerRemoving:Connect(function(player: Player)
		local run = current
		if run and run.Player == player then
			current = nil
		end
	end)
end

return UntouchableService
