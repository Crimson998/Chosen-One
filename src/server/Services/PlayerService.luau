--!strict
-- Character lifecycle: spawns characters once profiles load, sets up health
-- and nametags, handles death/respawn and transit between Haven and zones.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local CombatService = require(script.Parent.CombatService)
local DataService = require(script.Parent.DataService)
local Enemies = require(ReplicatedStorage.Shared.Config.Enemies)
local Net = require(ReplicatedStorage.Shared.Net)
local Progression = require(ReplicatedStorage.Shared.Config.Progression)
local ProgressionService = require(script.Parent.ProgressionService)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponService = require(script.Parent.WeaponService)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local WorldService = require(script.Parent.WorldService)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type DeathInfo = Types.DeathInfo
type Profile = Types.Profile

local PlayerService = {}

local COMBAT_LOCK = 10 -- seconds after taking damage before you can return to Haven

local diedRemote = Net.Event("Died")
local rng = Random.new()

local function addNametag(player: Player, character: Model)
	local head = character:WaitForChild("Head", 10)
	if not head or not head:IsA("BasePart") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "Nametag"
	gui.Size = UDim2.new(6, 0, 1, 0)
	gui.StudsOffset = Vector3.new(0, 2.2, 0)
	gui.MaxDistance = 90
	gui.LightInfluence = 0

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(235, 240, 255)
	label.TextStrokeTransparency = 0.5
	label.Parent = gui

	local function refresh()
		local level = player:GetAttribute("Level")
		label.Text = `Lv {if typeof(level) == "number" then level else 1}  {player.DisplayName}`
	end
	refresh()
	player:GetAttributeChangedSignal("Level"):Connect(refresh)
	gui.Parent = head
end

local function describeKiller(humanoid: Humanoid): (string?, string?)
	local attack = CombatService.GetLastAttack(humanoid, 10)
	if not attack then
		return nil, nil
	end
	local attacker = attack.Attacker
	local weapon = Weapons.Get(attack.WeaponId)
	local weaponName = if weapon then weapon.DisplayName else nil
	if attacker:IsA("Player") then
		return (attacker :: Player).DisplayName, weaponName
	end
	local enemy = Enemies.Get(attacker:GetAttribute("EnemyId"))
	return if enemy then enemy.DisplayName else "Enemy", nil
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	local profile = DataService.GetProfile(player)
	local maxHealth = Attributes.MaxHealth(if profile then profile.Attributes.VIT else Attributes.Base)
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	WeaponService.SetupCharacter(player, character)
	task.spawn(addNametag, player, character)

	humanoid.Died:Once(function()
		ProgressionService.AddStat(player, "Deaths", 1)
		local killer, weapon = describeKiller(humanoid)
		local info: DeathInfo = {
			Killer = killer,
			Weapon = weapon,
			RespawnTime = Progression.RespawnTime,
		}
		diedRemote:FireClient(player, info)
		task.delay(Progression.RespawnTime, function()
			if player.Parent and player.Character == character then
				player:LoadCharacterAsync()
			end
		end)
	end)
end

local function teleport(player: Player, position: Vector3)
	local character = player.Character
	if not character then
		return
	end
	pcall(function()
		player:RequestStreamAroundAsync(position, 5)
	end)
	local offset = Vector3.new(rng:NextNumber(-6, 6), 4, rng:NextNumber(-6, 6))
	character:PivotTo(CFrame.new(position + offset))
end

local function aliveRoot(player: Player): (Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

local function onTravel(player: Player, zoneId: string)
	local zone = Zones.Get(zoneId)
	local profile = DataService.GetProfile(player)
	local _, root = aliveRoot(player)
	if not zone or not profile or not root or not Zones.IsSafeAt(root.Position) then
		return
	end
	if profile.Level < zone.RecommendedLevel then
		ProgressionService.Notify(player, {
			Kind = "Warning",
			Text = `Transit to {zone.DisplayName} unlocks at level {zone.RecommendedLevel}. You can still walk there.`,
		})
		return
	end
	teleport(player, Zones.GetLandingPoint(zone))
end

local function onReturn(player: Player)
	local humanoid, root = aliveRoot(player)
	if not humanoid or not root then
		return
	end
	local lastDamaged = humanoid:GetAttribute("LastDamaged")
	if typeof(lastDamaged) == "number" and os.clock() - lastDamaged < COMBAT_LOCK then
		ProgressionService.Notify(player, { Kind = "Warning", Text = "Can't return while in combat" })
		return
	end
	local haven = Zones.Get(Zones.HubId) :: Zones.ZoneDef
	teleport(player, haven.Center + Vector3.new(0, 0, -30))
end

local function onProfileLoaded(player: Player, _profile: Profile)
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	player:LoadCharacterAsync()
end

function PlayerService.Init()
	Players.CharacterAutoLoads = false
	Players.RespawnTime = Progression.RespawnTime
	DataService.ProfileLoaded:Connect(onProfileLoaded)
	WorldService.TravelRequested:Connect(onTravel)
	WorldService.ReturnRequested:Connect(onReturn)
end

return PlayerService
