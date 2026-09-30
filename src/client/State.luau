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
	Spread = 0, -- current bullet circle radius in degrees
	Scoped = false,
	Guarding = false, -- blocking with a blade
	SpinUp = 0, -- 0..1 minigun barrel spin

	-- Heart rate drives the bullet circle: it pulses with every beat and
	-- swells as your pulse climbs.
	HeartRate = 70,
	Pulse = 0, -- 1 right after a beat, decaying toward 0

	OpenMenus = {} :: { [string]: boolean },
}

-- Menus call this so UIOpen stays true while any of them is open.
function State.SetMenuOpen(name: string, open: boolean)
	(State.OpenMenus :: any)[name] = if open then true else nil
	State.UIOpen = next(State.OpenMenus) ~= nil
end

return State
