--!strict
-- Pure helpers over a profile's inventory, shared by client and server so
-- both agree on weight, equipped gear and defenses.

local Items = require(script.Parent.Config.Items)
local Types = require(script.Parent.Types)

type Profile = Types.Profile
type ItemInstance = Types.ItemInstance

export type GearSlot = string -- "Primary" | "Secondary" | "Armor" | "Gadget"

local Inventory = {}

Inventory.MaxSlots = 40
Inventory.GearSlots = { "Primary", "Secondary", "Armor", "Gadget" }

function Inventory.IndexOf(profile: Profile, uid: string?): number?
	if uid == nil then
		return nil
	end
	for index, item in profile.Inventory do
		if item.Uid == uid then
			return index
		end
	end
	return nil
end

function Inventory.Find(profile: Profile, uid: string?): ItemInstance?
	local index = Inventory.IndexOf(profile, uid)
	return if index then profile.Inventory[index] else nil
end

function Inventory.Count(profile: Profile, itemId: string): number
	local total = 0
	for _, item in profile.Inventory do
		if item.Id == itemId then
			total += item.Count
		end
	end
	return total
end

function Inventory.EquippedUid(profile: Profile, slot: GearSlot): string?
	return (profile.Loadout :: any)[slot]
end

function Inventory.Equipped(profile: Profile, slot: GearSlot): ItemInstance?
	return Inventory.Find(profile, Inventory.EquippedUid(profile, slot))
end

-- The gear slot an item is equipped in, if any.
function Inventory.SlotOf(profile: Profile, uid: string): GearSlot?
	for _, slot in Inventory.GearSlots do
		if Inventory.EquippedUid(profile, slot) == uid then
			return slot
		end
	end
	return nil
end

function Inventory.EquippedWeaponId(profile: Profile, slot: GearSlot): string?
	local item = Inventory.Equipped(profile, slot)
	return if item then item.Id else nil
end

-- Everything you carry counts toward your STR carry capacity.
function Inventory.Weight(profile: Profile): number
	local total = 0
	for _, item in profile.Inventory do
		local def = Items.Get(item.Id)
		if def then
			total += def.Weight * item.Count
		end
	end
	return total
end

-- Share of solid damage blocked by equipped armor.
function Inventory.ArmorReduction(profile: Profile): number
	local item = Inventory.Equipped(profile, "Armor")
	local def = item and Items.Get(item.Id)
	return if item and def then Items.ArmorReduction(def, item.Rarity) else 0
end

-- Share of optical damage absorbed by the equipped anti-bullet field.
function Inventory.FieldStrength(profile: Profile): number
	local item = Inventory.Equipped(profile, "Gadget")
	local def = item and Items.Get(item.Id)
	return if item and def then Items.FieldStrength(def, item.Rarity) else 0
end

return Inventory
