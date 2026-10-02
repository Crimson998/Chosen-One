--!strict
-- Every item that can sit in an inventory. Weapons get an item entry
-- generated from Config.Weapons (same id); everything else is defined here.
--
-- Unique items (MaxStack 1: weapons, armor, gadgets) roll a rarity when they
-- drop. Rarity boosts the item's main stat and its sell value.

local Weapons = require(script.Parent.Weapons)

export type Category = "Weapon" | "Armor" | "Gadget" | "Consumable" | "Material"
export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary"

export type RarityInfo = {
	Id: Rarity,
	Color: Color3,
	Order: number, -- 1 = Common
	DropWeight: number,
	Bonus: number, -- weapons: +damage; armor and gadgets scale from it
	SellMultiplier: number,
}

export type GrenadeStats = {
	Damage: number,
	Radius: number,
	Fuse: number,
}

export type ItemDef = {
	Id: string,
	Name: string,
	Category: Category,
	Description: string,
	MaxStack: number, -- 1 = unique, rarity-rolled
	Weight: number, -- kg per unit
	SellValue: number, -- credits per unit at Common
	BuyPrice: number?, -- nil = not sold in the Armory (drop only)
	LevelRequired: number,
	Color: Color3, -- tile and loot-crate colour
	WeaponId: string?,
	DamageReduction: number?, -- armor: share of solid damage blocked
	FieldStrength: number?, -- gadget: share of optical damage absorbed
	HealFraction: number?, -- consumable: share of max HP restored
	HealTime: number?,
	Grenade: GrenadeStats?,
}

local Items = {}

Items.Rarities = {
	{ Id = "Common", Color = Color3.fromRGB(220, 222, 226), Order = 1, DropWeight = 55, Bonus = 0, SellMultiplier = 1 },
	{
		Id = "Uncommon",
		Color = Color3.fromRGB(90, 220, 110),
		Order = 2,
		DropWeight = 28,
		Bonus = 0.04,
		SellMultiplier = 1.6,
	},
	{
		Id = "Rare",
		Color = Color3.fromRGB(70, 150, 255),
		Order = 3,
		DropWeight = 12,
		Bonus = 0.08,
		SellMultiplier = 2.5,
	},
	{ Id = "Epic", Color = Color3.fromRGB(190, 100, 255), Order = 4, DropWeight = 4, Bonus = 0.12, SellMultiplier = 4 },
	{
		Id = "Legendary",
		Color = Color3.fromRGB(255, 165, 40),
		Order = 5,
		DropWeight = 1,
		Bonus = 0.18,
		SellMultiplier = 8,
	},
} :: { RarityInfo }

Items.RarityById = {} :: { [string]: RarityInfo }
for _, info in Items.Rarities do
	Items.RarityById[info.Id] = info
end

local SCRAP = Color3.fromRGB(130, 128, 124)
local TECH = Color3.fromRGB(60, 140, 120)
local MEDICAL = Color3.fromRGB(230, 70, 70)
local GEAR = Color3.fromRGB(70, 80, 64)
local FIELD = Color3.fromRGB(0, 190, 255)

