--!strict
-- Persistent player profiles with session locking.
--
-- Each DataStore record is { Data = Profile, Lock = { JobId, Time }? }. A
-- server only loads a profile it can lock; the lock is refreshed on every
-- autosave and cleared on leave, so a profile is never live on two servers
-- at once (which is how item duplication happens). Locks not refreshed for
-- LOCK_STALE_SECONDS are assumed to belong to a crashed server and are taken
-- over.
--
-- In Studio without API access the service falls back to an in-memory store.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Progression = require(ReplicatedStorage.Shared.Config.Progression)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

type Profile = Types.Profile

local STORE_NAME = "ChosenOne_Profiles_v1"
local AUTOSAVE_INTERVAL = 60
local LOCK_STALE_SECONDS = 300
local LOAD_ATTEMPTS = 8
local LOAD_RETRY_DELAY = 4
local SAVE_ATTEMPTS = 3

type Lock = {
	JobId: string,
	Time: number,
}

type Record = {
	Data: Profile?,
	Lock: Lock?,
}

type Store = {
	UpdateAsync: (self: Store, key: string, transform: (any) -> any) -> any,
}

type Session = {
	Profile: Profile,
	LastSave: number,
	Released: boolean,
}

local DataService = {}

-- Fired once a player's profile is loaded: (player: Player, profile: Profile)
DataService.ProfileLoaded = Signal.new()

local store: Store
local usingMock = false
local sessions: { [Player]: Session } = {}
local loading: { [Player]: boolean } = {}
local jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local function createMockStore(): Store
	local data: { [string]: any } = {}
	local mock = {} :: Store
	function mock.UpdateAsync(_: Store, key: string, transform: (any) -> any): any
		local current = data[key]
		local result = transform(if current ~= nil then HttpService:JSONDecode(current) else nil)
		if result ~= nil then
			data[key] = HttpService:JSONEncode(result)
		end
		return result
	end
	return mock
end

local function deepCopy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value :: any do
		copy[key] = deepCopy(inner)
	end
	return copy :: any
end

function DataService.NewProfile(): Profile
	local owned: { [string]: boolean } = {
		[Weapons.DefaultLoadout.Primary] = true,
		[Weapons.DefaultLoadout.Secondary] = true,
	}
	return {
		Version = 1,
		Level = 1,
		XP = 0,
		Credits = Progression.StartingCredits,
		OwnedWeapons = owned,
		Loadout = {
			Primary = Weapons.DefaultLoadout.Primary,
			Secondary = Weapons.DefaultLoadout.Secondary,
		},
		Stats = {
			Kills = 0,
			Deaths = 0,
			EnemyKills = 0,
			BossKills = 0,
			Headshots = 0,
			ShotsFired = 0,
			ShotsHit = 0,
			TotalXP = 0,
			PlayTime = 0,
			BountiesCompleted = 0,
		},
		Bounties = {},
	}
end

-- Fills keys that are missing from an older saved profile and repairs
-- anything that no longer matches the current config.
local function reconcile(saved: any): Profile
	local template = DataService.NewProfile()
	if typeof(saved) ~= "table" then
		return template
	end

	local function fill(target: { [any]: any }, defaults: { [any]: any })
		for key, value in defaults do
			if target[key] == nil then
				target[key] = deepCopy(value)
			elseif typeof(value) == "table" and typeof(target[key]) == "table" and next(value) ~= nil then
				fill(target[key], value)
			end
		end
	end
	fill(saved, template :: any)

	local profile = saved :: Profile
	profile.Level = math.clamp(math.floor(profile.Level), 1, Progression.MaxLevel)
	profile.OwnedWeapons[Weapons.DefaultLoadout.Primary] = true
	profile.OwnedWeapons[Weapons.DefaultLoadout.Secondary] = true
	for id in profile.OwnedWeapons do
		if not Weapons.Get(id) then
			profile.OwnedWeapons[id] = nil
		end
	end

	local function validSlot(id: string, slot: string): boolean
		local def = Weapons.Get(id)
		return def ~= nil and def.Slot == slot and profile.OwnedWeapons[id] == true
	end
	if not validSlot(profile.Loadout.Primary, "Primary") then
		profile.Loadout.Primary = Weapons.DefaultLoadout.Primary
	end
	if not validSlot(profile.Loadout.Secondary, "Secondary") then
		profile.Loadout.Secondary = Weapons.DefaultLoadout.Secondary
	end
	return profile
end

local function keyFor(player: Player): string
	return `Player_{player.UserId}`
