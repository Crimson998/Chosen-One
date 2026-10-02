--!strict
-- Audio asset ids. Roblox audio is permission-gated, so the game ships without
-- sound ids: paste ids you own or that are public (e.g. from the Creator Store)
-- as "rbxassetid://<id>". Empty entries are skipped silently.

local Sounds: { [string]: string } = {
	-- Weapon fire, keyed by WeaponDef.Sound
	Fire_Pistol = "",
	Fire_Revolver = "",
	Fire_SMG = "",
	Fire_Rifle = "",
	Fire_Shotgun = "",
	Fire_LMG = "",
	Fire_Sniper = "",
	Fire_Optical = "",
	Fire_Blade = "",
	Fire_Enemy = "",

	Reload = "",
	Empty = "",
	Equip = "",

	Hitmarker = "",
	Headshot = "",
	Kill = "",
	LevelUp = "",
	BountyComplete = "",
	Purchase = "",
	Hurt = "",
	Deflect = "",
	BulletLine = "", -- warning when a bullet line locks onto you
	Heartbeat = "",
	SpinUp = "",
	Explosion = "",
	Pickup = "",
}

return Sounds
