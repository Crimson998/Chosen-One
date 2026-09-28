--!strict
-- Leveling curve and reward tuning.

local Progression = {}

Progression.MaxLevel = 60
Progression.StartingCredits = 500
Progression.PlayerMaxHealth = 100
Progression.RespawnTime = 4
Progression.RegenDelay = 5 -- seconds without damage before health regenerates
Progression.RegenPerSecond = 12
Progression.SpawnProtection = 3 -- seconds of ForceField after spawning

-- XP needed to go from `level` to `level + 1`.
function Progression.XPForLevel(level: number): number
	return math.floor(120 * level ^ 1.4)
end

-- Reconstructs a level from lifetime XP (used by the global leaderboard).
function Progression.LevelFromTotalXP(totalXP: number): number
	local level = 1
	local remaining = totalXP
	while level < Progression.MaxLevel do
		local needed = Progression.XPForLevel(level)
		if remaining < needed then
			break
		end
		remaining -= needed
		level += 1
	end
	return level
end

-- Enemies far below your level give reduced XP so players push into harder zones.
function Progression.EnemyXP(baseXP: number, enemyLevel: number, playerLevel: number): number
	local gap = playerLevel - enemyLevel - 5
	if gap <= 0 then
		return baseXP
	end
	return math.max(1, math.floor(baseXP * math.max(0.2, 1 - gap * 0.1)))
end

function Progression.PvPKillXP(victimLevel: number): number
	return 100 + victimLevel * 10
end

function Progression.PvPKillCredits(victimLevel: number): number
	return 50 + victimLevel * 5
end

function Progression.LevelUpCredits(newLevel: number): number
	return 100 + newLevel * 25
end

-- Share of an enemy's max health a player must deal to be credited with the kill.
Progression.AssistThreshold = 0.1

return Progression
