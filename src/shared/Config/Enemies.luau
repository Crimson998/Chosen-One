--!strict
-- NPC definitions. Enemies are built procedurally (see server/Util/EnemyRig).

local Weapons = require(script.Parent.Weapons)

type ModelStyle = Weapons.ModelStyle

export type EnemyDef = {
	Id: string,
	DisplayName: string,
	Level: number,
	Health: number,
	WalkSpeed: number,

	-- Attacks are telegraphed: a bullet line points at the target for
	-- TelegraphTime seconds, then a burst is fired down (roughly) that line.
	-- Players who step out of the line in time are not hit.
	Damage: number, -- per pellet
	TelegraphTime: number,
	Burst: number, -- shots per attack
	FireInterval: number, -- seconds between shots in a burst
	AttackCooldown: number, -- seconds between attacks
	Spread: number, -- degrees of scatter around the bullet line
	Pellets: number,
	Lead: number, -- 0..1: how far ahead of a moving target the line is aimed
	AttackRange: number,
	AggroRange: number,
	LeashRange: number, -- distance from spawn anchor before giving up the chase

	XP: number,
	Credits: number,
	AmmoDropChance: number,
	RespawnTime: number,

	Scale: number,
	Colors: {
		Skin: Color3,
		Torso: Color3,
		Legs: Color3,
		Visor: Color3,
	},
	Weapon: ModelStyle?, -- gun model carried (see Shared/WeaponModel)
	Boss: boolean?,
	Passive: boolean?, -- training dummies: no AI, no rewards
}

local Enemies = {}

