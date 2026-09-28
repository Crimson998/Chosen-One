--!strict
-- Builds a classic R6 rig out of plain parts for an enemy definition, holding
-- a procedurally built gun. Templates are built once per enemy type and cloned.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enemies = require(ReplicatedStorage.Shared.Config.Enemies)
local WeaponModel = require(ReplicatedStorage.Shared.WeaponModel)

type EnemyDef = Enemies.EnemyDef

export type Rig = {
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Head: BasePart,
	Muzzle: Attachment?,
	HealthFill: Frame,
}

local EnemyRig = {}

local templates: { [string]: Model } = {}

-- Standard R6 joint frames (rotation part), shared by every R6 character.
local ROOT_ROT = CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0)
local RIGHT_ROT = CFrame.new(0, 0, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0)
local LEFT_ROT = CFrame.new(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0)

local function makePart(name: string, size: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.Parent = parent
	return part
end

-- Creates a joint and snaps Part1 into place so the rig is posed correctly
-- before it is ever simulated.
local function join(
	className: "Motor6D" | "Weld",
	name: string,
	part0: BasePart,
	part1: BasePart,
	c0: CFrame,
	c1: CFrame
)
	local joint = Instance.new(className) :: JointInstance
	joint.Name = name
	joint.Part0 = part0
	joint.Part1 = part1
	joint.C0 = c0
	joint.C1 = c1
	joint.Parent = part0
	part1.CFrame = part0.CFrame * c0 * c1:Inverse()
end

local function buildHealthBar(def: EnemyDef, head: BasePart): Frame
	local scale = def.Scale
	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Size = UDim2.new(if def.Boss then 8 else 4, 0, if def.Boss then 1.4 else 0.9, 0)
	gui.StudsOffset = Vector3.new(0, 1.6 * scale + 0.4, 0)
	gui.MaxDistance = if def.Boss then 400 else 140
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false

	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.Size = UDim2.fromScale(1, 0.55)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = if def.Boss then Color3.fromRGB(255, 90, 90) else Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.Text = `Lv {def.Level}  {def.DisplayName}`
	label.Parent = gui

	local back = Instance.new("Frame")
	back.Name = "Back"
	back.AnchorPoint = Vector2.new(0.5, 0)
	back.Position = UDim2.fromScale(0.5, 0.62)
	back.Size = UDim2.fromScale(0.9, 0.3)
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	back.BackgroundTransparency = 0.25
	back.BorderSizePixel = 0
	back.Parent = gui

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = if def.Passive then Color3.fromRGB(230, 200, 80) else Color3.fromRGB(220, 50, 50)
	fill.BorderSizePixel = 0
	fill.Parent = back

	gui.Parent = head
	return fill
end

local function buildTemplate(def: EnemyDef): Model
	local s = def.Scale
	local colors = def.Colors

	local model = Instance.new("Model")
	model.Name = def.Id

	local root = makePart("HumanoidRootPart", Vector3.new(2, 2, 1) * s, colors.Torso, model)
	root.Transparency = 1
	root.CFrame = CFrame.new(0, 3 * s, 0)

	local torso = makePart("Torso", Vector3.new(2, 2, 1) * s, colors.Torso, model)
	torso.CanCollide = true
	local head = makePart("Head", Vector3.new(2, 1, 1) * s, colors.Skin, model)
	head.CanCollide = true
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = Vector3.new(1.25, 1.25, 1.25)
	mesh.Parent = head

	local rightArm = makePart("Right Arm", Vector3.new(1, 2, 1) * s, colors.Torso, model)
	local leftArm = makePart("Left Arm", Vector3.new(1, 2, 1) * s, colors.Torso, model)
	local rightLeg = makePart("Right Leg", Vector3.new(1, 2, 1) * s, colors.Legs, model)
	local leftLeg = makePart("Left Leg", Vector3.new(1, 2, 1) * s, colors.Legs, model)

	join("Motor6D", "RootJoint", root, torso, ROOT_ROT, ROOT_ROT)
	join("Motor6D", "Neck", torso, head, CFrame.new(0, 1 * s, 0) * ROOT_ROT, CFrame.new(0, -0.5 * s, 0) * ROOT_ROT)
	join(
		"Motor6D",
		"Right Hip",
		torso,
		rightLeg,
		CFrame.new(1 * s, -1 * s, 0) * RIGHT_ROT,
		CFrame.new(0.5 * s, 1 * s, 0) * RIGHT_ROT
	)
	join(
		"Motor6D",
		"Left Hip",
		torso,
		leftLeg,
		CFrame.new(-1 * s, -1 * s, 0) * LEFT_ROT,
		CFrame.new(-0.5 * s, 1 * s, 0) * LEFT_ROT
	)

	-- Arms are fixed welds (not Motor6Ds) raised to hold the gun, so walk
	-- animations swing the legs without waving the weapon around.
	join(
		"Weld",
		"Right Shoulder",
		torso,
		rightArm,
		CFrame.new(1 * s, 0.5 * s, 0) * RIGHT_ROT * CFrame.Angles(0, 0, math.rad(90)),
		CFrame.new(-0.5 * s, 0.5 * s, 0) * RIGHT_ROT
	)
	join(
		"Weld",
		"Left Shoulder",
		torso,
		leftArm,
		CFrame.new(-1 * s, 0.5 * s, 0) * LEFT_ROT * CFrame.Angles(0, 0, math.rad(-80)),
		CFrame.new(0.5 * s, 0.5 * s, 0) * LEFT_ROT
	)

	-- Glowing visor so enemy types read at a glance.
	local visor = makePart("Visor", Vector3.new(1.7, 0.32, 0.25) * s, colors.Visor, model)
	visor.Material = Enum.Material.Neon
	visor.CanQuery = false
	visor.Massless = true
	join("Weld", "VisorWeld", head, visor, CFrame.new(0, 0.12 * s, -0.56 * s), CFrame.identity)

	if def.Weapon then
		local gun = WeaponModel.BuildStyle(def.Weapon, Color3.fromRGB(34, 34, 38), colors.Torso, "Gun")
		if s ~= 1 then
			gun:ScaleTo(s)
		end
		local handle = gun.PrimaryPart :: BasePart
		local grip = handle:FindFirstChild("GripR") :: Attachment
		local c0 = CFrame.new(0, -0.9 * s, 0) * CFrame.Angles(math.rad(-90), 0, 0)
		local c1 = CFrame.new(grip.Position)
		-- Move the whole gun (not just its handle) before welding; nothing is
		-- simulated yet, so welded parts would not follow the handle on their own.
		gun:PivotTo(rightArm.CFrame * c0 * c1:Inverse())
		gun.Parent = model
		join("Weld", "GunWeld", rightArm, handle, c0, c1)
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.MaxHealth = def.Health
	humanoid.Health = def.Health
	humanoid.WalkSpeed = def.WalkSpeed
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.BreakJointsOnDeath = true
	humanoid.Parent = model
	Instance.new("Animator").Parent = humanoid

	buildHealthBar(def, head)

	model.PrimaryPart = root
	model:SetAttribute("EnemyId", def.Id)
	model:SetAttribute("Level", def.Level)
	if def.Boss then
		model:SetAttribute("Boss", true)
	end
	return model
end

function EnemyRig.Create(def: EnemyDef): Rig
	local template = templates[def.Id]
	if not template then
		template = buildTemplate(def)
		templates[def.Id] = template
	end

	local model = template:Clone()
	local head = model:FindFirstChild("Head") :: BasePart
	local gun = model:FindFirstChild("Gun")
	local muzzle: Attachment? = nil
	if gun then
		local handle = (gun :: Model).PrimaryPart
		muzzle = if handle then handle:FindFirstChild("Muzzle") :: Attachment? else nil
	end
	local healthBar = head:FindFirstChild("HealthBar") :: BillboardGui
	local back = healthBar:FindFirstChild("Back") :: Frame

	return {
		Model = model,
		Humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid,
		Root = model:FindFirstChild("HumanoidRootPart") :: BasePart,
		Head = head,
		Muzzle = muzzle,
		HealthFill = back:FindFirstChild("Fill") :: Frame,
	}
end

return EnemyRig
