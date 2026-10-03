--!strict
-- Stores the player's settings (sensitivity) in their profile so they carry
-- over between sessions. The client applies changes itself straight away.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local Settings = require(ReplicatedStorage.Shared.Config.Settings)

local SettingsService = {}

-- The client saves at most once per drag, after a short pause.
local limiter = RateLimiter.new(2, 6)

function SettingsService.Init()
	Net.Event("SaveSettings").OnServerEvent:Connect(function(player: Player, raw: any)
		if not limiter:Allow(player) then
			return
		end
		local profile = DataService.GetProfile(player)
		if profile then
			profile.Settings = Settings.Sanitize(raw)
		end
	end)
end

return SettingsService
