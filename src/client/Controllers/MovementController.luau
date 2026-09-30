--!strict
-- Sprinting, move speed (AGI, weapon handling, carry weight, guarding) and
-- the arms-forward hold pose (so other players see us carrying the gun).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local State = require(script.Parent.Parent.State)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

local MovementController = {}

local BASE_SPEED = 16
local SPRINT_MULTIPLIER = 1.45
local AIM_MULTIPLIER = 0.65
local GUARD_MULTIPLIER = 0.6
local OVERWEIGHT_MULTIPLIER = 0.7

-- Roblox's default "tool held" arm poses.
local HOLD_ANIMATIONS = {
	[Enum.HumanoidRigType.R6] = "rbxassetid://182393478",
	[Enum.HumanoidRigType.R15] = "rbxassetid://507768375",
}

local player = Players.LocalPlayer
local humanoid: Humanoid? = nil
local sprintHeld = false

local function playHoldPose(target: Humanoid)
	local animator = target:WaitForChild("Animator", 10)
	if not animator or not animator:IsA("Animator") then
		return
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = HOLD_ANIMATIONS[target.RigType]
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if ok and track then
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = true
		track:Play()
	end
end

local function onCharacterAdded(character: Model)
	local newHumanoid = character:WaitForChild("Humanoid", 10)
	if newHumanoid and newHumanoid:IsA("Humanoid") then
		humanoid = newHumanoid
		task.spawn(playHoldPose, newHumanoid)
	end
end

local function update()
	local target = humanoid
	if not target or target.Health <= 0 then
		State.Sprinting = false
		return
	end

	local camera = workspace.CurrentCamera
	local look = camera.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	local moveDirection = target.MoveDirection
	local movingForward = moveDirection.Magnitude > 0.1
		and flatLook.Magnitude > 0.01
		and moveDirection.Unit:Dot(flatLook.Unit) > 0.5

	local profile = State.Profile
	local attributes = if profile then profile.Attributes else Attributes.Default()
	local carried = if profile then Weapons.LoadoutWeight(profile.Loadout.Primary, profile.Loadout.Secondary) else 0
	local overweight = carried > Attributes.CarryCapacity(attributes.STR)

	State.Sprinting = sprintHeld
		and movingForward
		and not overweight
		and not State.Firing
		and not State.AimHeld
		and not State.UIOpen

	local def = Weapons.Get(State.WeaponId)
	local speed = BASE_SPEED * Attributes.SpeedMultiplier(attributes.AGI) * (if def then def.MoveSpeedMultiplier else 1)
	if State.Sprinting then
		speed *= SPRINT_MULTIPLIER
	end
	if overweight then
		speed *= OVERWEIGHT_MULTIPLIER
	end
	if State.Guarding then
		speed *= GUARD_MULTIPLIER
	else
		speed *= 1 - State.AimAlpha * (1 - AIM_MULTIPLIER)
	end
	target.WalkSpeed = speed
end

function MovementController.Init()
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and (input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL3) then
			sprintHeld = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL3 then
			sprintHeld = false
		end
	end)
end

function MovementController.Start()
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
	RunService.RenderStepped:Connect(update)
end

return MovementController
