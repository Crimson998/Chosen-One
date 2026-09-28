--!strict
-- Keeps three active bounties per player, tracks progress from combat events
-- and pays out on completion.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bounties = require(ReplicatedStorage.Shared.Config.Bounties)
local DataService = require(script.Parent.DataService)
local ProgressionService = require(script.Parent.ProgressionService)
local Types = require(ReplicatedStorage.Shared.Types)

type BountyDef = Bounties.BountyDef
type BountyType = Bounties.BountyType
type Profile = Types.Profile

export type BountyEvent = {
	EnemyId: string?,
	Zone: string?,
}

local BountyService = {}

local rng = Random.new()

local function isActive(profile: Profile, id: string): boolean
	for _, bounty in profile.Bounties do
		if bounty.Id == id then
			return true
		end
	end
	return false
end

local function rollBounty(profile: Profile, exclude: string?): BountyDef?
	local candidates: { BountyDef } = {}
	for _, def in Bounties.List do
		if def.MinLevel <= profile.Level and def.Id ~= exclude and not isActive(profile, def.Id) then
			table.insert(candidates, def)
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

-- Drops bounties that no longer exist and tops the list back up.
local function fillBounties(profile: Profile)
	for index = #profile.Bounties, 1, -1 do
		if not Bounties.Get(profile.Bounties[index].Id) then
			table.remove(profile.Bounties, index)
		end
	end
	while #profile.Bounties < Bounties.ActiveCount do
		local def = rollBounty(profile)
		if not def then
			break
		end
		table.insert(profile.Bounties, { Id = def.Id, Progress = 0 })
	end
end

local function matches(def: BountyDef, eventType: BountyType, event: BountyEvent): boolean
	if def.Type ~= eventType then
		return false
	end
	if def.Target and def.Target ~= event.EnemyId then
		return false
	end
	if def.Zone and def.Zone ~= event.Zone then
		return false
	end
	return true
end

function BountyService.Record(player: Player, eventType: BountyType, event: BountyEvent)
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end

	local changed = false
	for index, bounty in profile.Bounties do
		local def = Bounties.Get(bounty.Id)
		if def and matches(def, eventType, event) then
			bounty.Progress += 1
			changed = true
			if bounty.Progress >= def.Goal then
				profile.Stats.BountiesCompleted += 1
				ProgressionService.Notify(player, {
					Kind = "Bounty",
					Text = def.Title,
					Amount = def.Credits,
				})
				ProgressionService.AwardCredits(player, def.Credits)
				ProgressionService.AwardXP(player, def.XP, def.Title)

				local nextDef = rollBounty(profile, def.Id)
				if nextDef then
					profile.Bounties[index] = { Id = nextDef.Id, Progress = 0 }
				else
					bounty.Progress = 0
				end
			end
		end
	end

	if changed then
		-- New levels can unlock bounties; refill in case the pool was exhausted.
		fillBounties(profile)
		ProgressionService.Replicate(player)
	end
end

function BountyService.Init()
	DataService.ProfileLoaded:Connect(function(player: Player, profile: Profile)
		fillBounties(profile)
		ProgressionService.Replicate(player)
	end)
end

return BountyService
