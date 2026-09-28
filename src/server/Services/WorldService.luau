--!strict
-- Generates the entire map at server start from Config.Zones, so the game
-- runs from an empty Baseplate with no uploaded assets. Layouts are seeded,
-- so every server builds the same world.
--
-- Also owns the shared workspace folders and the interactive hub props
-- (Armory, resupply crate, transit pads), exposing their use as signals so
-- gameplay services decide what happens.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enemies = require(ReplicatedStorage.Shared.Config.Enemies)
local Progression = require(ReplicatedStorage.Shared.Config.Progression)
local Signal = require(ReplicatedStorage.Shared.Signal)
local WeaponModel = require(ReplicatedStorage.Shared.WeaponModel)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type ZoneDef = Zones.ZoneDef
type Theme = typeof(Zones.List[1].Theme)

local WorldService = {}

WorldService.ArmoryRequested = Signal.new() -- (player: Player)
WorldService.ResupplyRequested = Signal.new() -- (player: Player)
WorldService.TravelRequested = Signal.new() -- (player: Player, zoneId: string)
WorldService.ReturnRequested = Signal.new() -- (player: Player)

local V = Vector3.new
local CELL = 42
local WALL_HEIGHT = 26
local BARRIER_HEIGHT = 220
local MAP_HALF_WIDTH = 250

local folders: { [string]: Folder } = {}
local spawnPoints: { [string]: { Vector3 } } = {}
local bossSpots: { [string]: Vector3 } = {}
local dummySpots: { CFrame } = {}
local leaderboardRows: Frame? = nil

---------------------------------------------------------------------------
-- Part helpers
---------------------------------------------------------------------------

type PartProps = {
	Name: string?,
	Size: Vector3,
	CFrame: CFrame,
	Color: Color3,
	Material: Enum.Material?,
	Transparency: number?,
	CanCollide: boolean?,
	CanQuery: boolean?,
	CastShadow: boolean?,
	Shape: Enum.PartType?,
}

local function makePart(props: PartProps, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = props.Name or "Part"
	part.Anchored = true
	part.Size = props.Size
	part.CFrame = props.CFrame
	part.Color = props.Color
	part.Material = props.Material or Enum.Material.SmoothPlastic
	part.Transparency = props.Transparency or 0
	if props.CanCollide ~= nil then
		part.CanCollide = props.CanCollide
	end
	if props.CanQuery ~= nil then
		part.CanQuery = props.CanQuery
	end
	if props.CastShadow ~= nil then
		part.CastShadow = props.CastShadow
	end
	if props.Shape then
		part.Shape = props.Shape
	end
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Box resting on the local ground plane of `frame` (y = 0 is the floor).
local function rest(
	parent: Instance,
	frame: CFrame,
	size: Vector3,
	x: number,
	z: number,
	color: Color3,
	material: Enum.Material?,
	y: number?
): Part
	return makePart({
		Size = size,
		CFrame = frame * CFrame.new(x, (y or 0) + size.Y / 2, z),
		Color = color,
		Material = material,
	}, parent)
end

local function addSign(
	part: BasePart,
	face: Enum.NormalId,
	text: string,
	textColor: Color3,
	background: Color3?
): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Brightness = 1.4

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = background or Color3.new(0, 0, 0)
	label.BackgroundTransparency = if background then 0 else 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = textColor
	label.Text = text

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0.04, 0)
	padding.PaddingRight = UDim.new(0.04, 0)
	padding.PaddingTop = UDim.new(0.1, 0)
	padding.PaddingBottom = UDim.new(0.1, 0)
	padding.Parent = label

	label.Parent = gui
	gui.Parent = part
	return label
end

local function addPrompt(
	part: BasePart,
	action: string,
	object: string,
	hold: number,
	onTriggered: (Player) -> ()
): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = hold
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Triggered:Connect(onTriggered)
	prompt.Parent = part
	return prompt
end

type Opening = {
	Center: number,
	Width: number,
	Bottom: number,
	Height: number,
}

-- Wall along the local X axis of `frame` (frame sits at the wall's bottom
-- centre), split into solid segments around rectangular openings.
local function wall(
	parent: Instance,
	frame: CFrame,
	length: number,
	height: number,
	thickness: number,
	color: Color3,
	material: Enum.Material,
	openings: { Opening }?
)
	local function segment(x0: number, x1: number, y0: number, y1: number)
		if x1 - x0 < 0.05 or y1 - y0 < 0.05 then
			return
		end
		makePart({
			Size = V(x1 - x0, y1 - y0, thickness),
			CFrame = frame * CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, 0),
			Color = color,
			Material = material,
		}, parent)
	end

	local sorted: { Opening } = table.clone(openings or {})
	table.sort(sorted, function(a: Opening, b: Opening)
		return a.Center < b.Center
	end)

	local cursor = -length / 2
	for _, opening in sorted do
		local left = math.max(cursor, opening.Center - opening.Width / 2)
		local right = math.min(length / 2, opening.Center + opening.Width / 2)
		local top = math.min(height, opening.Bottom + opening.Height)
		segment(cursor, left, 0, height)
		segment(left, right, 0, opening.Bottom)
		segment(left, right, top, height)
		cursor = right
	end
	segment(cursor, length / 2, 0, height)
