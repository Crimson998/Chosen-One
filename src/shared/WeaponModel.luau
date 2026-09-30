--!strict
-- Builds gun models out of primitive parts so the game needs no uploaded
-- meshes. The same model is used for first-person viewmodels (client) and
-- the third-person gun other players see (server).
--
-- Model space: +X right, +Y up, -Z forward (the barrel points down -Z).
-- The invisible "Handle" part sits at the origin and carries attachments:
--   Muzzle  - where tracers and flashes start
--   Aim     - the point placed on the camera's centre line when aiming
--   GripR   - right hand, GripL - left hand

local Weapons = require(script.Parent.Config.Weapons)

type WeaponDef = Weapons.WeaponDef
type ModelStyle = Weapons.ModelStyle

-- AccentGlow is the weapon's accent colour as glowing neon (energy weapons).
type ColorKey = "Body" | "Accent" | "AccentGlow" | "Dark" | "Metal" | "Glow" | "Lens"

type PartSpec = {
	Name: string?,
	Size: Vector3,
	Pos: Vector3,
	Rot: Vector3?, -- degrees
	Color: ColorKey,
	Shape: ("Block" | "Cylinder" | "Ball")?,
}

export type StyleSpec = {
	Parts: { PartSpec },
	Muzzle: Vector3,
	Aim: Vector3,
	GripR: Vector3,
	GripL: Vector3,
	Hip: CFrame, -- viewmodel offset from the camera when not aiming
}

local V = Vector3.new

local DARK = Color3.fromRGB(22, 22, 24)
local METAL = Color3.fromRGB(96, 98, 104)
local GLOW = Color3.fromRGB(255, 45, 45)
local LENS = Color3.fromRGB(70, 110, 150)

local function block(size: Vector3, pos: Vector3, color: ColorKey, rot: Vector3?, name: string?): PartSpec
	return { Size = size, Pos = pos, Color = color, Rot = rot, Name = name }
end

-- Roblox cylinders run along X; rotate so this one runs along Z.
local function cylZ(length: number, diameter: number, pos: Vector3, color: ColorKey, name: string?): PartSpec
	return {
		Size = V(length, diameter, diameter),
		Pos = pos,
		Rot = V(0, 90, 0),
		Color = color,
		Shape = "Cylinder",
		Name = name,
	}
end

local function ball(diameter: number, pos: Vector3, color: ColorKey): PartSpec
	return { Size = V(diameter, diameter, diameter), Pos = pos, Color = color, Shape = "Ball" }
end

-- Open-frame reflex sight whose red dot sits on the aim line (y + 0.12).
local function reflexSight(y: number, z: number): { PartSpec }
	return {
		block(V(0.16, 0.04, 0.26), V(0, y + 0.02, z + 0.05), "Dark"),
		block(V(0.03, 0.18, 0.03), V(-0.075, y + 0.13, z), "Dark"),
		block(V(0.03, 0.18, 0.03), V(0.075, y + 0.13, z), "Dark"),
		block(V(0.18, 0.03, 0.03), V(0, y + 0.235, z), "Dark"),
		ball(0.022, V(0, y + 0.12, z), "Glow"),
	}
end

local function concat(...: { PartSpec }): { PartSpec }
	local result = {}
	for _, list in { ... } do
		for _, spec in list do
			table.insert(result, spec)
		end
	end
	return result
end

local pistolParts: { PartSpec } = {
	block(V(0.2, 0.2, 0.95), V(0, 0.12, -0.15), "Body", nil, "Slide"),
	block(V(0.18, 0.12, 0.72), V(0, -0.03, -0.08), "Accent"),
	block(V(0.17, 0.5, 0.26), V(0, -0.3, 0.2), "Accent", V(-15, 0, 0), "Grip"),
	block(V(0.04, 0.12, 0.2), V(0, -0.15, -0.1), "Dark"),
	block(V(0.03, 0.05, 0.03), V(0, 0.245, -0.58), "Dark"),
	block(V(0.04, 0.05, 0.04), V(-0.05, 0.245, 0.27), "Dark"),
	block(V(0.04, 0.05, 0.04), V(0.05, 0.245, 0.27), "Dark"),
	cylZ(0.05, 0.08, V(0, 0.12, -0.645), "Dark"),
}