local defs: { EnemyDef } = {
	{
		Id = "Dummy",
		DisplayName = "Training Dummy",
		Level = 1,
		Health = 400,
		WalkSpeed = 0,
		Damage = 0,
		TelegraphTime = 1,
		Burst = 0,
		FireInterval = 1,
		AttackCooldown = 1,
		Spread = 0,
		Pellets = 1,
		Lead = 0,
		AttackRange = 0,
		AggroRange = 0,
		LeashRange = 0,
		XP = 0,
		Credits = 0,
		AmmoDropChance = 0,
		RespawnTime = 3,
		Scale = 1,
		Colors = {
			Skin = Color3.fromRGB(196, 170, 120),
			Torso = Color3.fromRGB(170, 140, 90),
			Legs = Color3.fromRGB(150, 120, 80),
			Visor = Color3.fromRGB(255, 80, 80),
		},
		Passive = true,
	},
	{
		Id = "Scavenger",
		DisplayName = "Scavenger",
		Level = 2,
		Health = 80,
		WalkSpeed = 12,
		Damage = 6,
		TelegraphTime = 0.8,
		Burst = 3,
		FireInterval = 0.12,
		AttackCooldown = 1.8,
		Spread = 1.8,
		Pellets = 1,
		Lead = 0.4,
		AttackRange = 70,
		AggroRange = 90,
		LeashRange = 150,
		XP = 25,
		Credits = 12,
		AmmoDropChance = 0.5,
		RespawnTime = 12,
		Scale = 1,
		Weapon = "SMG",
		Colors = {
			Skin = Color3.fromRGB(204, 142, 105),
			Torso = Color3.fromRGB(110, 88, 60),
			Legs = Color3.fromRGB(70, 62, 50),
			Visor = Color3.fromRGB(255, 190, 60),
		},
	},
	{
		Id = "Raider",
		DisplayName = "Raider",
		Level = 6,
		Health = 130,
		WalkSpeed = 14,
		Damage = 8,
		TelegraphTime = 0.7,
		Burst = 4,
		FireInterval = 0.1,
		AttackCooldown = 1.6,
		Spread = 1.5,
		Pellets = 1,
		Lead = 0.5,
		AttackRange = 90,
		AggroRange = 110,
		LeashRange = 170,
		XP = 45,
		Credits = 22,
		AmmoDropChance = 0.5,
		RespawnTime = 15,
		Scale = 1,
		Weapon = "Rifle",
		Colors = {
			Skin = Color3.fromRGB(160, 110, 80),
			Torso = Color3.fromRGB(120, 40, 40),
			Legs = Color3.fromRGB(45, 45, 50),
			Visor = Color3.fromRGB(255, 70, 50),
		},
	},
	{
		Id = "Marauder",
		DisplayName = "Marauder",
		Level = 12,
		Health = 220,
		WalkSpeed = 15,
		Damage = 5,
		TelegraphTime = 0.65,
		Burst = 1,
		FireInterval = 0.5,
		AttackCooldown = 1.8,
		Spread = 4,
		Pellets = 6,
		Lead = 0.5,
		AttackRange = 110,
		AggroRange = 130,
		LeashRange = 190,
		XP = 90,
		Credits = 40,
		AmmoDropChance = 0.55,
		RespawnTime = 18,
		Scale = 1.05,
		Weapon = "Shotgun",
		Colors = {
			Skin = Color3.fromRGB(120, 85, 60),
			Torso = Color3.fromRGB(150, 110, 50),
			Legs = Color3.fromRGB(80, 64, 40),
			Visor = Color3.fromRGB(255, 140, 20),
		},
	},
	{
		Id = "Sharpshooter",
		DisplayName = "Sharpshooter",
		Level = 15,
		Health = 160,
		WalkSpeed = 10,
		Damage = 32,
		TelegraphTime = 1.4,
		Burst = 1,
		FireInterval = 1,
		AttackCooldown = 3.2,
		Spread = 0.3,
		Pellets = 1,
		Lead = 0.7,
		AttackRange = 220,
		AggroRange = 240,
		LeashRange = 260,
		XP = 110,
		Credits = 55,
		AmmoDropChance = 0.6,
		RespawnTime = 20,
		Scale = 1,
		Weapon = "Sniper",
		Colors = {
			Skin = Color3.fromRGB(180, 130, 100),
			Torso = Color3.fromRGB(60, 72, 50),
			Legs = Color3.fromRGB(50, 58, 42),
			Visor = Color3.fromRGB(80, 255, 120),
		},
	},
	{
		Id = "Enforcer",
		DisplayName = "Enforcer",
		Level = 26,
		Health = 420,
		WalkSpeed = 15,
		Damage = 10,
		TelegraphTime = 0.55,
		Burst = 5,
		FireInterval = 0.09,
		AttackCooldown = 1.4,
		Spread = 1.4,
		Pellets = 1,
		Lead = 0.6,
		AttackRange = 120,
		AggroRange = 140,
		LeashRange = 200,
		XP = 180,
		Credits = 80,
		AmmoDropChance = 0.6,
		RespawnTime = 22,
		Scale = 1.15,
		Weapon = "Rifle",
		Colors = {
			Skin = Color3.fromRGB(90, 90, 96),
			Torso = Color3.fromRGB(30, 30, 36),
			Legs = Color3.fromRGB(24, 24, 28),
			Visor = Color3.fromRGB(255, 40, 60),
		},
	},
	{
		Id = "Juggernaut",
		DisplayName = "The Juggernaut",
		Level = 35,
		Health = 6000,
		WalkSpeed = 11,
		Damage = 7,
		TelegraphTime = 0.5,
		Burst = 16,
		FireInterval = 0.07,
		AttackCooldown = 1.6,
		Spread = 3,
		Pellets = 1,
		Lead = 0.5,
		AttackRange = 150,
		AggroRange = 180,
		LeashRange = 230,
		XP = 2500,
		Credits = 1500,
		AmmoDropChance = 1,
		RespawnTime = 240,
		Scale = 2.2,
		Weapon = "LMG",
		Colors = {
			Skin = Color3.fromRGB(70, 70, 76),
			Torso = Color3.fromRGB(60, 20, 24),
			Legs = Color3.fromRGB(30, 30, 34),
			Visor = Color3.fromRGB(255, 20, 20),
		},
		Boss = true,
	},
}

Enemies.List = defs
Enemies.ById = {} :: { [string]: EnemyDef }
for _, def in defs do
	Enemies.ById[def.Id] = def
end

function Enemies.Get(id: any): EnemyDef?
	if typeof(id) ~= "string" then
		return nil
	end
	return Enemies.ById[id]
end

return Enemies
