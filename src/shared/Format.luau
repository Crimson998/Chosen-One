--!strict
-- String formatting helpers for UI.

local Format = {}

-- 1234567 -> "1,234,567"
function Format.Commas(value: number): string
	local negative = value < 0
	local digits = tostring(math.floor(math.abs(value)))
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if grouped:sub(1, 1) == "," then
		grouped = grouped:sub(2)
	end
	return if negative then "-" .. grouped else grouped
end

-- 3725 -> "1h 2m"
function Format.Duration(seconds: number): string
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if hours > 0 then
		return `{hours}h {minutes}m`
	end
	return `{minutes}m`
end

return Format
