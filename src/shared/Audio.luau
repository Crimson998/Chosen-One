--!strict
-- Fire-and-forget sound playback keyed by Config.Sounds names.

local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local Sounds = require(script.Parent.Config.Sounds)

local Audio = {}

local function make(name: string, volume: number?): Sound?
	local id = Sounds[name]
	if id == nil or id == "" then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = id
	sound.Volume = volume or 0.6
	return sound
end

-- Non-positional (UI / first-person) sound.
function Audio.Play(name: string, volume: number?)
	local sound = make(name, volume)
	if not sound then
		return
	end
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 8)
end

-- 3D sound at a world position.
function Audio.PlayAt(name: string, position: Vector3, volume: number?)
	local sound = make(name, volume)
	if not sound then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain
	sound.RollOffMaxDistance = 600
	sound.Parent = attachment
	sound:Play()
	Debris:AddItem(attachment, 8)
end

return Audio
