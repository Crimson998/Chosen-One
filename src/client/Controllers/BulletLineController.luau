--!strict
-- Draws bullet prediction lines: translucent red beams showing where a shot
-- is about to travel. They thicken as the shot approaches, so you can read
-- the timing and step out of the way.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Audio = require(ReplicatedStorage.Shared.Audio)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)

type BulletLine = Types.BulletLine

type Entry = {
	Start: Attachment,
	Finish: Attachment,
	Beam: Beam,
	Created: number,
	Expires: number,
}

local BulletLineController = {}

local LINE_COLOR = Color3.fromRGB(255, 40, 40)

local entries: { [string]: Entry } = {}

local function remove(id: string)
	local entry = entries[id]
	if entry then
		entries[id] = nil
		entry.Start:Destroy()
		entry.Finish:Destroy()
	end
end

local function create(): Entry
	local start = Instance.new("Attachment")
	start.Name = "BulletLineStart"
	start.Parent = workspace.Terrain
	local finish = Instance.new("Attachment")
	finish.Name = "BulletLineEnd"
	finish.Parent = workspace.Terrain

	local beam = Instance.new("Beam")
	beam.Attachment0 = start
	beam.Attachment1 = finish
	beam.Color = ColorSequence.new(LINE_COLOR)
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Width0 = 0.08
	beam.Width1 = 0.08
	beam.Transparency = NumberSequence.new(0.35)
	beam.Parent = start

	local now = os.clock()
	return { Start = start, Finish = finish, Beam = beam, Created = now, Expires = now }
end

local function onLine(line: BulletLine)
	if typeof(line) ~= "table" or typeof(line.Id) ~= "string" then
		return
	end
	if line.Duration <= 0 then
		remove(line.Id)
		return
	end
	if typeof(line.From) ~= "Vector3" or typeof(line.To) ~= "Vector3" then
		return
	end
	local entry = entries[line.Id]
	if not entry then
		entry = create()
		entries[line.Id] = entry
		Audio.Play("BulletLine", 0.35)
	end
	entry.Start.WorldPosition = line.From
	entry.Finish.WorldPosition = line.To
	entry.Expires = os.clock() + line.Duration
end

local function update()
	local now = os.clock()
	for id, entry in entries do
		if now >= entry.Expires then
			remove(id)
			continue
		end
		-- Thicken and brighten as the moment of the shot approaches.
		local total = math.max(entry.Expires - entry.Created, 0.05)
		local progress = math.clamp((now - entry.Created) / total, 0, 1)
		local width = 0.07 + 0.13 * progress
		entry.Beam.Width0 = width
		entry.Beam.Width1 = width
		entry.Beam.Transparency = NumberSequence.new(0.5 - 0.3 * progress)
	end
end

function BulletLineController.Init()
	Net.Event("BulletLine").OnClientEvent:Connect(onLine)
end

function BulletLineController.Start()
	RunService.RenderStepped:Connect(update)
end

return BulletLineController
