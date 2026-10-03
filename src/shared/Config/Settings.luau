--!strict
-- Player settings, saved with the profile. Each option is a slider in the
-- SETTINGS window (M).

export type Settings = {
	Sensitivity: number, -- mouse look; stacks with Roblox's own camera sensitivity
	AimSensitivity: number, -- extra multiplier while aiming down sights
}

export type Option = {
	Id: string,
	Name: string,
	Description: string,
	Min: number,
	Max: number,
	Step: number,
	Default: number,
}

local Settings = {}

Settings.Options = {
	{
		Id = "Sensitivity",
		Name = "Mouse sensitivity",
		Description = "How fast the camera turns. Stacks with the sensitivity in Roblox's Esc menu.",
		Min = 0.1,
		Max = 3,
		Step = 0.05,
		Default = 1,
	},
	{
		Id = "AimSensitivity",
		Name = "Aim sensitivity",
		Description = "Extra multiplier while aiming down sights or looking through a scope.",
		Min = 0.2,
		Max = 2,
		Step = 0.05,
		Default = 1,
	},
} :: { Option }

function Settings.Default(): Settings
	local values: { [string]: number } = {}
	for _, option in Settings.Options do
		values[option.Id] = option.Default
	end
	return values :: any
end

-- Snaps a value onto the option's range and step.
function Settings.Clamp(option: Option, value: any): number
	if typeof(value) ~= "number" or value ~= value then
		return option.Default
	end
	local stepped = option.Min + math.floor((value - option.Min) / option.Step + 0.5) * option.Step
	return math.clamp(math.floor(stepped * 100 + 0.5) / 100, option.Min, option.Max)
end

-- A clean copy of saved or received settings: known keys only, all in range.
function Settings.Sanitize(raw: any): Settings
	local source = if typeof(raw) == "table" then raw else {}
	local values: { [string]: number } = {}
	for _, option in Settings.Options do
		values[option.Id] = Settings.Clamp(option, source[option.Id])
	end
	return values :: any
end

return Settings
