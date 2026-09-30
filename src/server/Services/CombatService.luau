--!strict
-- The single path through which anything takes damage. Enforces zone rules
-- (safe hub, PvE-only zones, PvP zones), tracks damage contributions for
-- shared kill credit, pays out kills and runs player health regeneration.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local BountyService = require(script.Parent.BountyService)
local DataService = require(script.Parent.DataService)
local Enemies = require(ReplicatedStorage.Shared.Config.Enemies)
local Net = require(ReplicatedStorage.Shared.Net)
local Progression = require(ReplicatedStorage.Shared.Config.Progression)
local ProgressionService = require(script.Parent.ProgressionService)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type EnemyDef = Enemies.EnemyDef
type KillFeedEntry = Types.KillFeedEntry

export type Attacker = Player | Model

export type DamageInfo = {
	WeaponId: string?,
	Headshot: boolean?,
	SourcePosition: Vector3?,
	DamageType: string?, -- Weapons.AmmoType; nil = solid
}

-- Players wear anti-bullet fields that absorb most optical (laser) damage.
-- Monsters have none, which makes optical guns the hunter's choice.
local ANTI_BULLET_FIELD = 0.25
local OPTICAL_VS_MONSTERS = 1.15
local DEFLECT_ARC = math.cos(math.rad(55)) -- blade guard covers +/-55 degrees

export type AttackRecord = {
	Attacker: Attacker,
	Time: number,
	WeaponId: string?,
}

local CombatService = {}

-- Fired after a kill is processed: (humanoid: Humanoid, attacker: Attacker, info: DamageInfo)
CombatService.Killed = Signal.new()

local REGEN_TICK = 0.25

