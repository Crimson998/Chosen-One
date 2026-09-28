--!strict
-- First-person viewmodel: the procedural gun plus a pair of arms, posed
-- relative to the camera by WeaponController every frame.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponModel = require(ReplicatedStorage.Shared.WeaponModel)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

type WeaponDef = Weapons.WeaponDef

export type Viewmodel = {
	Def: WeaponDef,
	Model: Model,
	Root: BasePart,
	Muzzle: Attachment,
	Hip: CFrame, -- camera-space pose when not aiming
	Ads: CFrame, -- camera-space pose that puts the sight on the crosshair
	Parts: { BasePart },
	Flash: BasePart,
	FlashLight: PointLight,
}

local Viewmodel = {}

local AIM_DISTANCE = 0.25 -- studs between the camera and the aim point when aiming
local SLEEVE = Color3.fromRGB(58, 66, 52)
local GLOVE = Color3.fromRGB(28, 28, 30)

local function makePart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	parent: Instance,
	root: BasePart
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
	part.Parent = parent
	return part
end

-- Hand at the grip, sleeve running back toward a shoulder behind the camera.
local function buildArm(model: Model, root: BasePart, grip: Vector3, shoulder: Vector3)
	local direction = (shoulder - grip).Unit
	makePart("Hand", Vector3.new(0.34, 0.34, 0.5), CFrame.lookAt(grip + direction * 0.1, shoulder), GLOVE, model, root)
	local sleeveStart = grip + direction * 0.35
	local length = (shoulder - sleeveStart).Magnitude
	makePart(
		"Sleeve",
		Vector3.new(0.46, 0.46, length),
		CFrame.lookAt((sleeveStart + shoulder) / 2, shoulder),
		SLEEVE,
		model,
		root
	)
end

function Viewmodel.Build(def: WeaponDef): Viewmodel
	local model = WeaponModel.Build(def)
	model.Name = "Viewmodel"
	local root = model.PrimaryPart :: BasePart
	root.Anchored = true
	local style = WeaponModel.GetStyle(def.Model.Style)

	buildArm(model, root, style.GripR, style.GripR + Vector3.new(0.4, -0.7, 1.8))
	buildArm(model, root, style.GripL, style.GripL + Vector3.new(-0.6, -0.75, 1.5))

	local muzzle = root:FindFirstChild("Muzzle") :: Attachment
	local flash = makePart(
		"Flash",
		Vector3.new(0.3, 0.3, 0.45),
		CFrame.new(style.Muzzle + Vector3.new(0, 0, -0.2)),
		Color3.fromRGB(255, 205, 100),
		model,
		root
	)
	flash.Material = Enum.Material.Neon
	flash.Transparency = 1
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 190, 100)
	light.Range = 12
	light.Brightness = 4
	light.Enabled = false
	light.Parent = flash

	local parts: { BasePart } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CastShadow = false
			table.insert(parts, descendant)
		end
	end

	return {
		Def = def,
		Model = model,
		Root = root,
		Muzzle = muzzle,
		Hip = style.Hip,
		Ads = CFrame.new(0, 0, -AIM_DISTANCE) * CFrame.new(-style.Aim),
		Parts = parts,
		Flash = flash,
		FlashLight = light,
	}
end

function Viewmodel.SetVisible(viewmodel: Viewmodel, visible: boolean)
	local modifier = if visible then 0 else 1
	for _, part in viewmodel.Parts do
		part.LocalTransparencyModifier = modifier
	end
end

function Viewmodel.MuzzleFlash(viewmodel: Viewmodel)
	local flash = viewmodel.Flash
	flash.Transparency = 0.1
	flash.Size = Vector3.new(0.3, 0.3, 0.45) * (0.8 + math.random() * 0.5)
	viewmodel.FlashLight.Enabled = true
	task.delay(0.04, function()
		flash.Transparency = 1
		viewmodel.FlashLight.Enabled = false
	end)
end

return Viewmodel
