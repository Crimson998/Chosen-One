--!strict
-- Per-player token bucket for throttling remote traffic.

local Players = game:GetService("Players")

export type RateLimiter = {
	Allow: (self: RateLimiter, player: Player) -> boolean,
}

type Bucket = {
	Tokens: number,
	Last: number,
}

local RateLimiter = {}

function RateLimiter.new(perSecond: number, burst: number): RateLimiter
	local buckets: { [Player]: Bucket } = {}

	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)

	local self = {} :: RateLimiter

	function self.Allow(_: RateLimiter, player: Player): boolean
		local now = os.clock()
		local bucket = buckets[player]
		if not bucket then
			bucket = { Tokens = burst, Last = now }
			buckets[player] = bucket
		end
		bucket.Tokens = math.min(burst, bucket.Tokens + (now - bucket.Last) * perSecond)
		bucket.Last = now
		if bucket.Tokens >= 1 then
			bucket.Tokens -= 1
			return true
		end
		return false
	end

	return self
end

return RateLimiter
