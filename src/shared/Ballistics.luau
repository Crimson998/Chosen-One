--!strict
-- Shared shot math so client prediction and server validation agree.

local Weapons = require(script.Parent.Config.Weapons)

type WeaponDef = Weapons.WeaponDef

local Ballistics = {}

-- Linear falloff between FalloffStart and FalloffEnd.
function Ballistics.DamageAt(def: WeaponDef, distance: number): number
	if distance <= def.FalloffStart then
		return def.Damage
	end
	if distance >= def.FalloffEnd then
		return def.Damage * def.MinDamageRatio
	end
	local t = (distance - def.FalloffStart) / (def.FalloffEnd - def.FalloffStart)
	return def.Damage * (1 - t * (1 - def.MinDamageRatio))
end

-- Random direction inside a cone of `angleDeg` around `forward`,
-- distributed uniformly over the cone's cross-section.
function Ballistics.ConeDirection(forward: Vector3, angleDeg: number, rng: Random): Vector3
	local unit = forward.Unit
	if angleDeg <= 0 then
		return unit
	end
	local up = if math.abs(unit.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local basis = CFrame.lookAt(Vector3.zero, unit, up)
	local theta = math.rad(angleDeg) * math.sqrt(rng:NextNumber())
	local phi = rng:NextNumber() * math.pi * 2
	return (basis * CFrame.Angles(0, 0, phi) * CFrame.Angles(theta, 0, 0)).LookVector
end

function Ballistics.IsFiniteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local v = value :: Vector3
	-- NaN fails every comparison; the bound also rejects +/- inf.
	return math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

return Ballistics