local Styles: { [ModelStyle]: StyleSpec } = {
	Pistol = {
		Parts = pistolParts,
		Muzzle = V(0, 0.12, -0.68),
		Aim = V(0, 0.27, 0.45),
		GripR = V(0, -0.3, 0.22),
		GripL = V(-0.07, -0.34, 0.18),
		Hip = CFrame.new(0.55, -0.55, -1.45),
	},

	MachinePistol = {
		Parts = concat(pistolParts, {
			block(V(0.13, 0.4, 0.2), V(0, -0.73, 0.31), "Dark", V(-15, 0, 0), "Mag"),
			block(V(0.16, 0.16, 0.18), V(0, 0.12, -0.72), "Dark"),
		}),
		Muzzle = V(0, 0.12, -0.82),
		Aim = V(0, 0.27, 0.45),
		GripR = V(0, -0.3, 0.22),
		GripL = V(-0.07, -0.34, 0.18),
		Hip = CFrame.new(0.55, -0.55, -1.45),
	},

	Revolver = {
		Parts = {
			block(V(0.18, 0.22, 0.5), V(0, 0.08, 0), "Body", nil, "Frame"),
			cylZ(0.32, 0.3, V(0, 0.06, -0.05), "Body", "Cylinder"),
			cylZ(0.75, 0.12, V(0, 0.13, -0.6), "Body", "Barrel"),
			block(V(0.08, 0.06, 0.75), V(0, 0.2, -0.6), "Body"),
			block(V(0.17, 0.5, 0.26), V(0, -0.28, 0.22), "Accent", V(-18, 0, 0), "Grip"),
			block(V(0.04, 0.12, 0.18), V(0, -0.1, 0.02), "Dark"),
			block(V(0.03, 0.06, 0.04), V(0, 0.26, -0.93), "Dark"),
			block(V(0.04, 0.06, 0.05), V(-0.045, 0.26, 0.2), "Dark"),
			block(V(0.04, 0.06, 0.05), V(0.045, 0.26, 0.2), "Dark"),
		},
		Muzzle = V(0, 0.13, -0.98),
		Aim = V(0, 0.29, 0.6),
		GripR = V(0, -0.28, 0.24),
		GripL = V(-0.07, -0.32, 0.2),
		Hip = CFrame.new(0.55, -0.55, -1.5),
	},

	SMG = {
		Parts = concat({
			block(V(0.24, 0.3, 1.1), V(0, 0, 0), "Body", nil, "Receiver"),
			block(V(0.12, 0.04, 0.9), V(0, 0.17, 0), "Dark"),
			cylZ(0.35, 0.16, V(0, 0.03, -0.72), "Dark"),
			cylZ(0.2, 0.07, V(0, 0.03, -0.99), "Dark"),
			block(V(0.15, 0.6, 0.22), V(0, -0.43, -0.3), "Dark", V(10, 0, 0), "Mag"),
			block(V(0.17, 0.45, 0.24), V(0, -0.33, 0.25), "Accent", V(-15, 0, 0), "Grip"),
			block(V(0.1, 0.22, 0.6), V(0, -0.02, 0.82), "Accent"),
			block(V(0.2, 0.34, 0.06), V(0, -0.05, 1.12), "Accent"),
		}, reflexSight(0.19, 0.05)),
		Muzzle = V(0, 0.03, -1.1),
		Aim = V(0, 0.31, 0.5),
		GripR = V(0, -0.33, 0.27),
		GripL = V(0, -0.1, -0.65),
		Hip = CFrame.new(0.6, -0.6, -1.25),
	},

	Rifle = {
		Parts = concat({
			block(V(0.24, 0.32, 1.3), V(0, 0, 0), "Body", nil, "Receiver"),
			block(V(0.22, 0.26, 0.9), V(0, 0.02, -1.1), "Accent", nil, "Handguard"),
			cylZ(0.55, 0.07, V(0, 0.05, -1.82), "Dark"),
			cylZ(0.14, 0.11, V(0, 0.05, -2.14), "Dark"),
			block(V(0.15, 0.7, 0.26), V(0, -0.48, -0.35), "Dark", V(12, 0, 0), "Mag"),
			block(V(0.17, 0.45, 0.24), V(0, -0.33, 0.35), "Dark", V(-18, 0, 0), "Grip"),
			block(V(0.2, 0.3, 0.8), V(0, -0.05, 1.05), "Accent", nil, "Stock"),
			block(V(0.12, 0.04, 1.3), V(0, 0.18, -0.3), "Dark"),
		}, reflexSight(0.2, 0)),
		Muzzle = V(0, 0.05, -2.22),
		Aim = V(0, 0.32, 0.45),
		GripR = V(0, -0.33, 0.37),
		GripL = V(0, -0.12, -1),
		Hip = CFrame.new(0.62, -0.62, -1.35),
	},

	Shotgun = {
		Parts = {
			block(V(0.26, 0.34, 1), V(0, 0, 0), "Body", nil, "Receiver"),
			cylZ(1.5, 0.13, V(0, 0.08, -1.25), "Dark", "Barrel"),
			cylZ(1.2, 0.11, V(0, -0.08, -1.1), "Dark"),
			block(V(0.2, 0.2, 0.55), V(0, -0.09, -0.95), "Accent", nil, "Pump"),
			block(V(0.17, 0.45, 0.24), V(0, -0.33, 0.3), "Accent", V(-18, 0, 0), "Grip"),
			block(V(0.22, 0.32, 0.9), V(0, -0.08, 0.95), "Accent", nil, "Stock"),
			block(V(0.1, 0.03, 0.4), V(0, 0.185, 0.2), "Dark"),
			ball(0.05, V(0, 0.17, -1.95), "Glow"),
		},
		Muzzle = V(0, 0.08, -2),
		Aim = V(0, 0.2, 0.7),
		GripR = V(0, -0.33, 0.32),
		GripL = V(0, -0.09, -0.95),
		Hip = CFrame.new(0.62, -0.62, -1.3),
	},

	DMR = {
		Parts = {
			block(V(0.24, 0.32, 1.4), V(0, 0, 0), "Body", nil, "Receiver"),
			block(V(0.22, 0.26, 1), V(0, 0.02, -1.2), "Body", nil, "Handguard"),
			cylZ(0.9, 0.07, V(0, 0.05, -2.15), "Dark"),
			cylZ(0.16, 0.12, V(0, 0.05, -2.66), "Dark"),
			block(V(0.15, 0.45, 0.26), V(0, -0.36, -0.35), "Dark", V(8, 0, 0), "Mag"),
			block(V(0.17, 0.45, 0.24), V(0, -0.33, 0.4), "Accent", V(-18, 0, 0), "Grip"),
			block(V(0.22, 0.34, 0.95), V(0, -0.04, 1.15), "Accent", nil, "Stock"),
			block(V(0.08, 0.12, 0.08), V(0, 0.22, -0.35), "Dark"),
			block(V(0.08, 0.12, 0.08), V(0, 0.22, 0.2), "Dark"),
			cylZ(1, 0.16, V(0, 0.36, -0.1), "Dark", "Scope"),
			cylZ(0.25, 0.24, V(0, 0.36, -0.68), "Dark"),
			cylZ(0.2, 0.2, V(0, 0.36, 0.48), "Dark"),
			cylZ(0.02, 0.2, V(0, 0.36, -0.81), "Lens"),
		},
		Muzzle = V(0, 0.05, -2.75),
		Aim = V(0, 0.36, 0.8),
		GripR = V(0, -0.33, 0.42),
		GripL = V(0, -0.12, -1.1),
		Hip = CFrame.new(0.62, -0.64, -1.4),
	},

	Sniper = {
		Parts = {
			block(V(0.24, 0.3, 1.4), V(0, 0, 0), "Body", nil, "Receiver"),
			cylZ(1.9, 0.09, V(0, 0.05, -1.65), "Dark", "Barrel"),
			block(V(0.16, 0.12, 0.28), V(0, 0.05, -2.72), "Dark"),
			block(V(0.24, 0.4, 1.2), V(0, -0.08, 1.2), "Accent", nil, "Stock"),
			block(V(0.17, 0.45, 0.24), V(0, -0.33, 0.45), "Accent", V(-18, 0, 0), "Grip"),
			block(V(0.15, 0.25, 0.3), V(0, -0.25, -0.1), "Dark", nil, "Mag"),
			{ Size = V(0.28, 0.05, 0.05), Pos = V(0.2, 0.08, 0.35), Color = "Metal", Shape = "Cylinder" },
			ball(0.09, V(0.35, 0.08, 0.35), "Metal"),
			block(V(0.08, 0.12, 0.08), V(0, 0.21, -0.4), "Dark"),
			block(V(0.08, 0.12, 0.08), V(0, 0.21, 0.25), "Dark"),
			cylZ(1.3, 0.2, V(0, 0.37, -0.1), "Dark", "Scope"),
			cylZ(0.35, 0.3, V(0, 0.37, -0.88), "Dark"),
			cylZ(0.25, 0.26, V(0, 0.37, 0.65), "Dark"),
			cylZ(0.02, 0.28, V(0, 0.37, -1.06), "Lens"),
			block(V(0.04, 0.6, 0.04), V(-0.1, -0.3, -1.4), "Dark", V(0, 0, -15)),
			block(V(0.04, 0.6, 0.04), V(0.1, -0.3, -1.4), "Dark", V(0, 0, 15)),
		},
		Muzzle = V(0, 0.05, -2.88),
		Aim = V(0, 0.37, 1),
		GripR = V(0, -0.33, 0.47),
		GripL = V(0, -0.12, -0.8),
		Hip = CFrame.new(0.65, -0.66, -1.45),
	},

	LMG = {
		Parts = concat({
			block(V(0.32, 0.42, 1.5), V(0, 0, 0), "Body", nil, "Receiver"),
			block(V(0.3, 0.1, 0.9), V(0, 0.26, -0.1), "Dark"),
			block(V(0.24, 0.24, 1), V(0, 0.05, -1.25), "Accent", nil, "Shroud"),
			cylZ(0.8, 0.09, V(0, 0.05, -2.15), "Dark"),
			block(V(0.36, 0.42, 0.45), V(0.04, -0.42, -0.3), "Accent", nil, "Mag"),
			block(V(0.17, 0.45, 0.24), V(0, -0.36, 0.42), "Dark", V(-18, 0, 0), "Grip"),
			block(V(0.26, 0.38, 0.8), V(0, -0.05, 1.15), "Body", nil, "Stock"),
			block(V(0.04, 0.5, 0.04), V(-0.1, -0.25, -1.5), "Dark", V(0, 0, -15)),
			block(V(0.04, 0.5, 0.04), V(0.1, -0.25, -1.5), "Dark", V(0, 0, 15)),
		}, reflexSight(0.31, 0.2)),
		Muzzle = V(0, 0.05, -2.55),
		Aim = V(0, 0.43, 0.65),
		GripR = V(0, -0.36, 0.44),
		GripL = V(0, -0.1, -1.1),
		Hip = CFrame.new(0.65, -0.68, -1.45),
	},

	-- Bullpup PDW with a translucent top-loaded magazine.
	PDW = {
		Parts = concat({
			block(V(0.28, 0.42, 1.25), V(0, 0, -0.05), "Body", nil, "Receiver"),
			block(V(0.2, 0.18, 0.5), V(0, -0.3, -0.1), "Body"),
			block(V(0.17, 0.4, 0.22), V(0, -0.35, -0.05), "Accent", V(-10, 0, 0), "Grip"),
			block(V(0.2, 0.3, 0.12), V(0, -0.28, -0.55), "Body"),
			block(V(0.22, 0.08, 1), V(0, 0.25, 0), "Lens", nil, "Mag"),
			cylZ(0.25, 0.09, V(0, 0.02, -0.78), "Dark"),
			cylZ(0.1, 0.12, V(0, 0.02, -0.93), "Dark"),
			block(V(0.26, 0.38, 0.12), V(0, -0.02, 0.6), "Accent"),
		}, reflexSight(0.29, -0.25)),
		Muzzle = V(0, 0.02, -1),
		Aim = V(0, 0.41, 0.2),
		GripR = V(0, -0.35, -0.03),
		GripL = V(0, -0.3, -0.45),
		Hip = CFrame.new(0.55, -0.55, -1.2),
	},

	-- Heavy bolt-action anti-materiel rifle.
	AMR = {
		Parts = {
			block(V(0.3, 0.36, 1.6), V(0, 0, 0), "Body", nil, "Receiver"),
			cylZ(2.6, 0.13, V(0, 0.06, -2.1), "Dark", "Barrel"),
			block(V(0.26, 0.18, 0.4), V(0, 0.06, -3.55), "Dark"),
			block(V(0.26, 0.28, 0.9), V(0, 0.03, -1.2), "Accent", nil, "Handguard"),
			block(V(0.26, 0.5, 1.2), V(0, -0.12, 1.35), "Accent", nil, "Stock"),
			block(V(0.18, 0.12, 0.5), V(0, 0.2, 1.1), "Accent"),
			block(V(0.18, 0.5, 0.26), V(0, -0.38, 0.5), "Accent", V(-18, 0, 0), "Grip"),
			block(V(0.2, 0.35, 0.36), V(0, -0.33, -0.15), "Dark", nil, "Mag"),
			block(V(0.05, 0.8, 0.05), V(-0.14, -0.4, -2), "Dark", V(0, 0, -15)),
			block(V(0.05, 0.8, 0.05), V(0.14, -0.4, -2), "Dark", V(0, 0, 15)),
			{ Size = V(0.3, 0.06, 0.06), Pos = V(0.22, 0.1, 0.4), Color = "Metal", Shape = "Cylinder" },
			ball(0.1, V(0.38, 0.1, 0.4), "Metal"),
			block(V(0.1, 0.14, 0.1), V(0, 0.25, -0.4), "Dark"),
			block(V(0.1, 0.14, 0.1), V(0, 0.25, 0.3), "Dark"),
			cylZ(1.5, 0.22, V(0, 0.42, -0.05), "Dark", "Scope"),
			cylZ(0.4, 0.34, V(0, 0.42, -0.95), "Dark"),
			cylZ(0.3, 0.28, V(0, 0.42, 0.8), "Dark"),
			cylZ(0.02, 0.32, V(0, 0.42, -1.16), "Lens"),
		},
		Muzzle = V(0, 0.06, -3.78),
		Aim = V(0, 0.42, 1.2),
		GripR = V(0, -0.38, 0.52),
		GripL = V(0, -0.15, -1.1),
		Hip = CFrame.new(0.7, -0.72, -1.55),
	},

	-- Six-barrel rotary gun carried at the hip.
	Minigun = {
		Parts = {
			block(V(0.36, 0.42, 0.9), V(0, 0, 0), "Body", nil, "Housing"),
			cylZ(1.6, 0.07, V(0.12, 0.02, -1.25), "Dark"),
			cylZ(1.6, 0.07, V(0.06, 0.124, -1.25), "Dark"),
			cylZ(1.6, 0.07, V(-0.06, 0.124, -1.25), "Dark"),
			cylZ(1.6, 0.07, V(-0.12, 0.02, -1.25), "Dark"),
			cylZ(1.6, 0.07, V(-0.06, -0.084, -1.25), "Dark"),
			cylZ(1.6, 0.07, V(0.06, -0.084, -1.25), "Dark"),
			cylZ(0.08, 0.38, V(0, 0.02, -1.6), "Metal"),
			cylZ(0.08, 0.38, V(0, 0.02, -0.9), "Metal"),
			block(V(0.2, 0.2, 0.5), V(0, 0.3, 0.1), "Accent", nil, "Motor"),
			block(V(0.06, 0.06, 0.6), V(0, 0.55, -0.1), "Dark"),
			block(V(0.06, 0.2, 0.06), V(0, 0.45, 0.15), "Dark"),
			block(V(0.06, 0.2, 0.06), V(0, 0.45, -0.35), "Dark"),
			block(V(0.14, 0.4, 0.16), V(0.12, -0.25, 0.42), "Dark", nil, "Grip"),
			block(V(0.12, 0.35, 0.12), V(-0.25, -0.2, -0.4), "Dark"),
			block(V(0.4, 0.4, 0.45), V(0.1, -0.45, 0.1), "Accent", nil, "AmmoBox"),
			block(V(0.1, 0.3, 0.1), V(0.05, -0.2, -0.1), "Dark"),
		},
		Muzzle = V(0, 0.02, -2.05),
		Aim = V(0, 0.5, 0.6),
		GripR = V(0.12, -0.3, 0.42),
		GripL = V(-0.25, -0.3, -0.4),
		Hip = CFrame.new(0.45, -0.75, -1.3),
	},

	-- Optical (laser) pistol.
	Blaster = {
		Parts = {
			block(V(0.2, 0.26, 0.85), V(0, 0.1, -0.1), "Body", nil, "Body"),
			cylZ(0.25, 0.14, V(0, 0.1, -0.62), "AccentGlow", "Emitter"),
			block(V(0.02, 0.08, 0.35), V(0.11, 0.1, 0.05), "AccentGlow"),
			block(V(0.17, 0.48, 0.26), V(0, -0.28, 0.18), "Dark", V(-15, 0, 0), "Grip"),
			block(V(0.24, 0.04, 0.3), V(0, 0.25, -0.2), "Body"),
			block(V(0.03, 0.05, 0.03), V(0, 0.255, -0.5), "Dark"),
			block(V(0.04, 0.05, 0.04), V(-0.05, 0.255, 0.25), "Dark"),
			block(V(0.04, 0.05, 0.04), V(0.05, 0.255, 0.25), "Dark"),
		},
		Muzzle = V(0, 0.1, -0.76),
		Aim = V(0, 0.28, 0.45),
		GripR = V(0, -0.28, 0.2),
		GripL = V(-0.07, -0.32, 0.16),
		Hip = CFrame.new(0.55, -0.55, -1.45),
	},

	-- Optical (laser) assault rifle.
	OpticalRifle = {
		Parts = concat({
			block(V(0.24, 0.34, 1.3), V(0, 0, 0), "Body", nil, "Receiver"),
			block(V(0.26, 0.3, 1), V(0, 0.02, -1.1), "Body", nil, "Shroud"),
			cylZ(0.12, 0.22, V(0, 0.03, -1.7), "AccentGlow", "Emitter"),
			cylZ(0.2, 0.12, V(0, 0.03, -1.85), "Dark"),
			block(V(0.02, 0.06, 1.6), V(-0.13, 0.05, -0.5), "AccentGlow"),
			block(V(0.02, 0.06, 1.6), V(0.13, 0.05, -0.5), "AccentGlow"),
			block(V(0.16, 0.45, 0.3), V(0, -0.36, -0.35), "Dark", nil, "Battery"),
			block(V(0.17, 0.45, 0.24), V(0, -0.33, 0.35), "Dark", V(-18, 0, 0), "Grip"),
			block(V(0.2, 0.3, 0.8), V(0, -0.05, 1.05), "Body", nil, "Stock"),
			block(V(0.12, 0.04, 1.2), V(0, 0.19, -0.3), "Dark"),
		}, reflexSight(0.21, 0)),
		Muzzle = V(0, 0.03, -1.96),
		Aim = V(0, 0.33, 0.45),
		GripR = V(0, -0.33, 0.37),
		GripL = V(0, -0.12, -1),
		Hip = CFrame.new(0.62, -0.62, -1.35),
	},

	-- Photon sword: a hilt with a glowing blade along -Z.
	Blade = {
		Parts = {
			cylZ(0.5, 0.14, V(0, 0, 0.05), "Body", "Hilt"),
			cylZ(0.08, 0.2, V(0, 0, -0.22), "Metal"),
			cylZ(0.06, 0.16, V(0, 0, 0.32), "Metal"),
			cylZ(2.6, 0.12, V(0, 0, -1.55), "AccentGlow", "Blade"),
		},
		Muzzle = V(0, 0, -2.85),
		Aim = V(0, 0.3, 0.6),
		GripR = V(0, 0, 0),
		GripL = V(0, 0, 0.25),
		Hip = CFrame.new(0.55, -0.6, -1.3) * CFrame.Angles(math.rad(35), math.rad(10), math.rad(-20)),
	},
}