end

-- Visible wall plus a tall invisible barrier so players can't leave the map.
local function boundaryWall(parent: Instance, center: Vector3, size: Vector3, color: Color3, material: Enum.Material)
	makePart({
		Name = "BoundaryWall",
		Size = size,
		CFrame = CFrame.new(center + V(0, size.Y / 2, 0)),
		Color = color,
		Material = material,
	}, parent)
	makePart({
		Name = "Barrier",
		Size = V(size.X, BARRIER_HEIGHT, size.Z),
		CFrame = CFrame.new(center + V(0, size.Y + BARRIER_HEIGHT / 2, 0)),
		Color = color,
		Transparency = 1,
		CanQuery = false,
		CastShadow = false,
	}, parent)
end

---------------------------------------------------------------------------
-- Zone props
---------------------------------------------------------------------------

local CONTAINER_COLORS = {
	Color3.fromRGB(140, 50, 40),
	Color3.fromRGB(40, 80, 130),
	Color3.fromRGB(50, 100, 60),
	Color3.fromRGB(190, 110, 40),
	Color3.fromRGB(110, 110, 115),
}

local function building(parent: Instance, origin: CFrame, rng: Random, theme: Theme, tall: boolean)
	local model = Instance.new("Model")
	model.Name = "Building"
	local w = rng:NextInteger(18, 30)
	local d = rng:NextInteger(18, 28)
	local h = if tall then rng:NextInteger(15, 24) else rng:NextInteger(11, 15)
	local t = 1.2
	local ruined = not tall and rng:NextNumber() < 0.4
	local color = theme.Prop
	local material = theme.PropMaterial

	local function wallHeight(): number
		return if ruined then math.floor(h * rng:NextNumber(0.35, 0.9)) else h
	end

	local door: Opening = { Center = rng:NextNumber(-w / 2 + 5, w / 2 - 5), Width = 6, Bottom = 0, Height = 9 }
	local window: Opening = { Center = 0, Width = 5, Bottom = 4.5, Height = 3.5 }

	-- Front (with door) and back (door or window).
	wall(model, origin * CFrame.new(0, 0, -d / 2 + t / 2), w, wallHeight(), t, color, material, { door })
	local backOpening: Opening = if rng:NextNumber() < 0.5
		then { Center = -door.Center, Width = 6, Bottom = 0, Height = 9 }
		else window
	wall(model, origin * CFrame.new(0, 0, d / 2 - t / 2), w, wallHeight(), t, color, material, { backOpening })
	-- Sides with windows.
	for _, side in { -1, 1 } do
		local frame = origin * CFrame.new(side * (w / 2 - t / 2), 0, 0) * CFrame.Angles(0, math.rad(90), 0)
		wall(model, frame, d - 2 * t, wallHeight(), t, color, material, {
			{ Center = rng:NextNumber(-d / 4, d / 4), Width = 4, Bottom = 4.5, Height = 3.5 },
		})
	end

	if not ruined then
		rest(model, origin, V(w + 1, 1, d + 1), 0, 0, color:Lerp(Color3.new(0, 0, 0), 0.25), material, h)
	end

	-- Interior cover.
	for _ = 1, rng:NextInteger(1, 2) do
		rest(
			model,
			origin,
			V(4, 4, 4),
			rng:NextNumber(-w / 4, w / 4),
			rng:NextNumber(-d / 4, d / 4),
			Color3.fromRGB(120, 90, 60),
			Enum.Material.WoodPlanks
		)
	end
	model.Parent = parent
end

local function crates(parent: Instance, origin: CFrame, rng: Random)
	local previous: Part? = nil
	for _ = 1, rng:NextInteger(2, 5) do
		local size = rng:NextInteger(3, 5)
		local color = Color3.fromRGB(130, 95, 60):Lerp(Color3.fromRGB(90, 70, 50), rng:NextNumber())
		if previous and rng:NextNumber() < 0.35 then
			local top = previous.Position.Y + previous.Size.Y / 2
			makePart({
				Name = "Crate",
				Size = V(size, size, size),
				CFrame = CFrame.new(previous.Position.X, top + size / 2, previous.Position.Z)
					* CFrame.Angles(0, rng:NextNumber(0, 1), 0),
				Color = color,
				Material = Enum.Material.WoodPlanks,
			}, parent)
		else
			previous = makePart({
				Name = "Crate",
				Size = V(size, size, size),
				CFrame = origin
					* CFrame.new(rng:NextNumber(-9, 9), size / 2, rng:NextNumber(-9, 9))
					* CFrame.Angles(0, rng:NextNumber(0, 1), 0),
				Color = color,
				Material = Enum.Material.WoodPlanks,
			}, parent)
		end
	end
