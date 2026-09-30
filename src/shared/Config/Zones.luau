--!strict
-- World zones. The world is a north-running strip of zones: Haven (safe hub)
-- in the south, each zone further north is harder. Zone bounds are axis
-- aligned rectangles on the XZ plane; the ground top sits at Y = 0.

export type EnemySpawn = {
	Id: string,
	Count: number,
}

export type ZoneDef = {
	Id: string,
	DisplayName: string,
	Description: string,
	Center: Vector3,
	Width: number, -- X extent
	Depth: number, -- Z extent
	Safe: boolean, -- no damage of any kind to players
	PvP: boolean, -- players may damage each other
	RecommendedLevel: number,
	Theme: {
		Ground: Color3,
		GroundMaterial: Enum.Material,
		Prop: Color3,
		PropMaterial: Enum.Material,
		Accent: Color3,
	},
	PropDensity: number, -- 0..1 fraction of grid cells that receive cover
	Enemies: { EnemySpawn },
	Seed: number,
}

local Zones = {}

local list: { ZoneDef } = {
	{
		Id = "Haven",
		DisplayName = "Haven",
		Description = "The last city under the orange sky. Resupply, gear up and deploy.",
		Center = Vector3.new(0, 0, 0),
		Width = 220,
		Depth = 220,
		Safe = true,
		PvP = false,
		RecommendedLevel = 1,
		Theme = {
			Ground = Color3.fromRGB(150, 152, 156),
			GroundMaterial = Enum.Material.Concrete,
			Prop = Color3.fromRGB(200, 202, 206),
			PropMaterial = Enum.Material.SmoothPlastic,
			Accent = Color3.fromRGB(0, 200, 255),
		},
		PropDensity = 0,
		Enemies = {},
		Seed = 1,
	},
	{
		Id = "Outskirts",
		DisplayName = "The Dust Flats",
		Description = "Barren scrubland where scavengers pick through the wrecks.",
		Center = Vector3.new(0, 0, -360),
		Width = 500,
		Depth = 500,
		Safe = false,
		PvP = false,
		RecommendedLevel = 1,
		Theme = {
			Ground = Color3.fromRGB(150, 126, 94),
			GroundMaterial = Enum.Material.Ground,
			Prop = Color3.fromRGB(128, 100, 74),
			PropMaterial = Enum.Material.WoodPlanks,
			Accent = Color3.fromRGB(255, 200, 60),
		},
		PropDensity = 0.5,
		Enemies = {
			{ Id = "Scavenger", Count = 14 },
			{ Id = "Raider", Count = 5 },
		},
		Seed = 1337,
	},
	{
		Id = "Wastes",
		DisplayName = "The Wastes",
		Description = "Sun-bleached ruins. Raiders fight over what's left, and so do players.",
		Center = Vector3.new(0, 0, -860),
		Width = 500,
		Depth = 500,
		Safe = false,
		PvP = true,
		RecommendedLevel = 10,
		Theme = {
			Ground = Color3.fromRGB(196, 168, 118),
			GroundMaterial = Enum.Material.Sand,
			Prop = Color3.fromRGB(150, 110, 80),
			PropMaterial = Enum.Material.CorrodedMetal,
			Accent = Color3.fromRGB(255, 120, 30),
		},
		PropDensity = 0.55,
		Enemies = {
			{ Id = "Raider", Count = 5 },
			{ Id = "Marauder", Count = 9 },
			{ Id = "Sharpshooter", Count = 3 },
		},
		Seed = 4242,
	},
	{
		Id = "Core",
		DisplayName = "The Ruined Core",
		Description = "The shattered heart of the old city. Home of the Juggernaut.",
		Center = Vector3.new(0, 0, -1360),
		Width = 500,
		Depth = 500,
		Safe = false,
		PvP = true,
		RecommendedLevel = 25,
		Theme = {
			Ground = Color3.fromRGB(60, 62, 68),
			GroundMaterial = Enum.Material.Slate,
			Prop = Color3.fromRGB(70, 72, 80),
			PropMaterial = Enum.Material.DiamondPlate,
			Accent = Color3.fromRGB(255, 40, 60),
		},
		PropDensity = 0.6,
		Enemies = {
			{ Id = "Enforcer", Count = 9 },
			{ Id = "Sharpshooter", Count = 3 },
			{ Id = "Juggernaut", Count = 1 },
		},
		Seed = 9001,
	},
}

Zones.List = list
Zones.ById = {} :: { [string]: ZoneDef }
for _, zone in list do
	Zones.ById[zone.Id] = zone
end

Zones.HubId = "Haven"

function Zones.Get(id: any): ZoneDef?
	if typeof(id) ~= "string" then
		return nil
	end
	return Zones.ById[id]
end

function Zones.GetZoneAt(position: Vector3): ZoneDef?
	for _, zone in list do
		local offset = position - zone.Center
		if math.abs(offset.X) <= zone.Width / 2 and math.abs(offset.Z) <= zone.Depth / 2 then
			return zone
		end
	end
	return nil
end

function Zones.IsSafeAt(position: Vector3): boolean
	local zone = Zones.GetZoneAt(position)
	return zone ~= nil and zone.Safe
end

function Zones.IsPvPAt(position: Vector3): boolean
	local zone = Zones.GetZoneAt(position)
	return zone ~= nil and zone.PvP
end

-- Where transit pads drop players: just inside the zone's southern entrance.
function Zones.GetLandingPoint(zone: ZoneDef): Vector3
	return zone.Center + Vector3.new(0, 0, zone.Depth / 2 - 30)
end

return Zones