end

local function loadProfile(player: Player): Profile?
	local key = keyFor(player)
	for attempt = 1, LOAD_ATTEMPTS do
		local locked = false
		local ok, result = pcall(function()
			return store:UpdateAsync(key, function(record: Record?)
				locked = false
				local current: Record = record or {}
				local lock = current.Lock
				if lock and lock.JobId ~= jobId and os.time() - lock.Time < LOCK_STALE_SECONDS then
					locked = true
					return nil -- cancel the write; someone else owns it
				end
				current.Lock = { JobId = jobId, Time = os.time() }
				return current
			end)
		end)

		if ok and not locked then
			local record = result :: Record?
			return reconcile(record and record.Data)
		end
		if not ok then
			warn(`[DataService] Load attempt {attempt} for {player.Name} failed: {result}`)
		end
		if player.Parent == nil then
			return nil
		end
		task.wait(LOAD_RETRY_DELAY)
	end
	return nil
end

local function saveProfile(player: Player, release: boolean): boolean
	local session = sessions[player]
	if not session or session.Released then
		return false
	end

	local now = os.clock()
	session.Profile.Stats.PlayTime += math.floor(now - session.LastSave)
	session.LastSave = now
	if release then
		session.Released = true
	end

	local data = deepCopy(session.Profile)
	for attempt = 1, SAVE_ATTEMPTS do
		local stolen = false
		local ok, err = pcall(function()
			store:UpdateAsync(keyFor(player), function(record: Record?)
				stolen = false
				local current: Record = record or {}
				if current.Lock and current.Lock.JobId ~= jobId then
					stolen = true
					return nil
				end
				current.Data = data
				current.Lock = if release then nil else { JobId = jobId, Time = os.time() }
				return current
			end)
		end)
		if ok then
			if stolen then
				warn(`[DataService] Session for {player.Name} was taken over by another server; save skipped`)
				return false
			end
			return true
		end
		warn(`[DataService] Save attempt {attempt} for {player.Name} failed: {err}`)
		task.wait(2 ^ attempt)
	end
	return false
end

local function onPlayerAdded(player: Player)
	if sessions[player] or loading[player] then
		return
	end
	loading[player] = true
	local profile = loadProfile(player)
	loading[player] = nil

	if player.Parent == nil then
		-- Left while loading: release the lock we may have just taken.
		if profile then
			sessions[player] = { Profile = profile, LastSave = os.clock(), Released = false }
			saveProfile(player, true)
			sessions[player] = nil
		end
		return
	end
	if not profile then
		player:Kick("Your profile is still in use by another server. Please rejoin in a minute.")
		return
	end

	sessions[player] = { Profile = profile, LastSave = os.clock(), Released = false }
	DataService.ProfileLoaded:Fire(player, profile)
end

local function onPlayerRemoving(player: Player)
	if sessions[player] then
		saveProfile(player, true)
		sessions[player] = nil
	end
end

function DataService.GetProfile(player: Player): Profile?
	local session = sessions[player]
	return if session then session.Profile else nil
end

-- Yields until the profile is loaded (or the timeout / player leaves).
function DataService.WaitForProfile(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 30)
	while player.Parent and os.clock() < deadline do
		local profile = DataService.GetProfile(player)
		if profile then
			return profile
		end
		task.wait(0.1)
	end
	return nil
end

function DataService.IsMock(): boolean
	return usingMock
end

function DataService.Init()
	local ok, err = pcall(function()
		local realStore = DataStoreService:GetDataStore(STORE_NAME)
		realStore:GetAsync("__probe")
		store = realStore :: any
	end)
	if not ok then
		if RunService:IsStudio() then
			warn(
				`[DataService] DataStores unavailable ({err}). Using an in-memory store; progress will not persist. Enable "Studio Access to API Services" to test saving.`
			)
			usingMock = true
			store = createMockStore()
		else
			warn(`[DataService] DataStore probe failed ({err}); continuing with retries.`)
			store = DataStoreService:GetDataStore(STORE_NAME) :: any
		end
	end

	Players.PlayerRemoving:Connect(onPlayerRemoving)

	game:BindToClose(function()
		local pending = 0
		for player in sessions do
			pending += 1
			task.spawn(function()
				saveProfile(player, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for player in sessions do
				task.spawn(saveProfile, player, false)
			end
		end
	end)
end

function DataService.Start()
	-- Connected in Start so every other service has subscribed to
	-- ProfileLoaded before the first profile can finish loading.
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return DataService