end

local function barriers(parent: Instance, origin: CFrame, rng: Random)
	local rows = if rng:NextNumber() < 0.5 then 2 else 1
	for row = 1, rows do
		local frame = if row == 1 then origin else origin * CFrame.new(-10, 0, 8) * CFrame.Angles(0, math.rad(90), 0)
		local count = rng:NextInteger(2, 4)
		for i = 1, count do
			local x = (i - (count + 1) / 2) * 8.6
			rest(parent, frame, V(8, 1, 2.6), x, 0, Color3.fromRGB(170, 170, 165), Enum.Material.Concrete)
			rest(parent, frame, V(8, 3.6, 1.6), x, 0, Color3.fromRGB(185, 185, 180), Enum.Material.Concrete, 1)
		end
	end
end

local function container(parent: Instance, origin: CFrame, rng: Random)
	local color = CONTAINER_COLORS[rng:NextInteger(1, #CONTAINER_COLORS)]
	rest(parent, origin, V(20, 8.5, 8), 0, 0, color, Enum.Material.CorrodedMetal)
	if rng:NextNumber() < 0.35 then
		local top = CONTAINER_COLORS[rng:NextInteger(1, #CONTAINER_COLORS)]
		rest(
			parent,
			origin * CFrame.Angles(0, rng:NextNumber(-0.15, 0.15), 0),
			V(20, 8.5, 8),
			1,
			0,
			top,
			Enum.Material.CorrodedMetal,
			8.5
		)
	elseif rng:NextNumber() < 0.5 then
		rest(
			parent,
			origin * CFrame.new(0, 0, 11) * CFrame.Angles(0, 0.1, 0),
			V(20, 8.5, 8),
			0,
			0,
			color:Lerp(Color3.new(0, 0, 0), 0.2),
			Enum.Material.CorrodedMetal
		)
	end
end

local function rocks(parent: Instance, origin: CFrame, rng: Random, theme: Theme)
	local color = theme.Ground:Lerp(Color3.fromRGB(110, 105, 100), 0.6)
	for _ = 1, rng:NextInteger(2, 4) do
		local size = V(rng:NextNumber(4, 11), rng:NextNumber(3, 8), rng:NextNumber(4, 11))
		makePart({
			Name = "Rock",
			Size = size,
			CFrame = origin
				* CFrame.new(rng:NextNumber(-9, 9), size.Y * 0.35, rng:NextNumber(-9, 9))
				* CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, math.pi * 2), rng:NextNumber(-0.3, 0.3)),
			Color = color:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.25)),
			Material = Enum.Material.Rock,
		}, parent)
	end
end

local function tower(parent: Instance, origin: CFrame, theme: Theme)
	local height = 16
	local metal = Color3.fromRGB(80, 80, 84)
	for _, corner in { V(-4.5, 0, -4.5), V(4.5, 0, -4.5), V(-4.5, 0, 4.5), V(4.5, 0, 4.5) } do
		rest(parent, origin, V(1, height, 1), corner.X, corner.Z, metal, Enum.Material.Metal)
	end
	rest(parent, origin, V(11, 1, 11), 0, 0, theme.Prop, Enum.Material.WoodPlanks, height)
	-- Rails on three sides; the ladder side stays open.
	rest(parent, origin, V(11, 3, 0.5), 0, 5.25, metal, Enum.Material.Metal, height + 1)
	rest(parent, origin, V(0.5, 3, 11), -5.25, 0, metal, Enum.Material.Metal, height + 1)
	rest(parent, origin, V(0.5, 3, 11), 5.25, 0, metal, Enum.Material.Metal, height + 1)

	local ladder = Instance.new("TrussPart")
	ladder.Name = "Ladder"
	ladder.Anchored = true
	ladder.Size = V(2, height + 2, 2)
	ladder.CFrame = origin * CFrame.new(0, (height + 2) / 2, -6.5)
	ladder.Color = metal
	ladder.Material = Enum.Material.Metal
	ladder.Parent = parent
end