local defs: { ItemDef } = {
	-- Materials: loot to sell in Haven ----------------------------------------
	{
		Id = "Scrap",
		Name = "Scrap Metal",
		Category = "Material",
		Description = "Twisted salvage. Every trader in Haven buys it.",
		MaxStack = 99,
		Weight = 0.2,
		SellValue = 8,
		LevelRequired = 1,
		Color = SCRAP,
	},
	{
		Id = "Wiring",
		Name = "Copper Wiring",
		Category = "Material",
		Description = "Stripped from dead machines.",
		MaxStack = 99,
		Weight = 0.1,
		SellValue = 15,
		LevelRequired = 1,
		Color = Color3.fromRGB(200, 120, 60),
	},
	{
		Id = "Circuit",
		Name = "Circuit Board",
		Category = "Material",
		Description = "Pre-war electronics, still worth something.",
		MaxStack = 99,
		Weight = 0.1,
		SellValue = 35,
		LevelRequired = 1,
		Color = TECH,
	},
	{
		Id = "PowerCell",
		Name = "Power Cell",
		Category = "Material",
		Description = "A charged energy cell. Optical gunsmiths pay well.",
		MaxStack = 50,
		Weight = 0.3,
		SellValue = 60,
		LevelRequired = 1,
		Color = Color3.fromRGB(80, 200, 255),
	},
	{
		Id = "Alloy",
		Name = "Rare Alloy",
		Category = "Material",
		Description = "Military-grade plating recovered from the Core.",
		MaxStack = 50,
		Weight = 0.5,
		SellValue = 150,
		LevelRequired = 1,
		Color = Color3.fromRGB(180, 190, 210),
	},
	{
		Id = "DataChip",
		Name = "Encrypted Data Chip",
		Category = "Material",
		Description = "Someone in Haven will pay a fortune for what's on this.",
		MaxStack = 20,
		Weight = 0.05,
		SellValue = 400,
		LevelRequired = 1,
		Color = Color3.fromRGB(255, 220, 80),
	},
	{
		Id = "JuggernautCore",
		Name = "Juggernaut Core",
		Category = "Material",
		Description = "The still-humming reactor of the Juggernaut. Proof of the kill.",
		MaxStack = 10,
		Weight = 2,
		SellValue = 2500,
		LevelRequired = 1,
		Color = Color3.fromRGB(255, 60, 60),
	},

	-- Consumables -------------------------------------------------------------
	{
		Id = "MedKit",
		Name = "Emergency Med Kit",
		Category = "Consumable",
		Description = "Injects nanites that restore 40% of your HP over 4 seconds. Press F.",
		MaxStack = 10,
		Weight = 0.2,
		SellValue = 40,
		BuyPrice = 150,
		LevelRequired = 1,
		Color = MEDICAL,
		HealFraction = 0.4,
		HealTime = 4,
	},
	{
		Id = "MedKitPlus",
		Name = "Advanced Med Kit",
		Category = "Consumable",
		Description = "Restores 80% of your HP over 4 seconds. Press F.",
		MaxStack = 10,
		Weight = 0.3,
		SellValue = 120,
		BuyPrice = 450,
		LevelRequired = 12,
		Color = Color3.fromRGB(255, 120, 160),
		HealFraction = 0.8,
		HealTime = 4,
	},
	{
		Id = "PlasmaGrenade",
		Name = "Plasma Grenade",
		Category = "Consumable",
		Description = "Detonates in a blue plasma burst after a short fuse. Press G to throw.",
		MaxStack = 5,
		Weight = 0.4,
		SellValue = 80,
		BuyPrice = 300,
		LevelRequired = 5,
		Color = Color3.fromRGB(70, 140, 255),
		Grenade = { Damage = 95, Radius = 14, Fuse = 2.2 },
	},

	-- Armor: blocks part of all solid damage ----------------------------------
	{
		Id = "Vest",
		Name = "Kevlar Vest",
		Category = "Armor",
		Description = "Soft body armor. Blocks some solid rounds.",
		MaxStack = 1,
		Weight = 2.5,
		SellValue = 250,
		BuyPrice = 800,
		LevelRequired = 3,
		Color = GEAR,
		DamageReduction = 0.1,
	},
	{
		Id = "PlateCarrier",
		Name = "Plate Carrier",
		Category = "Armor",
		Description = "Ceramic plates front and back.",
		MaxStack = 1,
		Weight = 5,
		SellValue = 1100,
		BuyPrice = 3500,
		LevelRequired = 12,
		Color = Color3.fromRGB(90, 84, 70),
		DamageReduction = 0.18,
	},
	{
		Id = "ExoRig",
		Name = "Exo Rig",
		Category = "Armor",
		Description = "Powered exoskeleton plating. Only found on the Core's elite.",
		MaxStack = 1,
		Weight = 8,
		SellValue = 3000,
		LevelRequired = 24,
		Color = Color3.fromRGB(40, 44, 52),
		DamageReduction = 0.26,
	},

	-- Gadgets: anti-bullet field generators ----------------------------------
	{
		Id = "FieldMk1",
		Name = "Field Generator Mk1",
		Category = "Gadget",
		Description = "Standard-issue anti-bullet field. Absorbs most optical (laser) damage.",
		MaxStack = 1,
		Weight = 0.5,
		SellValue = 30,
		BuyPrice = 100,
		LevelRequired = 1,
		Color = FIELD,
		FieldStrength = 0.6,
	},
	{
		Id = "FieldMk2",
		Name = "Field Generator Mk2",
		Category = "Gadget",
		Description = "Military anti-bullet field with a denser lattice.",
		MaxStack = 1,
		Weight = 0.8,
		SellValue = 800,
		BuyPrice = 2500,
		LevelRequired = 10,
		Color = Color3.fromRGB(0, 140, 255),
		FieldStrength = 0.72,
	},
	{
		Id = "FieldMk3",
		Name = "Field Generator Mk3",
		Category = "Gadget",
		Description = "Prototype field generator. Lasers barely tickle.",
		MaxStack = 1,
		Weight = 1,
		SellValue = 2000,
		LevelRequired = 20,
		Color = Color3.fromRGB(120, 90, 255),
		FieldStrength = 0.82,
	},
}

