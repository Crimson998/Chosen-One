--!strict
-- Character stats, allocated with points earned on level up. Every formula
-- lives here so the client (movement, spread, recoil) and server (health,
-- reloads, crits, loot) always agree.
--
--   STR  carry capacity and handling of heavy weapons
--   AGI  movement speed
--   VIT  max health
--   DEX  bullet circle size and reload speed
--   LUK  critical hits and credit drops

export type AttributeName = "STR" | "AGI" | "VIT" | "DEX" | "LUK"

export type AttributeSet = {
	STR: number,
	AGI: number,
	VIT: number,
	DEX: number,
	LUK: number,
}

export type AttributeInfo = {
	Id: AttributeName,
	Name: string,
	Description: string,
}

local Attributes = {}

Attributes.Base = 5 -- starting value of every stat
Attributes.Max = 100
Attributes.PointsPerLevel = 3
Attributes.CritMultiplier = 1.5

Attributes.List = {
	{ Id = "STR", Name = "Strength", Description = "Carry capacity. Heavy weapons need STR to handle their recoil." },
	{ Id = "AGI", Name = "Agility", Description = "Movement and sprint speed." },
	{ Id = "VIT", Name = "Vitality", Description = "Maximum HP." },
	{ Id = "DEX", Name = "Dexterity", Description = "Tighter bullet circle and faster reloads." },
	{ Id = "LUK", Name = "Luck", Description = "Critical hit chance and bonus credits from kills." },
} :: { AttributeInfo }

function Attributes.Default(): AttributeSet
	local base = Attributes.Base
	return { STR = base, AGI = base, VIT = base, DEX = base, LUK = base }
end

function Attributes.IsName(value: any): boolean
	return value == "STR" or value == "AGI" or value == "VIT" or value == "DEX" or value == "LUK"
end

function Attributes.Get(set: AttributeSet, name: string): number
	return (set :: any)[name]
end

function Attributes.Set(set: AttributeSet, name: string, value: number)
	(set :: any)[name] = value
end

function Attributes.MaxHealth(vit: number): number
	return math.floor(100 + (vit - Attributes.Base) * 2.5)
end

function Attributes.SpeedMultiplier(agi: number): number
	return 1 + (agi - Attributes.Base) * 0.006
end

-- Multiplier on bullet circle size.
function Attributes.SpreadMultiplier(dex: number): number
	return 1 - math.min(0.45, (dex - Attributes.Base) * 0.005)
end

function Attributes.ReloadMultiplier(dex: number): number
	return 1 - math.min(0.3, (dex - Attributes.Base) * 0.0035)
end

-- Kilograms of weapons you can carry before you slow down.
function Attributes.CarryCapacity(str: number): number
	return 10 + str * 0.5
end

-- Below a weapon's required STR it kicks harder and sprays wider.
function Attributes.HandlingPenalty(str: number, requiredStr: number): (number, number)
	local deficit = math.max(0, requiredStr - str)
	return 1 + deficit * 0.05, deficit * 0.04 -- recoil multiplier, extra spread (degrees)
end

function Attributes.CritChance(luk: number): number
	return math.min(0.25, luk * 0.0025)
end

function Attributes.LootMultiplier(luk: number): number
	return 1 + luk * 0.004
end

function Attributes.RespecCost(level: number): number
	return 500 + level * 150
end

-- Total points a character of this level has earned.
function Attributes.TotalPoints(level: number): number
	return (level - 1) * Attributes.PointsPerLevel
end

return Attributes
