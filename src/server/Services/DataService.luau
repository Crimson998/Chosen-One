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

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local Inventory = require(ReplicatedStorage.Shared.Inventory)
local Items = require(ReplicatedStorage.Shared.Config.Items)
local Progression = require(ReplicatedStorage.Shared.Config.Progression)
local Settings = require(ReplicatedStorage.Shared.Config.Settings)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

type Profile = Types.Profile
type ItemInstance = Types.ItemInstance

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

-- Builds an inventory, handing out sequential Uids ("i1", "i2", ...).
local function inventoryBuilder(startId: number)
	local builder = { Items = {} :: { ItemInstance }, NextId = startId }
	function builder.Add(id: string, count: number): string
		local uid = `i{builder.NextId}`
		builder.NextId += 1
		table.insert(builder.Items, { Uid = uid, Id = id, Count = count, Rarity = "Common" })
		return uid
	end
	return builder
end

function DataService.NewProfile(): Profile
	local builder = inventoryBuilder(1)
	local primary = builder.Add(Weapons.DefaultLoadout.Primary, 1)
	local secondary = builder.Add(Weapons.DefaultLoadout.Secondary, 1)
	local field = builder.Add("FieldMk1", 1)
	builder.Add("MedKit", 3)
	return {
		Version = 2,
		Level = 1,
		XP = 0,
		Credits = Progression.StartingCredits,
		Attributes = Attributes.Default(),
		AttributePoints = 0,
		Inventory = builder.Items,
		NextItemId = builder.NextId,
		Loadout = {
			Primary = primary,
			Secondary = secondary,
			Gadget = field,
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
		Settings = Settings.Default(),
	}
end

-- Version 1 profiles owned weapons by id. Give them one Common copy of each
-- owned weapon, keep the same loadout, and add the new starter gear.
local function migrateFromOwnedWeapons(raw: { [string]: any })
	local owned = if typeof(raw.OwnedWeapons) == "table" then raw.OwnedWeapons else {}
	local oldLoadout = if typeof(raw.Loadout) == "table" then raw.Loadout else {}
	local ids: { string } = {}
	for id, isOwned in owned do
		if isOwned == true and Weapons.Get(id) then
			table.insert(ids, id)
		end
	end
	table.sort(ids)

	local builder = inventoryBuilder(1)
	local uidByWeapon: { [string]: string } = {}
	for _, id in ids do
		uidByWeapon[id] = builder.Add(id, 1)
	end
	local loadout = {
		Primary = uidByWeapon[oldLoadout.Primary],
		Secondary = uidByWeapon[oldLoadout.Secondary],
		Gadget = builder.Add("FieldMk1", 1),
	}
	builder.Add("MedKit", 3)

	raw.Inventory = builder.Items
	raw.NextItemId = builder.NextId
	raw.Loadout = loadout
	raw.OwnedWeapons = nil
	raw.Version = 2
end

-- Drops unknown items and duplicate Uids, clamps stacks and rarities.
local function sanitizeInventory(profile: Profile)
	local clean: { ItemInstance } = {}
	local seen: { [string]: boolean } = {}
	local highest = 0
	for _, item in profile.Inventory do
		local def = if typeof(item) == "table" then Items.Get(item.Id) else nil
		if not def or typeof(item.Uid) ~= "string" or seen[item.Uid] then
			continue
		end
		seen[item.Uid] = true
		local count = tonumber(item.Count) or 1
		item.Count = math.clamp(math.floor(count), 1, def.MaxStack)
		item.Rarity = if def.MaxStack == 1 and Items.IsRarity(item.Rarity) then item.Rarity else "Common"
		table.insert(clean, item)
		local number = tonumber(string.match(item.Uid, "^i(%d+)$"))
		if number then
			highest = math.max(highest, number)
		end
	end
	profile.Inventory = clean
	profile.NextItemId = math.max(math.floor(tonumber(profile.NextItemId) or 1), highest + 1)
end

-- Every profile must have a weapon equipped in both slots; armor and gadget
-- slots must point at an item of the right kind (or be empty).
local function repairLoadout(profile: Profile)
	local loadout = profile.Loadout :: any
	local defaults: { [string]: string } =
		{ Primary = Weapons.DefaultLoadout.Primary, Secondary = Weapons.DefaultLoadout.Secondary }
	for slot, defaultId in defaults do
		local item = Inventory.Find(profile, loadout[slot])
		local weapon = if item then Weapons.Get(item.Id) else nil
		if weapon and weapon.Slot == slot then
			continue
		end
		loadout[slot] = nil
		for _, candidate in profile.Inventory do
			local candidateWeapon = Weapons.Get(candidate.Id)
			if candidateWeapon and candidateWeapon.Slot == slot then
				loadout[slot] = candidate.Uid
				break
			end
		end
		if not loadout[slot] then
			local uid = `i{profile.NextItemId}`
			profile.NextItemId += 1
			table.insert(profile.Inventory, { Uid = uid, Id = defaultId, Count = 1, Rarity = "Common" })
			loadout[slot] = uid
		end
	end
	for _, slot in { "Armor", "Gadget" } do
		local item = Inventory.Find(profile, loadout[slot])
		local def = if item then Items.Get(item.Id) else nil
		if not def or def.Category ~= slot then
			loadout[slot] = nil
		end
	end
end

-- Fills keys that are missing from an older saved profile and repairs
-- anything that no longer matches the current config.
local function reconcile(saved: any): Profile
	local template = DataService.NewProfile()
	if typeof(saved) ~= "table" then
		return template
	end
	if saved.Inventory == nil then
		migrateFromOwnedWeapons(saved)
	elseif typeof(saved.Inventory) ~= "table" then
		saved.Inventory = {}
	end
	if typeof(saved.Loadout) ~= "table" then
		saved.Loadout = {}
	end

	-- Inventory and Loadout are validated below rather than merged with the
	-- template, which would splice starter items into existing inventories.
	local function fill(target: { [any]: any }, defaults: { [any]: any })
		for key, value in defaults do
			if target[key] == nil then
				target[key] = deepCopy(value)
			elseif
				typeof(value) == "table"
				and typeof(target[key]) == "table"
				and next(value) ~= nil
				and key ~= "Inventory"
				and key ~= "Loadout"
			then
				fill(target[key], value)
			end
		end
	end
	fill(saved, template :: any)

	local profile = saved :: Profile
	profile.Level = math.clamp(math.floor(profile.Level), 1, Progression.MaxLevel)
	sanitizeInventory(profile)
	repairLoadout(profile)
	profile.Settings = Settings.Sanitize(profile.Settings)

	-- Stat points: clamp each stat, then make spent + unspent add up to what
	-- this level has earned (covers older profiles and tuning changes).
	local spent = 0
	for _, info in Attributes.List do
		local raw = Attributes.Get(profile.Attributes, info.Id)
		local value = if typeof(raw) == "number" and raw == raw
			then math.clamp(math.floor(raw), Attributes.Base, Attributes.Max)
			else Attributes.Base
		Attributes.Set(profile.Attributes, info.Id, value)
		spent += value - Attributes.Base
	end
	local earned = Attributes.TotalPoints(profile.Level)
	if spent > earned then
		profile.Attributes = Attributes.Default()
		profile.AttributePoints = earned
	else
		profile.AttributePoints = earned - spent
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