local function wreck(parent: Instance, origin: CFrame, rng: Random)
	local frame = origin * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	local paint = CONTAINER_COLORS[rng:NextInteger(1, #CONTAINER_COLORS)]:Lerp(Color3.fromRGB(80, 70, 60), 0.5)
	rest(parent, frame, V(5.4, 2.4, 11), 0, 0, paint, Enum.Material.CorrodedMetal, 0.6)
	rest(parent, frame, V(5, 2, 5.5), 0, 0.8, Color3.fromRGB(30, 34, 40), Enum.Material.Glass, 3)
	for _, wheel in { V(-2.8, 0, -3.4), V(2.8, 0, -3.4), V(-2.8, 0, 3.4), V(2.8, 0, 3.4) } do
		makePart({
			Name = "Wheel",
			Size = V(1, 2.4, 2.4),
			CFrame = frame * CFrame.new(wheel.X, 1.2, wheel.Z),
			Color = Color3.fromRGB(25, 25, 25),
			Material = Enum.Material.Rubber,
			Shape = Enum.PartType.Cylinder,
		}, parent)
	end
end

local function sandbags(parent: Instance, origin: CFrame)
	local tan = Color3.fromRGB(176, 156, 112)
	for row = 0, 3 do
		local y = row * 0.95
		local shift = if row % 2 == 0 then 0 else 0.6
		rest(parent, origin, V(10, 0.95, 1.4), shift, -4, tan, Enum.Material.Fabric, y)
		rest(parent, origin, V(1.4, 0.95, 7), -5.7, -0.8 + shift, tan, Enum.Material.Fabric, y)
		rest(parent, origin, V(1.4, 0.95, 7), 5.7, -0.8 + shift, tan, Enum.Material.Fabric, y)
	end
end

local function trees(parent: Instance, origin: CFrame, rng: Random)
	for _ = 1, rng:NextInteger(2, 4) do
		local height = rng:NextNumber(10, 17)
		local x, z = rng:NextNumber(-12, 12), rng:NextNumber(-12, 12)
		makePart({
			Name = "Trunk",
			Size = V(height, 1.6, 1.6),
			CFrame = origin * CFrame.new(x, height / 2, z) * CFrame.Angles(0, 0, math.rad(90)),
			Color = Color3.fromRGB(95, 70, 45),
			Material = Enum.Material.Wood,
			Shape = Enum.PartType.Cylinder,
		}, parent)
		for _ = 1, rng:NextInteger(2, 3) do
			local size = rng:NextNumber(7, 11)
			makePart({
				Name = "Leaves",
				Size = V(size, size, size),
				CFrame = origin
					* CFrame.new(x + rng:NextNumber(-2, 2), height + rng:NextNumber(-1, 2), z + rng:NextNumber(-2, 2)),
				Color = Color3.fromRGB(60, 110, 50):Lerp(Color3.fromRGB(90, 140, 60), rng:NextNumber()),
				Material = Enum.Material.Grass,
				Shape = Enum.PartType.Ball,
			}, parent)
		end
	end
end

type PropKind =
	"Building"
	| "Tall"
	| "Crates"
	| "Barriers"
	| "Container"
	| "Rocks"
	| "Tower"
	| "Wreck"
	| "Sandbags"
	| "Trees"

type WeightedProp = {
	Kind: PropKind,
	Weight: number,
}

-- Arrays (not dictionaries) so the seeded layout is identical on every server.
local PROP_WEIGHTS: { [string]: { WeightedProp } } = {
	Outskirts = {
		{ Kind = "Building", Weight = 3 },
		{ Kind = "Crates", Weight = 2 },
		{ Kind = "Trees", Weight = 4 },
		{ Kind = "Rocks", Weight = 1 },
		{ Kind = "Wreck", Weight = 1 },
		{ Kind = "Sandbags", Weight = 1 },
		{ Kind = "Tower", Weight = 1 },
	},
	Wastes = {
		{ Kind = "Building", Weight = 3 },
		{ Kind = "Container", Weight = 2 },
		{ Kind = "Wreck", Weight = 2 },
		{ Kind = "Rocks", Weight = 2 },
		{ Kind = "Barriers", Weight = 1 },
		{ Kind = "Sandbags", Weight = 1 },
		{ Kind = "Tower", Weight = 1 },
	},
	Core = {
		{ Kind = "Tall", Weight = 4 },
		{ Kind = "Container", Weight = 2 },
		{ Kind = "Barriers", Weight = 3 },
		{ Kind = "Sandbags", Weight = 1 },
		{ Kind = "Tower", Weight = 1 },
		{ Kind = "Crates", Weight = 1 },
	},
}

local function pickProp(zoneId: string, rng: Random): PropKind
	local weights = PROP_WEIGHTS[zoneId] or PROP_WEIGHTS.Wastes
	local total = 0
	for _, entry in weights do
		total += entry.Weight
	end
	local roll = rng:NextNumber() * total
	for _, entry in weights do
		roll -= entry.Weight
		if roll <= 0 then
			return entry.Kind
		end
	end
	return weights[#weights].Kind
end

local function placeProp(parent: Instance, zone: ZoneDef, origin: CFrame, rng: Random)
	local kind = pickProp(zone.Id, rng)
	if kind == "Building" then
		building(parent, origin, rng, zone.Theme, false)
	elseif kind == "Tall" then
		building(parent, origin, rng, zone.Theme, true)
	elseif kind == "Crates" then
		crates(parent, origin, rng)
	elseif kind == "Barriers" then
		barriers(parent, origin, rng)
	elseif kind == "Container" then
		container(parent, origin, rng)
	elseif kind == "Rocks" then
		rocks(parent, origin, rng, zone.Theme)
	elseif kind == "Tower" then
		tower(parent, origin, zone.Theme)
	elseif kind == "Wreck" then
		wreck(parent, origin, rng)
	elseif kind == "Sandbags" then
		sandbags(parent, origin)
	elseif kind == "Trees" then
		trees(parent, origin, rng)
	end
end

---------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------

local function buildGround(parent: Instance, zone: ZoneDef)
	makePart({
		Name = "Ground",
		Size = V(zone.Width, 20, zone.Depth),
		CFrame = CFrame.new(zone.Center.X, -10, zone.Center.Z),
		Color = zone.Theme.Ground,
		Material = zone.Theme.GroundMaterial,
	}, parent)
end

-- Arch over the road at a zone's southern edge, signed on both faces.
local function buildGate(parent: Instance, zone: ZoneDef, previous: ZoneDef)
	local z = zone.Center.Z + zone.Depth / 2
	local accent = zone.Theme.Accent
	for _, x in { -22, 22 } do
		makePart({
			Name = "GatePillar",
			Size = V(4, 28, 4),
			CFrame = CFrame.new(x, 14, z),
			Color = Color3.fromRGB(60, 60, 64),
			Material = Enum.Material.Metal,
		}, parent)
	end
	local beam = makePart({
		Name = "GateBeam",
		Size = V(48, 6, 3),
		CFrame = CFrame.new(0, 29, z),
		Color = Color3.fromRGB(30, 30, 34),
		Material = Enum.Material.Metal,
	}, parent)
	local ahead =
		`{string.upper(zone.DisplayName)}  •  {if zone.PvP then "PVP ZONE" else "PVE"}  •  LV {zone.RecommendedLevel}+`
	addSign(beam, Enum.NormalId.Back, ahead, accent)
	addSign(beam, Enum.NormalId.Front, string.upper(previous.DisplayName), previous.Theme.Accent)

	-- A glowing line across the whole zone boundary; red where PvP starts.
	makePart({
		Name = "BoundaryLine",
		Size = V(zone.Width, 0.2, 1),
		CFrame = CFrame.new(zone.Center.X, 0.1, z),
		Color = if zone.PvP then Color3.fromRGB(255, 40, 40) else accent,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	}, parent)
end

local function buildReturnBeacon(parent: Instance, zone: ZoneDef)
	local landing = Zones.GetLandingPoint(zone)
	local beacon = makePart({
		Name = "ReturnBeacon",
		Size = V(2, 9, 2),
		CFrame = CFrame.new(landing + V(18, 4.5, 0)),
		Color = Color3.fromRGB(0, 200, 255),
		Material = Enum.Material.Neon,
	}, parent)
	addPrompt(beacon, "Return to Haven", "Transit Beacon", 1.5, function(player)
		WorldService.ReturnRequested:Fire(player)
	end)
end

local function buildArena(parent: Instance, zone: ZoneDef, center: Vector3)
	makePart({
		Name = "ArenaFloor",
		Size = V(0.4, 120, 120),
		CFrame = CFrame.new(center + V(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = zone.Theme.Ground:Lerp(Color3.new(0, 0, 0), 0.3),
		Material = Enum.Material.Slate,
		Shape = Enum.PartType.Cylinder,
	}, parent)
	for i = 0, 23 do
		local angle = i / 24 * math.pi * 2
		makePart({
			Name = "ArenaRing",
			Size = V(1, 0.3, 14),
			CFrame = CFrame.new(center + V(math.cos(angle) * 58, 0.45, math.sin(angle) * 58))
				* CFrame.Angles(0, -angle, 0),
			Color = zone.Theme.Accent,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
		}, parent)
	end
	for i = 0, 7 do
		local angle = (i + 0.5) / 8 * math.pi * 2
		makePart({
			Name = "ArenaPillar",
			Size = V(5, 16, 5),
			CFrame = CFrame.new(center + V(math.cos(angle) * 40, 8, math.sin(angle) * 40)),
			Color = zone.Theme.Prop,
			Material = zone.Theme.PropMaterial,
		}, parent)
	end
end

local function buildCombatZone(parent: Instance, zone: ZoneDef)
	local rng = Random.new(zone.Seed)
	local points: { Vector3 } = {}
	local nx = math.floor(zone.Width / CELL)
	local nz = math.floor(zone.Depth / CELL)
	local x0 = zone.Center.X - nx * CELL / 2
	local z0 = zone.Center.Z - nz * CELL / 2
	local southEdge = zone.Center.Z + zone.Depth / 2
	local hasBoss = false
	for _, entry in zone.Enemies do
		local def = Enemies.Get(entry.Id)
		hasBoss = hasBoss or (def ~= nil and def.Boss == true)
	end
	local arena = if hasBoss then zone.Center else nil

	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local center = V(x0 + (i + 0.5) * CELL, 0, z0 + (j + 0.5) * CELL)
			if math.abs(center.X) < 30 or southEdge - center.Z < 45 then
				continue -- keep the road and the entrance clear
			end
			if arena and (center - arena).Magnitude < 75 then
				continue
			end
			if rng:NextNumber() < zone.PropDensity then
				local origin = CFrame.new(center) * CFrame.Angles(0, math.rad(90 * rng:NextInteger(0, 3)), 0)
				placeProp(parent, zone, origin, rng)
			else
				table.insert(points, center + V(rng:NextNumber(-10, 10), 0, rng:NextNumber(-10, 10)))
			end
		end
	end

	-- Road down the middle.
	makePart({
		Name = "Road",
		Size = V(28, 0.2, zone.Depth),
		CFrame = CFrame.new(zone.Center.X, 0, zone.Center.Z),
		Color = Color3.fromRGB(58, 58, 62),
		Material = Enum.Material.Asphalt,
	}, parent)

	if arena then
		buildArena(parent, zone, arena)
		bossSpots[zone.Id] = arena
	end
	spawnPoints[zone.Id] = points
	buildReturnBeacon(parent, zone)
end

---------------------------------------------------------------------------
-- Haven (safe hub)
---------------------------------------------------------------------------

local function buildHaven(parent: Instance, zone: ZoneDef)
	local white = Color3.fromRGB(215, 218, 222)
	local steel = Color3.fromRGB(70, 74, 82)
	local accent = zone.Theme.Accent

	-- Plaza and central beacon.
	makePart({
		Name = "Plaza",
		Size = V(90, 0.2, 90),
		CFrame = CFrame.new(0, 0.1, 0),
		Color = Color3.fromRGB(190, 192, 196),
		Material = Enum.Material.Marble,
	}, parent)
	makePart({
		Name = "Road",
		Size = V(28, 0.2, 65),
		CFrame = CFrame.new(0, 0.1, -77.5),
		Color = Color3.fromRGB(58, 58, 62),
		Material = Enum.Material.Asphalt,
	}, parent)
	rest(parent, CFrame.identity, V(14, 2, 14), 0, 0, steel, Enum.Material.DiamondPlate)
	rest(parent, CFrame.identity, V(5, 34, 5), 0, 0, white, Enum.Material.SmoothPlastic, 2)
	for _, y in { 10, 20, 30 } do
		rest(parent, CFrame.identity, V(6, 0.6, 6), 0, 0, accent, Enum.Material.Neon, y)
	end
	local orb = makePart({
		Name = "BeaconOrb",
		Size = V(7, 7, 7),
		CFrame = CFrame.new(0, 40, 0),
		Color = accent,
		Material = Enum.Material.Neon,
		Shape = Enum.PartType.Ball,
	}, parent)
	local light = Instance.new("PointLight")
	light.Color = accent
	light.Range = 60
	light.Brightness = 2
	light.Parent = orb

	-- Spawn pads around the beacon.
	for _, offset in { V(-20, 0, -20), V(20, 0, -20), V(-20, 0, 20), V(20, 0, 20) } do
		local spawn = Instance.new("SpawnLocation")
		spawn.Name = "HavenSpawn"
		spawn.Anchored = true
		spawn.Size = V(8, 1, 8)
		spawn.CFrame = CFrame.new(offset + V(0, 0.5, 0))
		spawn.Color = accent
		spawn.Material = Enum.Material.SmoothPlastic
		spawn.Neutral = true
		spawn.Duration = Progression.SpawnProtection
		spawn.TopSurface = Enum.SurfaceType.Smooth
		spawn.Parent = parent
	end

	-- Armory (west): open-fronted shop facing the plaza.
	local armory = CFrame.new(-72, 0, -5)
	rest(parent, armory, V(1.5, 14, 28), -9, 0, white, Enum.Material.SmoothPlastic)
	rest(parent, armory, V(18, 14, 1.5), 0, -14, white, Enum.Material.SmoothPlastic)
	rest(parent, armory, V(18, 14, 1.5), 0, 14, white, Enum.Material.SmoothPlastic)
	rest(parent, armory, V(20, 1, 30), 0, 0, steel, Enum.Material.Metal, 14)
	local counter = rest(parent, armory, V(3, 3.5, 18), 4, 0, steel, Enum.Material.DiamondPlate)
	addPrompt(counter, "Open Armory", "Armory", 0, function(player)
		WorldService.ArmoryRequested:Fire(player)
	end)
	local armorySign =
		rest(parent, armory, V(1, 4, 20), 9.5, 0, Color3.fromRGB(20, 22, 26), Enum.Material.SmoothPlastic, 15)
	addSign(armorySign, Enum.NormalId.Right, "ARMORY", accent)
	-- Display a few guns on the back wall.
	local displayIndex = 0
	for _, def in Weapons.List do
		if def.Slot == "Primary" and displayIndex < 4 then
			local gun = WeaponModel.Build(def)
			local handle = gun.PrimaryPart :: BasePart
			handle.Anchored = true
			gun:ScaleTo(1.6)
			gun:PivotTo(armory * CFrame.new(-7.6, 5 + displayIndex * 2.2, 0))
			gun.Parent = parent
			displayIndex += 1
		end
	end

	-- Resupply crate.
	local crate =
		rest(parent, CFrame.new(-52, 0, -32), V(5, 4, 4), 0, 0, Color3.fromRGB(70, 90, 50), Enum.Material.Metal)
	rest(parent, CFrame.new(-52, 0, -32), V(5.1, 0.6, 4.1), 0, 0, Color3.fromRGB(255, 220, 60), Enum.Material.Neon, 2.4)
	addPrompt(crate, "Resupply", "Ammo Crate", 0.4, function(player)
		WorldService.ResupplyRequested:Fire(player)
	end)

	-- Transit terminal (east): one pad per combat zone.
	rest(parent, CFrame.new(72, 0, 0), V(26, 0.6, 90), 0, 0, steel, Enum.Material.DiamondPlate)
	local padIndex = 0
	for _, target in Zones.List do
		if target.Safe then
			continue
		end
		local z = -30 + padIndex * 30
		padIndex += 1
		local pad = makePart({
			Name = `Transit_{target.Id}`,
			Size = V(10, 0.4, 10),
			CFrame = CFrame.new(70, 0.8, z),
			Color = target.Theme.Accent,
			Material = Enum.Material.Neon,
		}, parent)
		local mode = if target.PvP then "PVP" else "PVE"
		addPrompt(pad, "Deploy", `{target.DisplayName} (Lv {target.RecommendedLevel}+ {mode})`, 0.6, function(player)
			WorldService.TravelRequested:Fire(player, target.Id)
		end)
		for _, dz in { -5.5, 5.5 } do
			rest(parent, CFrame.new(80, 0, z + dz), V(0.8, 14, 0.8), 0, 0, steel, Enum.Material.Metal)
		end
		local board = rest(
			parent,
			CFrame.new(80, 0, z),
			V(0.6, 4.5, 12),
			0,
			0,
			Color3.fromRGB(20, 22, 26),
			Enum.Material.SmoothPlastic,
			9.5
		)
		addSign(
			board,
			Enum.NormalId.Left,
			`{string.upper(target.DisplayName)}\nLV {target.RecommendedLevel}+ • {mode}`,
			target.Theme.Accent
		)
	end

	-- Firing range (south-west) with training dummies.
	local range = CFrame.new(-72, 0, 70)
	rest(parent, range, V(56, 0.3, 44), 0, 0, Color3.fromRGB(120, 110, 95), Enum.Material.Ground)
	rest(parent, range, V(2, 3.5, 44), 22, 0, steel, Enum.Material.Metal)
	rest(parent, range, V(1.5, 18, 44), -28, 0, Color3.fromRGB(90, 80, 70), Enum.Material.WoodPlanks)
	local rangeSign =
		rest(parent, range, V(1, 4, 16), 23, 0, Color3.fromRGB(20, 22, 26), Enum.Material.SmoothPlastic, 8)
	addSign(rangeSign, Enum.NormalId.Right, "FIRING RANGE", Color3.fromRGB(255, 220, 60))
	for i = 0, 3 do
		local position = (range * CFrame.new(-20, 0.1, -15 + i * 10)).Position
		table.insert(dummySpots, CFrame.lookAt(position, position + V(1, 0, 0)))
	end

	-- Global leaderboard (south), facing the plaza.
	for _, x in { -17, 17 } do
		rest(parent, CFrame.new(x, 0, 96), V(1.5, 26, 1.5), 0, 0, steel, Enum.Material.Metal)
	end
	local board = makePart({
		Name = "Leaderboard",
		Size = V(34, 22, 1),
		CFrame = CFrame.new(0, 15, 96),
		Color = Color3.fromRGB(16, 18, 22),
		Material = Enum.Material.SmoothPlastic,
	}, parent)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Brightness = 1.3
	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, 0.16)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = accent
	title.Text = "CHOSEN ONE  •  TOP OPERATIVES"
	title.Parent = gui
	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.Position = UDim2.fromScale(0.04, 0.18)
	rows.Size = UDim2.fromScale(0.92, 0.8)
	rows.BackgroundTransparency = 1
	rows.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = rows
	gui.Parent = board
	leaderboardRows = rows

	-- Skyline blocks along the south wall.
	local skyline = Random.new(zone.Seed)
	for x = -95, 95, 38 do
		if math.abs(x) < 25 then
			continue
		end
		local height = skyline:NextInteger(18, 40)
		local block = rest(
			parent,
			CFrame.new(x, 0, 104),
			V(22, height, 10),
			0,
			0,
			white:Lerp(steel, skyline:NextNumber(0, 0.5)),
			Enum.Material.Concrete
		)
		for y = 4, height - 4, 6 do
			rest(parent, CFrame.new(x, 0, 98.9), V(18, 1, 0.3), 0, 0, accent, Enum.Material.Neon, y)
		end
		block.Name = "Skyline"
	end

	-- Walls: west, east and south; the north side is shared with the Outskirts.
	boundaryWall(parent, V(-113, 0, 0), V(6, WALL_HEIGHT, 226), white, Enum.Material.Concrete)
	boundaryWall(parent, V(113, 0, 0), V(6, WALL_HEIGHT, 226), white, Enum.Material.Concrete)
	boundaryWall(parent, V(0, 0, 113), V(232, WALL_HEIGHT, 6), white, Enum.Material.Concrete)
end

-- North wall of Haven (with the gate) and the outer walls of the combat strip.
local function buildBoundaries(parent: Instance)
	local haven = Zones.Get(Zones.HubId) :: ZoneDef
	local north = haven.Center.Z - haven.Depth / 2
	local rock = Color3.fromRGB(96, 92, 88)
	local halfGate = 20
	local segment = MAP_HALF_WIDTH + 6 - halfGate
	boundaryWall(parent, V(-(halfGate + segment / 2), 0, north), V(segment, WALL_HEIGHT, 6), rock, Enum.Material.Slate)
	boundaryWall(parent, V(halfGate + segment / 2, 0, north), V(segment, WALL_HEIGHT, 6), rock, Enum.Material.Slate)

	local farthest = north
	for _, zone in Zones.List do
		if not zone.Safe then
			farthest = math.min(farthest, zone.Center.Z - zone.Depth / 2)
		end
	end
	local length = north - farthest
	local midZ = (north + farthest) / 2
	boundaryWall(parent, V(-MAP_HALF_WIDTH - 3, 0, midZ), V(6, WALL_HEIGHT, length), rock, Enum.Material.Slate)
	boundaryWall(parent, V(MAP_HALF_WIDTH + 3, 0, midZ), V(6, WALL_HEIGHT, length), rock, Enum.Material.Slate)
	boundaryWall(parent, V(0, 0, farthest - 3), V(MAP_HALF_WIDTH * 2 + 12, WALL_HEIGHT, 6), rock, Enum.Material.Slate)
end

local function setupLighting()
	Lighting.Ambient = Color3.fromRGB(70, 72, 80)
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 136)
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1
	Lighting.GlobalShadows = true

	local function ensure(className: string, name: string): Instance
		local existing = Lighting:FindFirstChild(name)
		if existing then
			return existing
		end
		local instance = Instance.new(className)
		instance.Name = name
		instance.Parent = Lighting
		return instance
	end

	local atmosphere = ensure("Atmosphere", "Atmosphere") :: Atmosphere
	atmosphere.Density = 0.32
	atmosphere.Haze = 1.4
	atmosphere.Color = Color3.fromRGB(200, 190, 175)
	atmosphere.Decay = Color3.fromRGB(110, 100, 90)
	atmosphere.Glare = 0.2

	local bloom = ensure("BloomEffect", "Bloom") :: BloomEffect
	bloom.Intensity = 0.6
	bloom.Size = 24
	bloom.Threshold = 1.6

	local grading = ensure("ColorCorrectionEffect", "Grading") :: ColorCorrectionEffect
	grading.Contrast = 0.08
	grading.Saturation = -0.05
	grading.TintColor = Color3.fromRGB(255, 248, 240)

	local rays = ensure("SunRaysEffect", "SunRays") :: SunRaysEffect
	rays.Intensity = 0.05
	rays.Spread = 0.8
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function WorldService.GetFolder(name: "World" | "Enemies" | "Drops"): Folder
	return folders[name]
end

function WorldService.GetSpawnPoints(zoneId: string): { Vector3 }
	return spawnPoints[zoneId] or {}
end

function WorldService.GetBossSpot(zoneId: string): Vector3?
	return bossSpots[zoneId]
end

function WorldService.GetDummySpots(): { CFrame }
	return dummySpots
end

function WorldService.GetLeaderboardRows(): Frame?
	return leaderboardRows
end

function WorldService.Init()
	-- The default Baseplate template would z-fight with the generated ground.
	for _, name in { "Baseplate", "SpawnLocation" } do
		local template = workspace:FindFirstChild(name)
		if template and template:IsA("BasePart") then
			template:Destroy()
		end
	end

	for _, name in { "World", "Enemies", "Drops" } do
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = workspace
		folders[name] = folder
	end

	setupLighting()

	local world = folders.World
	local previous: ZoneDef? = nil
	for _, zone in Zones.List do
		local zoneFolder = Instance.new("Folder")
		zoneFolder.Name = zone.Id
		buildGround(zoneFolder, zone)
		if zone.Safe then
			buildHaven(zoneFolder, zone)
		else
			buildCombatZone(zoneFolder, zone)
			if previous then
				buildGate(zoneFolder, zone, previous)
			end
		end
		zoneFolder.Parent = world
		previous = zone
	end
	buildBoundaries(world)
end

return WorldService
