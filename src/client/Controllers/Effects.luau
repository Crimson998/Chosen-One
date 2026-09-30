--!strict
-- Local-only visual effects: tracers, impacts, bullet holes, muzzle flashes
-- and floating damage numbers. Nothing here replicates.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage.Shared.Audio)
local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

type ShotReplication = Types.ShotReplication

local Effects = {}

local MAX_HOLES = 80
local TRACER_SPEED = 1400 -- studs per second
local PLAYER_TRACER = Color3.fromRGB(255, 225, 160)
local ENEMY_TRACER = Color3.fromRGB(255, 110, 80)
local OPTICAL_TRACER = Color3.fromRGB(90, 230, 255)

local folder = Instance.new("Folder")
folder.Name = "ClientEffects"
folder.Parent = workspace

local holes: { BasePart } = {}

local function effectPart(size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

function Effects.Folder(): Folder
	return folder
end

-- Tracer colour for a weapon: optical guns fire cyan laser bolts.
function Effects.TracerColor(weaponId: string?): Color3
	local def = Weapons.Get(weaponId)
	return if def and def.Ammo == "Optical" then OPTICAL_TRACER else PLAYER_TRACER
end

-- A short streak that travels from `from` to `to`.
function Effects.Tracer(from: Vector3, to: Vector3, color: Color3?)
	local length = (to - from).Magnitude
	if length < 2 then
		return
	end
	local streak = math.min(10, length * 0.5)
	local direction = (to - from).Unit
	local startCFrame = CFrame.lookAt(from + direction * streak / 2, to)
	local endCFrame = CFrame.lookAt(to - direction * streak / 2, to + direction)
	local part = effectPart(Vector3.new(0.07, 0.07, streak), startCFrame, color or PLAYER_TRACER, Enum.Material.Neon)
	part.Transparency = 0.15
	part.Parent = folder
	local duration = math.max(0.03, (length - streak) / TRACER_SPEED)
	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Linear), { CFrame = endCFrame }):Play()
	Debris:AddItem(part, duration + 0.02)
end

local function burst(position: Vector3, normal: Vector3, color: Color3, count: number, speed: NumberRange, size: number)
	local attachment = Instance.new("Attachment")
	-- Particles emit along the attachment's +Y; point it along the surface normal.
	attachment.WorldCFrame = CFrame.lookAt(position, position + normal) * CFrame.Angles(-math.pi / 2, 0, 0)
	attachment.Parent = workspace.Terrain

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.6
	emitter.Size = NumberSequence.new(size, 0)
	emitter.Transparency = NumberSequence.new(0, 1)
	emitter.Lifetime = NumberRange.new(0.12, 0.3)
	emitter.Speed = speed
	emitter.SpreadAngle = Vector2.new(55, 55)
	emitter.Drag = 6
	emitter.Rate = 0
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Parent = attachment
	emitter:Emit(count)
	Debris:AddItem(attachment, 0.6)
end

function Effects.Impact(position: Vector3, normal: Vector3, hitCharacter: boolean)
	if hitCharacter then
		burst(position, normal, Color3.fromRGB(200, 20, 20), 10, NumberRange.new(6, 14), 0.25)
		return
	end
	burst(position, normal, Color3.fromRGB(255, 200, 120), 8, NumberRange.new(10, 22), 0.12)

	local hole = effectPart(
		Vector3.new(0.22, 0.22, 0.04),
		CFrame.lookAt(position + normal * 0.01, position + normal),
		Color3.fromRGB(20, 20, 20),
		Enum.Material.SmoothPlastic
	)
	hole.Parent = folder
	table.insert(holes, hole)
	if #holes > MAX_HOLES then
		local oldest = table.remove(holes, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(12, function()
		local index = table.find(holes, hole)
		if index then
			table.remove(holes, index)
			hole:Destroy()
		end
	end)
end

function Effects.Flash(position: Vector3, color: Color3?)
	local part = effectPart(
		Vector3.new(0.5, 0.5, 0.5),
		CFrame.new(position),
		color or Color3.fromRGB(255, 200, 90),
		Enum.Material.Neon
	)
	part.Shape = Enum.PartType.Ball
	part.Transparency = 0.2
	local light = Instance.new("PointLight")
	light.Color = part.Color
	light.Range = 10
	light.Brightness = 3
	light.Parent = part
	part.Parent = folder
	Debris:AddItem(part, 0.05)
end

function Effects.DamageNumber(position: Vector3, amount: number, headshot: boolean, killed: boolean, critical: boolean?)
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(90, 34)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.StudsOffsetWorldSpace = Vector3.new(0, 1, 0)
	gui.Parent = attachment

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = if critical then `{amount}!` else tostring(amount)
	label.TextColor3 = if killed
		then Color3.fromRGB(255, 70, 70)
		elseif critical then Color3.fromRGB(255, 140, 40)
		elseif headshot then Color3.fromRGB(255, 200, 40)
		else Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.3
	label.Parent = gui

	local drift = Vector3.new(math.random() - 0.5, 3, math.random() - 0.5)
	TweenService:Create(gui, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = drift,
	}):Play()
	TweenService:Create(label, TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, 0.35), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	Debris:AddItem(attachment, 0.9)
end

local function findMuzzle(shooter: Instance?): Vector3?
	if not shooter then
		return nil
	end
	local model: Instance? = nil
	if shooter:IsA("Player") then
		local character = (shooter :: Player).Character
		model = character and character:FindFirstChild("WorldWeapon")
	else
		model = shooter:FindFirstChild("Gun")
	end
	local handle = model and model:FindFirstChild("Handle")
	local muzzle = handle and handle:FindFirstChild("Muzzle")
	if muzzle and muzzle:IsA("Attachment") then
		return muzzle.WorldPosition
	end
	return nil
end

-- Renders a shot fired by another player or an enemy.
function Effects.RemoteShot(payload: ShotReplication)
	if typeof(payload) ~= "table" or typeof(payload.Origin) ~= "Vector3" or typeof(payload.Ends) ~= "table" then
		return
	end
	if payload.Shooter == Players.LocalPlayer then
		return
	end
	local isEnemy = payload.Weapon == "Enemy"
	local def = Weapons.Get(payload.Weapon)
	local from = findMuzzle(payload.Shooter) or payload.Origin
	Audio.PlayAt(if def then "Fire_" .. def.Sound else "Fire_Enemy", from, 0.7)
	if def and def.Melee then
		return -- blade swings have no tracer or flash
	end
	local color = if isEnemy then ENEMY_TRACER else Effects.TracerColor(payload.Weapon)
	for _, endPosition in payload.Ends do
		if typeof(endPosition) == "Vector3" then
			Effects.Tracer(from, endPosition, color)
		end
	end
	Effects.Flash(from, if def and def.Ammo == "Optical" then OPTICAL_TRACER else nil)
end

return Effects