local WeaponModel = {}

function WeaponModel.GetStyle(style: ModelStyle): StyleSpec
	return Styles[style]
end

local function makePart(spec: PartSpec, palette: { [ColorKey]: Color3 }): Part
	local part = Instance.new("Part")
	part.Name = spec.Name or "Part"
	part.Size = spec.Size
	local rot = spec.Rot or Vector3.zero
	part.CFrame = CFrame.new(spec.Pos) * CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))
	part.Color = palette[spec.Color]
	if spec.Color == "Glow" or spec.Color == "AccentGlow" then
		part.Material = Enum.Material.Neon
	elseif spec.Color == "Lens" then
		part.Material = Enum.Material.Glass
		part.Transparency = 0.3
		part.Reflectance = 0.3
	elseif spec.Color == "Metal" then
		part.Material = Enum.Material.Metal
	else
		part.Material = Enum.Material.SmoothPlastic
		part.Reflectance = 0.04
	end
	if spec.Shape == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
	elseif spec.Shape == "Ball" then
		part.Shape = Enum.PartType.Ball
	end
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	return part
end

local function addAttachment(parent: BasePart, name: string, position: Vector3)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = position
	attachment.Parent = parent
end

-- Builds a gun at the origin. All parts are welded to the invisible Handle,
-- which is the model's PrimaryPart; move the gun by moving the Handle.
function WeaponModel.BuildStyle(style: ModelStyle, body: Color3, accent: Color3, name: string?): Model
	local spec = Styles[style]
	local palette: { [ColorKey]: Color3 } = {
		Body = body,
		Accent = accent,
		AccentGlow = accent,
		Dark = DARK,
		Metal = METAL,
		Glow = GLOW,
		Lens = LENS,
	}

	local model = Instance.new("Model")
	model.Name = name or style

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.2, 0.2, 0.2)
	handle.CFrame = CFrame.identity
	handle.Transparency = 1
	handle.Anchored = false
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.Parent = model

	for _, partSpec in spec.Parts do
		local part = makePart(partSpec, palette)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = handle
		weld.Part1 = part
		weld.Parent = part
		part.Parent = model
	end

	addAttachment(handle, "Muzzle", spec.Muzzle)
	addAttachment(handle, "Aim", spec.Aim)
	addAttachment(handle, "GripR", spec.GripR)
	addAttachment(handle, "GripL", spec.GripL)

	model.PrimaryPart = handle
	return model
end

function WeaponModel.Build(def: WeaponDef): Model
	return WeaponModel.BuildStyle(def.Model.Style, def.Model.Body, def.Model.Accent, def.Id)
end

return WeaponModel
