--!strict
-- Client entry point.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

if not game:IsLoaded() then
	game.Loaded:Wait()
end
ReplicatedStorage:WaitForChild("Shared")

local Net = require(ReplicatedStorage.Shared.Net)
local State = require(script.Parent.State)
local Types = require(ReplicatedStorage.Shared.Types)
local Version = require(ReplicatedStorage.Shared.Version)

local Controllers = script.Parent.Controllers

type Controller = {
	Init: () -> (),
	Start: () -> (),
}

local controllers: { Controller } = {
	require(Controllers.HUDController) :: any,
	require(Controllers.WeaponController) :: any,
	require(Controllers.MovementController) :: any,
	require(Controllers.ShopController) :: any,
	require(Controllers.StatusController) :: any,
	require(Controllers.InventoryController) :: any,
	require(Controllers.ScoreboardController) :: any,
	require(Controllers.HeartRateController) :: any,
	require(Controllers.BulletLineController) :: any,
}

-- Hide the core UI this game replaces. SetCoreGuiEnabled can fail while the
-- core scripts are still loading, so retry for a few seconds.
task.spawn(function()
	for _ = 1, 20 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
		end)
		if ok then
			break
		end
		task.wait(0.5)
	end
end)

local function setProfile(profile: Types.Profile?)
	if typeof(profile) ~= "table" then
		return
	end
	State.Profile = profile
	State.ProfileChanged:Fire(profile)
end

for _, controller in controllers do
	controller.Init()
end

Net.Event("ProfileUpdate").OnClientEvent:Connect(setProfile)
task.spawn(function()
	local ok, profile = pcall(function()
		return Net.Function("GetProfile"):InvokeServer()
	end)
	if ok and State.Profile == nil then
		setProfile(profile)
	end
end)

for _, controller in controllers do
	task.spawn(controller.Start)
end

print(`[Chosen One] Client ready (v{Version})`)