-- Weapons become items. Free starter guns still cost something in the
-- Armory so they can't be bought and sold for profit.
for _, weapon in Weapons.List do
	local buyPrice = math.max(weapon.Price, 100)
	table.insert(defs, {
		Id = weapon.Id,
		Name = weapon.DisplayName,
		Category = "Weapon",
		Description = weapon.Description,
		MaxStack = 1,
		Weight = weapon.Weight,
		SellValue = math.floor(buyPrice * 0.3),
		BuyPrice = if weapon.DropOnly then nil else buyPrice,
		LevelRequired = weapon.LevelRequired,
		Color = weapon.Model.Body,
		WeaponId = weapon.Id,
	})
end

Items.List = defs
Items.ById = {} :: { [string]: ItemDef }
for _, def in defs do
	assert(Items.ById[def.Id] == nil, `Duplicate item id {def.Id}`)
	Items.ById[def.Id] = def
end

function Items.Get(id: any): ItemDef?
	if typeof(id) ~= "string" then
		return nil
	end
	return Items.ById[id]
end

function Items.RarityInfo(rarity: any): RarityInfo
	return Items.RarityById[rarity] or Items.RarityById.Common
end

function Items.IsRarity(value: any): boolean
	return typeof(value) == "string" and Items.RarityById[value] ~= nil
end

-- Credits paid for `count` units of an item at the given rarity.
function Items.SellPrice(def: ItemDef, rarity: string, count: number): number
	return math.floor(def.SellValue * Items.RarityInfo(rarity).SellMultiplier) * count
end

function Items.DamageMultiplier(rarity: string): number
	return 1 + Items.RarityInfo(rarity).Bonus
end

function Items.ArmorReduction(def: ItemDef, rarity: string): number
	return math.min(0.6, (def.DamageReduction or 0) * (1 + Items.RarityInfo(rarity).Bonus * 2.5))
end

function Items.FieldStrength(def: ItemDef, rarity: string): number
	return math.min(0.92, (def.FieldStrength or 0) + Items.RarityInfo(rarity).Bonus * 0.5)
end

-- Rolls a rarity. `luck` (0 = none) shifts weight toward the higher tiers.
function Items.RollRarity(rng: Random, luck: number): Rarity
	local total = 0
	local weights: { number } = {}
	for index, info in Items.Rarities do
		local weight = info.DropWeight * (1 + luck) ^ (index - 1)
		weights[index] = weight
		total += weight
	end
	local roll = rng:NextNumber() * total
	for index, info in Items.Rarities do
		roll -= weights[index]
		if roll <= 0 then
			return info.Id
		end
	end
	return "Common"
end

return Items
