--!strict
-- What each enemy drops. Loot is personal: every player credited with a kill
-- gets their own roll, so grouping up never costs anyone loot.
--
-- Entries are independent chances. Weapon and Gear rolls pick one item from
-- their pool and roll its rarity; RarityLuck (plus the looter's LUK) tilts
-- those rolls toward the higher tiers.

export type LootEntry = {
	Item: string,
	Chance: number,
	Min: number?,
	Max: number?,
}

export type PoolRoll = {
	Chance: number,
	Pool: { string },
	Rolls: number?,
}

export type LootTable = {
	Entries: { LootEntry },
	Weapons: PoolRoll?,
	Gear: PoolRoll?,
	RarityLuck: number,
}

local Loot = {}

Loot.Tables = {
	Scavenger = {
		Entries = {
			{ Item = "Scrap", Chance = 0.7, Min = 1, Max = 3 },
			{ Item = "Wiring", Chance = 0.25 },
			{ Item = "MedKit", Chance = 0.08 },
		},
		Weapons = { Chance = 0.03, Pool = { "P9", "Viper", "Rattler", "Lumen" } },
		Gear = { Chance = 0.02, Pool = { "Vest", "FieldMk1" } },
		RarityLuck = 0,
	},
	Raider = {
		Entries = {
			{ Item = "Scrap", Chance = 0.7, Min = 1, Max = 3 },
			{ Item = "Wiring", Chance = 0.4 },
			{ Item = "Circuit", Chance = 0.15 },
			{ Item = "MedKit", Chance = 0.1 },
			{ Item = "PlasmaGrenade", Chance = 0.05 },
		},
		Weapons = { Chance = 0.05, Pool = { "AR7", "Viper", "Rattler", "Brawler", "Vixen" } },
		Gear = { Chance = 0.03, Pool = { "Vest", "FieldMk2" } },
		RarityLuck = 0.1,
	},
	Marauder = {
		Entries = {
			{ Item = "Scrap", Chance = 0.6, Min = 2, Max = 4 },
			{ Item = "Circuit", Chance = 0.3 },
			{ Item = "PowerCell", Chance = 0.2 },
			{ Item = "MedKit", Chance = 0.12 },
			{ Item = "MedKitPlus", Chance = 0.04 },
			{ Item = "PlasmaGrenade", Chance = 0.08 },
		},
		Weapons = { Chance = 0.06, Pool = { "Brawler", "Tempest", "AR7", "Arclight", "HandCannon" } },
		Gear = { Chance = 0.04, Pool = { "Vest", "PlateCarrier", "FieldMk2" } },
		RarityLuck = 0.2,
	},
	Sharpshooter = {
		Entries = {
			{ Item = "Circuit", Chance = 0.4 },
			{ Item = "PowerCell", Chance = 0.25 },
			{ Item = "DataChip", Chance = 0.05 },
			{ Item = "MedKitPlus", Chance = 0.06 },
		},
		Weapons = { Chance = 0.08, Pool = { "Marksman", "Vanguard", "Arclight" } },
		Gear = { Chance = 0.04, Pool = { "PlateCarrier", "FieldMk2" } },
		RarityLuck = 0.3,
	},
	Enforcer = {
		Entries = {
			{ Item = "Scrap", Chance = 0.5, Min = 2, Max = 5 },
			{ Item = "PowerCell", Chance = 0.35 },
			{ Item = "Alloy", Chance = 0.2 },
			{ Item = "DataChip", Chance = 0.06 },
			{ Item = "MedKitPlus", Chance = 0.1 },
			{ Item = "PlasmaGrenade", Chance = 0.12 },
		},
		Weapons = { Chance = 0.07, Pool = { "Hammer", "Tempest", "Marksman", "Thunderclap", "PhotonBlade" } },
		Gear = { Chance = 0.05, Pool = { "PlateCarrier", "ExoRig", "FieldMk2", "FieldMk3" } },
		RarityLuck = 0.4,
	},
	Juggernaut = {
		Entries = {
			{ Item = "JuggernautCore", Chance = 1 },
			{ Item = "Alloy", Chance = 1, Min = 3, Max = 6 },
			{ Item = "DataChip", Chance = 0.5 },
			{ Item = "MedKitPlus", Chance = 1, Min = 2, Max = 3 },
			{ Item = "PlasmaGrenade", Chance = 0.8, Min = 2, Max = 3 },
		},
		Weapons = { Chance = 1, Pool = { "Nemesis", "Thunderclap", "Hammer", "Vanguard" }, Rolls = 2 },
		Gear = { Chance = 0.7, Pool = { "ExoRig", "FieldMk3" } },
		RarityLuck = 1.2,
	},
} :: { [string]: LootTable }

-- Extra rarity luck per point of LUK.
Loot.LuckPerLuk = 0.004

-- Seconds that personal loot stays reserved for its owner.
Loot.OwnershipTime = 30
-- Seconds before any ground loot disappears.
Loot.Lifetime = 120

return Loot
