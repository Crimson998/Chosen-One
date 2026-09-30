--!strict
-- Simulated heart rate. Sprinting, firing, taking hits and having a bullet
-- line locked onto you all raise it; standing still calms it. WeaponController
-- scales the bullet circle by the resulting pulse, so a calm shooter who fires
-- between heartbeats is the most accurate.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Audio = require(ReplicatedStorage.Shared.Audio)
local Net = require(ReplicatedStorage.Shared.Net)
local State = require(script.Parent.Parent.State)
local Types = require(ReplicatedStorage.Shared.Types)

type BulletLine = Types.BulletLine

local HeartRateController = {}

local RESTING = 68
local MAX_BPM = 185
local RISE_RATE = 30 -- bpm per second
local FALL_RATE = 9

local player = Players.LocalPlayer
local stress = 0 -- extra bpm from scares; decays over time
local phase = 0 -- 0..1 through the current beat
local seenLines: { [string]: number } = {}

local function addStress(amount: number)
	stress = math.min(stress + amount, 80)
end

local function update(dt: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		State.HeartRate = RESTING
		State.Pulse = 0
		stress = 0
		return
	end

	local velocity = root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local target = RESTING
	if State.Sprinting then
		target += 45
	elseif speed > 2 then
		target += 12
	end
	if State.Firing then
		target += 12
	end
	if State.Scoped and speed < 1 then
		target -= 6 -- steadying your breath behind a scope
	end
	target = math.min(MAX_BPM, target + stress)
	stress = math.max(0, stress - dt * 7)

	local bpm = State.HeartRate
	if bpm < target then
		bpm = math.min(target, bpm + RISE_RATE * dt)
	else
		bpm = math.max(target, bpm - FALL_RATE * dt)
	end
	State.HeartRate = bpm

	phase += dt * bpm / 60
	if phase >= 1 then
		phase -= 1
		if bpm > 130 then
			Audio.Play("Heartbeat", math.clamp((bpm - 130) / 60, 0.1, 0.6))
		end
	end
	-- Sharp swell right after each beat, easing off until the next.
	State.Pulse = math.exp(-phase * 5)
end

function HeartRateController.Init()
	Net.Event("DamageTaken").OnClientEvent:Connect(function(_source: Vector3?, amount: number)
		if typeof(amount) == "number" and amount > 0 then
			addStress(18 + amount * 0.6)
		end
	end)
	Net.Event("BulletLine").OnClientEvent:Connect(function(line: BulletLine)
		if typeof(line) ~= "table" or not line.TargetsYou or line.Duration <= 0 then
			return
		end
		-- Only a fresh line startles you, not every refresh of the same one.
		local now = os.clock()
		local last = seenLines[line.Id]
		seenLines[line.Id] = now
		if not last or now - last > 1 then
			addStress(10)
		end
	end)
end

function HeartRateController.Start()
	RunService.RenderStepped:Connect(update)
end

return HeartRateController