local contributions: { [Humanoid]: { [Player]: number } } = setmetatable({}, { __mode = "k" }) :: any
local lastAttack: { [Humanoid]: AttackRecord } = setmetatable({}, { __mode = "k" }) :: any
local dead: { [Humanoid]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local damageTaken = Net.Event("DamageTaken")
local killFeed = Net.Event("KillFeed")

local function asPlayer(attacker: Attacker): Player?
	if typeof(attacker) == "Instance" and attacker:IsA("Player") then
		return attacker :: Player
	end
	return nil
end

local function rootPosition(model: Instance?): Vector3?
	local root = model and model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- Walks up from a hit part to the model that owns a Humanoid.
function CombatService.FindHumanoid(instance: Instance): (Model?, Humanoid?)
	local model = instance:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return model, humanoid
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

function CombatService.GetEnemyDef(humanoid: Humanoid): EnemyDef?
	local model = humanoid.Parent
	if model and model:IsA("Model") then
		return Enemies.Get(model:GetAttribute("EnemyId"))
	end
	return nil
end

function CombatService.GetLastAttack(humanoid: Humanoid, maxAge: number): AttackRecord?
	local record = lastAttack[humanoid]
	if record and os.clock() - record.Time <= maxAge then
		return record
	end
	return nil
end

function CombatService.CanDamage(attacker: Attacker, humanoid: Humanoid): boolean
	if humanoid.Health <= 0 or dead[humanoid] then
		return false
	end
	local victimModel = humanoid.Parent
	if not victimModel or victimModel:FindFirstChildOfClass("ForceField") then
		return false
	end
	local victimPosition = rootPosition(victimModel)
	if not victimPosition then
		return false
	end
	local victimPlayer = Players:GetPlayerFromCharacter(victimModel)

	local attackerPlayer = asPlayer(attacker)
	if attackerPlayer then
		local character = attackerPlayer.Character
		local attackerHumanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not attackerHumanoid or attackerHumanoid.Health <= 0 then
			return false
		end
		if victimPlayer then
			local attackerPosition = rootPosition(character)
			return victimPlayer ~= attackerPlayer
				and attackerPosition ~= nil
				and Zones.IsPvPAt(victimPosition)
				and Zones.IsPvPAt(attackerPosition)
		end
		return CombatService.GetEnemyDef(humanoid) ~= nil
	end

	-- Enemies only hurt players, and never inside the safe zone.
	return victimPlayer ~= nil and not Zones.IsSafeAt(victimPosition)
end

local function weaponName(weaponId: string?): string
	local weapon = Weapons.Get(weaponId)
	if weapon then
		return weapon.DisplayName
	end
	local enemy = Enemies.Get(weaponId)
	return if enemy then enemy.DisplayName else ""
end

local function rewardEnemyKill(humanoid: Humanoid, def: EnemyDef, killer: Player?, info: DamageInfo)
	local credited: { Player } = {}
	local contributed: { [Player]: number } = contributions[humanoid] or {}
	local threshold = humanoid.MaxHealth * Progression.AssistThreshold
	for player, damage in contributed do
		if player.Parent and (player == killer or damage >= threshold) then
			table.insert(credited, player)
		end
	end
	if killer and not table.find(credited, killer) then
		table.insert(credited, killer)
	end

	if def.Passive then
		return
	end

	local zone = Zones.GetZoneAt(rootPosition(humanoid.Parent) or Vector3.zero)
	local zoneId = if zone then zone.Id else nil
	for _, player in credited do
		local xp = Progression.EnemyXP(def.XP, def.Level, ProgressionService.GetLevel(player))
		ProgressionService.AwardXP(player, xp, def.DisplayName)
		local profile = DataService.GetProfile(player)
		local luck = if profile then profile.Attributes.LUK else Attributes.Base
		ProgressionService.AwardCredits(player, math.floor(def.Credits * Attributes.LootMultiplier(luck)))
		ProgressionService.AddStat(player, "EnemyKills", 1)
		if def.Boss then
			ProgressionService.AddStat(player, "BossKills", 1)
		end
		BountyService.Record(player, "EnemyKill", { EnemyId = def.Id, Zone = zoneId })
	end

	if killer then
		if info.Headshot then
			ProgressionService.AddStat(killer, "Headshots", 1)
			BountyService.Record(killer, "Headshot", {})
		end
		local entry: KillFeedEntry = {
			Killer = killer.DisplayName,
			Victim = def.DisplayName,
			Weapon = weaponName(info.WeaponId),
			Headshot = info.Headshot == true,
			KillerIsEnemy = false,
			VictimIsEnemy = true,
		}
		if def.Boss then
			killFeed:FireAllClients(entry)
		else
			killFeed:FireClient(killer, entry)
		end
	end

	if def.Boss then
		local names = {}
		for _, player in credited do
			table.insert(names, player.DisplayName)
		end
		ProgressionService.NotifyAll({
			Kind = "Boss",
			Text = `{def.DisplayName} was defeated by {table.concat(names, ", ")}!`,
		})
	end
end

local function rewardPlayerKill(victim: Player, killer: Player, info: DamageInfo)
	local victimLevel = ProgressionService.GetLevel(victim)
	ProgressionService.AddStat(killer, "Kills", 1)
	ProgressionService.AwardXP(killer, Progression.PvPKillXP(victimLevel), `Defeated {victim.DisplayName}`)
	ProgressionService.AwardCredits(killer, Progression.PvPKillCredits(victimLevel))
	BountyService.Record(killer, "PlayerKill", {})
	if info.Headshot then
		ProgressionService.AddStat(killer, "Headshots", 1)
		BountyService.Record(killer, "Headshot", {})
	end
	killFeed:FireAllClients({
		Killer = killer.DisplayName,
		Victim = victim.DisplayName,
		Weapon = weaponName(info.WeaponId),
		Headshot = info.Headshot == true,
		KillerIsEnemy = false,
		VictimIsEnemy = false,
	} :: KillFeedEntry)
end

local function handleKill(humanoid: Humanoid, attacker: Attacker, info: DamageInfo)
	local victimModel = humanoid.Parent
	local victimPlayer = if victimModel then Players:GetPlayerFromCharacter(victimModel) else nil
	local killer = asPlayer(attacker)

	if victimPlayer then
		if killer then
			rewardPlayerKill(victimPlayer, killer, info)
		else
			local enemyDef = if typeof(attacker) == "Instance"
				then Enemies.Get(attacker:GetAttribute("EnemyId"))
				else nil
			killFeed:FireClient(
				victimPlayer,
				{
					Killer = if enemyDef then enemyDef.DisplayName else "Enemy",
					Victim = victimPlayer.DisplayName,
					Weapon = "",
					Headshot = false,
					KillerIsEnemy = true,
					VictimIsEnemy = false,
				} :: KillFeedEntry
			)
		end
	else
		local def = CombatService.GetEnemyDef(humanoid)
		if def then
			rewardEnemyKill(humanoid, def, killer, info)
		end
	end

	contributions[humanoid] = nil
	CombatService.Killed:Fire(humanoid, attacker, info)
end

-- A player guarding with a blade cuts incoming bullets out of the air when
-- they come from in front.
local function isDeflected(victimModel: Instance, info: DamageInfo): boolean
	if victimModel:GetAttribute("Guarding") ~= true or info.DamageType == "Blade" or not info.SourcePosition then
		return false
	end
	local root = victimModel:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local toSource = (info.SourcePosition - root.Position) * Vector3.new(1, 0, 1)
	local facing = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	if toSource.Magnitude < 0.1 or facing.Magnitude < 0.1 then
		return false
	end
	return facing.Unit:Dot(toSource.Unit) >= DEFLECT_ARC
end

-- Applies damage if the rules allow it. Returns (damageDealt, killed).
function CombatService.DamageHumanoid(
	attacker: Attacker,
	humanoid: Humanoid,
	amount: number,
	info: DamageInfo
): (number, boolean)
	if amount <= 0 or not CombatService.CanDamage(attacker, humanoid) then
		return 0, false
	end

	local victimModel = humanoid.Parent
	local victimPlayer = if victimModel then Players:GetPlayerFromCharacter(victimModel) else nil
	if victimPlayer and victimModel then
		if isDeflected(victimModel, info) then
			damageTaken:FireClient(victimPlayer, info.SourcePosition, 0)
			return 0, false
		end
		if info.DamageType == "Optical" then
			amount *= ANTI_BULLET_FIELD
		end
	elseif info.DamageType == "Optical" then
		amount *= OPTICAL_VS_MONSTERS
	end

	local dealt = math.min(humanoid.Health, amount)
	humanoid.Health -= dealt
	humanoid:SetAttribute("LastDamaged", os.clock())
	lastAttack[humanoid] = { Attacker = attacker, Time = os.clock(), WeaponId = info.WeaponId }

	local attackerPlayer = asPlayer(attacker)
	if attackerPlayer then
		local byPlayer = contributions[humanoid]
		if not byPlayer then
			byPlayer = {}
			contributions[humanoid] = byPlayer
		end
		byPlayer[attackerPlayer] = (byPlayer[attackerPlayer] or 0) + dealt
	end

	if victimPlayer then
		damageTaken:FireClient(victimPlayer, info.SourcePosition, dealt)
	end

	if humanoid.Health <= 0 then
		dead[humanoid] = true
		handleKill(humanoid, attacker, info)
		return dealt, true
	end
	return dealt, false
end

function CombatService.Init()
	-- Delayed, fast regeneration (the default Health script is stubbed out).
	task.spawn(function()
		while true do
			task.wait(REGEN_TICK)
			local now = os.clock()
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
					local last = humanoid:GetAttribute("LastDamaged")
					if typeof(last) ~= "number" or now - last >= Progression.RegenDelay then
						local regen = humanoid.MaxHealth * Progression.RegenFraction * REGEN_TICK
						humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + regen)
					end
				end
			end
		end
	end)
end

return CombatService
