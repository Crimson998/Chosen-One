--!strict
-- Bounties are repeatable objectives. Each player always holds three; completing
-- one pays out and rolls a fresh one.

export type BountyType = "EnemyKill" | "PlayerKill" | "Headshot"

export type BountyDef = {
	Id: string,
	Title: string,
	Description: string,
	Type: BountyType,
	Target: string?, -- enemy id for EnemyKill; nil = any
	Zone: string?, -- zone id; nil = anywhere
	Goal: number,
	XP: number,
	Credits: number,
	MinLevel: number,
}

local Bounties = {}

local defs: { BountyDef } = {
	{
		Id = "ScavSweep",
		Title = "Scavenger Sweep",
		Description = "Eliminate 15 Scavengers",
		Type = "EnemyKill",
		Target = "Scavenger",
		Goal = 15,
		XP = 350,
		Credits = 250,
		MinLevel = 1,
	},
	{
		Id = "OutskirtsPatrol",
		Title = "Outskirts Patrol",
		Description = "Eliminate 25 enemies in the Outskirts",
		Type = "EnemyKill",
		Zone = "Outskirts",
		Goal = 25,
		XP = 500,
		Credits = 300,
		MinLevel = 1,
	},
	{
		Id = "RaiderHunt",
		Title = "Raider Hunt",
		Description = "Eliminate 12 Raiders",
		Type = "EnemyKill",
		Target = "Raider",
		Goal = 12,
		XP = 600,
		Credits = 400,
		MinLevel = 4,
	},
	{
		Id = "Sharpshot",
		Title = "Sharpshot",
		Description = "Get 20 headshot kills",
		Type = "Headshot",
		Goal = 20,
		XP = 900,
		Credits = 600,
		MinLevel = 3,
	},
	{
		Id = "Marauders",
		Title = "Break the Marauders",
		Description = "Eliminate 15 Marauders",
		Type = "EnemyKill",
		Target = "Marauder",
		Goal = 15,
		XP = 1600,
		Credits = 900,
		MinLevel = 10,
	},
	{
		Id = "CounterSnipe",
		Title = "Counter-Snipe",
		Description = "Eliminate 6 Sharpshooters",
		Type = "EnemyKill",
		Target = "Sharpshooter",
		Goal = 6,
		XP = 1400,
		Credits = 800,
		MinLevel = 12,
	},
	{
		Id = "Contender",
		Title = "Contender",
		Description = "Defeat 5 players in PvP zones",
		Type = "PlayerKill",
		Goal = 5,
		XP = 2000,
		Credits = 1200,
		MinLevel = 10,
	},
	{
		Id = "Enforcers",
		Title = "Crack the Core",
		Description = "Eliminate 15 Enforcers",
		Type = "EnemyKill",
		Target = "Enforcer",
		Goal = 15,
		XP = 4000,
		Credits = 2000,
		MinLevel = 24,
	},
	{
		Id = "Juggernaut",
		Title = "Giant Slayer",
		Description = "Take down the Juggernaut",
		Type = "EnemyKill",
		Target = "Juggernaut",
		Goal = 1,
		XP = 5000,
		Credits = 3000,
		MinLevel = 25,
	},
}

Bounties.List = defs
Bounties.ById = {} :: { [string]: BountyDef }
for _, def in defs do
	Bounties.ById[def.Id] = def
end

Bounties.ActiveCount = 3

function Bounties.Get(id: any): BountyDef?
	if typeof(id) ~= "string" then
		return nil
	end
	return Bounties.ById[id]
end

return Bounties
