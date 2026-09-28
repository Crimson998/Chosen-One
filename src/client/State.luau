--!strict
-- Client-side shared state. Controllers read and write these fields and use
-- the signals to react to changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

local State = {
	Profile = nil :: Types.Profile?,
	ProfileChanged = Signal.new(),

	-- Locally predicted ammo; corrected by the server's AmmoUpdate.
	Ammo = nil :: Types.AmmoState?,
	AmmoChanged = Signal.new(),
	WeaponId = nil :: string?,

	Zone = nil :: Zones.ZoneDef?,
	ZoneChanged = Signal.new(),

	UIOpen = false, -- a menu owns the mouse; weapons are holstered
	Firing = false,
	AimHeld = false, -- aim input is down (aiming cancels sprint)
	Aiming = false,
	AimAlpha = 0,
	Sprinting = false,
	Reloading = false,
	ReloadStart = 0,
	ReloadDuration = 0,
	Spread = 0, -- current spread in degrees, drives the crosshair
	Scoped = false,
}

return State
