--!strict
-- Damped spring on Vector3, used for recoil, sway and viewmodel kick.

export type Spring = {
	Position: Vector3,
	Velocity: Vector3,
	Target: Vector3,
	Stiffness: number,
	Damping: number,
	Impulse: (self: Spring, velocity: Vector3) -> (),
	Update: (self: Spring, dt: number) -> Vector3,
	Reset: (self: Spring) -> (),
}

local Spring = {}

function Spring.new(stiffness: number, damping: number): Spring
	local self = {
		Position = Vector3.zero,
		Velocity = Vector3.zero,
		Target = Vector3.zero,
		Stiffness = stiffness,
		Damping = damping,
	} :: Spring

	function self.Impulse(spring: Spring, velocity: Vector3)
		spring.Velocity += velocity
	end

	function self.Update(spring: Spring, dt: number): Vector3
		-- Fixed sub-steps keep stiff springs stable at low frame rates.
		local steps = math.clamp(math.ceil(dt * 240), 1, 16)
		local h = dt / steps
		for _ = 1, steps do
			local acceleration = (spring.Target - spring.Position) * spring.Stiffness - spring.Velocity * spring.Damping
			spring.Velocity += acceleration * h
			spring.Position += spring.Velocity * h
		end
		return spring.Position
	end

	function self.Reset(spring: Spring)
		spring.Position = Vector3.zero
		spring.Velocity = Vector3.zero
		spring.Target = Vector3.zero
	end

	return self
end

return Spring
