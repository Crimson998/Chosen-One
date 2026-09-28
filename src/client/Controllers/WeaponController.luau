--!strict
-- First-person gunplay: input, client-side prediction (ammo, hit effects),
-- recoil, spread, aim-down-sights, reloads, weapon switching and the
-- viewmodel pose. Every shot is sent to the server, which has the final say.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Audio = require(ReplicatedStorage.Shared.Audio)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Effects = require(script.Parent.Effects)
local Net = require(ReplicatedStorage.Shared.Net)
local Spring = require(ReplicatedStorage.Shared.Spring)
local State = require(script.Parent.Parent.State)
local Types = require(ReplicatedStorage.Shared.Types)
local Viewmodel = require(script.Parent.Viewmodel)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

type WeaponDef = Weapons.WeaponDef
type Slot = string -- "Primary" | "Secondary"
type Viewmodel = Viewmodel.Viewmodel
type AmmoState = Types.AmmoState
type AmmoSlot = Types.AmmoSlot
type ShotClaim = Types.ShotClaim

local WeaponController = {}

local BASE_FOV = 70
local SPRINT_FOV = 76
local EQUIP_TIME = 0.3
local RENDER_NAME = "ChosenOneWeapons"

local player = Players.LocalPlayer

local fireRemote = Net.Event("WeaponFire")
local reloadRemote = Net.Event("WeaponReload")
local equipRemote = Net.Event("WeaponEquip")

local viewmodels: { [Slot]: Viewmodel } = {}
local equipped: Slot? = nil
local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil
local alive = false

local triggerHeld = false
local aimHeld = false
local lastShot = 0
local burstRemaining = 0
local nextBurstTime = 0
local bloom = 0
local aimAlpha = 0
local sprintAlpha = 0
local equipAlpha = 0
local reloadToken = 0
local bobTime = 0
local lastRecoil = Vector3.zero

-- Camera recoil (X = pitch, Y = yaw, degrees). Recovers on its own.
local recoilSpring = Spring.new(120, 14)
-- Viewmodel kick (X = pitch degrees, Y = pushback studs, Z = roll degrees).
local kickSpring = Spring.new(260, 20)
-- Viewmodel sway from mouse movement (X = pitch, Y = yaw, degrees).
local swaySpring = Spring.new(140, 16)

local rng = Random.new()
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function approach(value: number, target: number, step: number): number
	if value < target then
		return math.min(target, value + step)
	end
	return math.max(target, value - step)
end

local function smoothstep(t: number): number
	return t * t * (3 - 2 * t)
end

local function current(): Viewmodel?
	return if equipped then viewmodels[equipped] else nil
end

local function ammoFor(slot: Slot): AmmoSlot?
	local ammo = State.Ammo
	if not ammo then
		return nil
	end
	return if slot == "Primary" then ammo.Primary else ammo.Secondary
end

local function currentSpread(def: WeaponDef): number
	local base = def.HipSpread + (def.AimSpread - def.HipSpread) * aimAlpha
	if def.Pellets > 1 then
		return base -- shotguns keep a fixed pattern
	end
	local speed = 0
	if rootPart then
		local velocity = rootPart.AssemblyLinearVelocity
		speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	end
	local movePenalty = math.clamp(speed / 16, 0, 1.5) * 1.2 * (1 - aimAlpha * 0.6)
	local airPenalty = if humanoid and humanoid.FloorMaterial == Enum.Material.Air then 2.5 else 0
	return base + bloom * (1 - aimAlpha * 0.5) + movePenalty + airPenalty
end

local function cancelReload()
	reloadToken += 1
	State.Reloading = false
end

local function reload()
	local vm = current()
	local slot = equipped
	if not alive or not vm or not slot or State.Reloading or State.UIOpen then
		return
	end
	local def = vm.Def
	local ammo = ammoFor(slot)
	if not ammo or ammo.Mag >= def.MagSize or ammo.Reserve <= 0 then
		return
	end

	reloadToken += 1
	local token = reloadToken
	burstRemaining = 0
	State.Reloading = true
	State.ReloadStart = os.clock()
	State.ReloadDuration = def.ReloadTime
	State.AmmoChanged:Fire()
	reloadRemote:FireServer()
	Audio.Play("Reload", 0.5)

	task.delay(def.ReloadTime, function()
		if token ~= reloadToken then
			return
		end
		State.Reloading = false
		local slotAmmo = ammoFor(slot)
		if slotAmmo then
			local take = math.min(def.MagSize - slotAmmo.Mag, slotAmmo.Reserve)
			slotAmmo.Mag += take
			slotAmmo.Reserve -= take
		end
		State.AmmoChanged:Fire()
	end)
end

local function equip(slot: Slot, fromServer: boolean?)
	local vm = viewmodels[slot]
	if not vm or (equipped == slot and vm.Model.Parent ~= nil) then
		return
	end
	cancelReload()
	if equipped and viewmodels[equipped] then
		viewmodels[equipped].Model.Parent = nil
	end
	-- onRender parents the model to the camera while we're alive.
	equipped = slot
	Viewmodel.SetVisible(vm, true)
	State.Scoped = false
	equipAlpha = 0
	burstRemaining = 0
	bloom = 0
	State.WeaponId = vm.Def.Id
	if State.Ammo then
		State.Ammo.Equipped = slot
	end
	if not fromServer then
		equipRemote:FireServer(slot)
	end
	Audio.Play("Equip", 0.4)
	State.AmmoChanged:Fire()
end

local function swap()
	if equipped then
		equip(if equipped == "Primary" then "Secondary" else "Primary")
	end
end

local function clearViewmodels()
	for slot, vm in viewmodels do
		vm.Model:Destroy()
		viewmodels[slot] = nil
	end
	equipped = nil
	State.WeaponId = nil
end

local function fire(vm: Viewmodel, now: number)
	local def = vm.Def
	local slot = equipped :: Slot
	local ammo = ammoFor(slot)
	if not ammo then
		return
	end

	local interval = Weapons.FireInterval(def)
	-- Keep a steady cadence for automatic fire despite frame quantisation.
	lastShot = if now - lastShot < interval * 2 then lastShot + interval else now

	if ammo.Mag <= 0 then
		Audio.Play("Empty", 0.5)
		burstRemaining = 0
		reload()
		return
	end
	ammo.Mag -= 1

	local camera = workspace.CurrentCamera
	local origin = camera.CFrame.Position
	local forward = camera.CFrame.LookVector
	local spread = currentSpread(def)
	local shots: { ShotClaim } = {}
	local ends: { Vector3 } = {}

	for _ = 1, def.Pellets do
		local direction = Ballistics.ConeDirection(forward, spread, rng)
		local result = workspace:Raycast(origin, direction * def.Range, rayParams)
		local claim: ShotClaim = { Dir = direction }
		local endPosition = origin + direction * def.Range
		if result then
			claim.Hit = result.Instance
			claim.Pos = result.Position
			endPosition = result.Position
			local model = result.Instance:FindFirstAncestorOfClass("Model")
			local hitCharacter = model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
			Effects.Impact(result.Position, result.Normal, hitCharacter)
		end
		table.insert(shots, claim)
		table.insert(ends, endPosition)
	end

	fireRemote:FireServer({
		Slot = slot,
		Origin = origin,
		Shots = shots,
	} :: Types.FirePayload)

	local muzzle = vm.Muzzle.WorldPosition
	for _, endPosition in ends do
		Effects.Tracer(muzzle, endPosition)
	end
	Viewmodel.MuzzleFlash(vm)
	Audio.Play("Fire_" .. def.Sound, 0.5)

	local steadiness = 1 - aimAlpha * 0.35
	recoilSpring:Impulse(
		Vector3.new(def.RecoilKick * 18 * steadiness, rng:NextNumber(-1, 1) * def.RecoilSide * 18 * steadiness, 0)
	)
	kickSpring:Impulse(Vector3.new(def.RecoilKick * 25, 3, rng:NextNumber(-1, 1) * 45))
	bloom = math.min(def.MaxBloom, bloom + def.SpreadPerShot)
	State.AmmoChanged:Fire()
end

local function canFire(): boolean
	return alive
		and equipped ~= nil
		and not State.UIOpen
		and not State.Reloading
		and equipAlpha > 0.85
		and sprintAlpha < 0.3
end

local function onTriggerPressed()
	local vm = current()
	if not vm or not canFire() then
		return
	end
	local def = vm.Def
	local now = os.clock()
	if def.FireMode == "Semi" then
		if now - lastShot >= Weapons.FireInterval(def) then
			fire(vm, now)
		end
	elseif def.FireMode == "Burst" then
		if burstRemaining == 0 and now >= nextBurstTime then
			burstRemaining = def.BurstCount or 3
		end
	end
end

local function updateFiring(vm: Viewmodel, now: number)
	local def = vm.Def
	local interval = Weapons.FireInterval(def)
	if def.FireMode == "Auto" then
		if triggerHeld and now - lastShot >= interval then
			fire(vm, now)
		end
	elseif def.FireMode == "Burst" then
		if burstRemaining > 0 and now - lastShot >= interval then
			burstRemaining -= 1
			fire(vm, now)
			if burstRemaining == 0 then
				nextBurstTime = now + (def.BurstDelay or 0.3)
			end
		end
	end
end

local function onRender(dt: number)
	dt = math.min(dt, 0.1)
	local camera = workspace.CurrentCamera
	local now = os.clock()

	-- Recoil rotates the real camera; the camera module reads its look vector
	-- back next frame, so un-recovered recoil moves your aim.
	local recoil = recoilSpring:Update(dt)
	local delta = recoil - lastRecoil
	lastRecoil = recoil
	if alive then
		camera.CFrame *= CFrame.Angles(math.rad(delta.X), math.rad(delta.Y), 0)
	end

	local vm = current()
	if vm then
		local parent: Instance? = if alive then camera else nil
		if vm.Model.Parent ~= parent then
			vm.Model.Parent = parent
		end
	end
	if not vm or not alive then
		State.Scoped = false
		State.Aiming = false
		State.AimAlpha = 0
		aimAlpha = 0
		camera.FieldOfView = BASE_FOV
		UserInputService.MouseDeltaSensitivity = 1
		return
	end
	local def = vm.Def

	if State.UIOpen then
		triggerHeld = false
		burstRemaining = 0
	end
	State.Firing = triggerHeld or burstRemaining > 0

	State.AimHeld = aimHeld
	local wantsAim = aimHeld and not State.Reloading and not State.UIOpen
	aimAlpha = approach(aimAlpha, if wantsAim then 1 else 0, dt / def.AimTime)
	sprintAlpha = approach(sprintAlpha, if State.Sprinting then 1 else 0, dt / 0.15)
	equipAlpha = approach(equipAlpha, 1, dt / EQUIP_TIME)
	State.AimAlpha = aimAlpha
	State.Aiming = aimAlpha > 0.5

	if canFire() then
		updateFiring(vm, now)
	end
	if now - lastShot > Weapons.FireInterval(def) * 1.5 then
		bloom = math.max(0, bloom - dt * math.max(def.MaxBloom, 1) * 2.5)
	end
	State.Spread = currentSpread(def)

	-- Field of view and matching mouse sensitivity.
	local eased = smoothstep(aimAlpha)
	local baseFov = BASE_FOV + (SPRINT_FOV - BASE_FOV) * sprintAlpha
	camera.FieldOfView = baseFov + (def.AimFOV - baseFov) * eased
	UserInputService.MouseDeltaSensitivity = math.min(1, camera.FieldOfView / BASE_FOV)

	local scoped = def.Scoped == true and aimAlpha > 0.92
	if scoped ~= State.Scoped then
		State.Scoped = scoped
		Viewmodel.SetVisible(vm, not scoped)
	end

	-- Viewmodel pose.
	local steady = 1 - aimAlpha * 0.8
	local mouseDelta = UserInputService:GetMouseDelta()
	swaySpring:Impulse(Vector3.new(mouseDelta.Y, mouseDelta.X, 0) * 0.35 * steady)
	local sway = swaySpring:Update(dt)
	local kick = kickSpring:Update(dt)

	local speed = 0
	if rootPart then
		local velocity = rootPart.AssemblyLinearVelocity
		speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	end
	local moving = math.clamp(speed / 16, 0, 1.5)
	bobTime += dt * (5 + speed * 0.3)
	local bobAmount = moving * steady * (1 + sprintAlpha * 0.8)
	local bob = CFrame.new(math.sin(bobTime) * 0.035 * bobAmount, math.abs(math.cos(bobTime)) * 0.045 * bobAmount, 0)
		* CFrame.Angles(0, 0, math.sin(bobTime) * 0.02 * bobAmount)

	local pose = vm.Hip:Lerp(vm.Ads, eased)
	local sprintPose = vm.Hip * CFrame.new(-0.25, -0.25, 0.1) * CFrame.Angles(math.rad(-18), math.rad(35), math.rad(12))
	pose = pose:Lerp(sprintPose, sprintAlpha)

	if State.Reloading and State.ReloadDuration > 0 then
		local t = math.clamp((now - State.ReloadStart) / State.ReloadDuration, 0, 1)
		local w = math.sin(t * math.pi)
		pose *= CFrame.new(0, -0.25 * w, 0.1 * w) * CFrame.Angles(math.rad(-20 * w), math.rad(10 * w), math.rad(35 * w))
	end

	local lowered = 1 - smoothstep(equipAlpha)
	pose = CFrame.new(0, -0.8 * lowered, 0) * pose * CFrame.Angles(math.rad(-40 * lowered), 0, 0)

	local swayCFrame = CFrame.Angles(math.rad(sway.X), math.rad(sway.Y), math.rad(sway.Y * 0.5))
	local kickScale = 1 - aimAlpha * 0.6
	local kickCFrame = CFrame.new(0, 0, kick.Y * 0.035 * kickScale)
		* CFrame.Angles(math.rad(kick.X * 0.035 * kickScale), 0, math.rad(kick.Z * 0.035 * kickScale))
	vm.Root.CFrame = camera.CFrame * pose * swayCFrame * bob * kickCFrame
end

local function onAmmoUpdate(ammo: AmmoState)
	if typeof(ammo) ~= "table" then
		return
	end
	local rebuiltEquipped = false
	for _, slot in { "Primary", "Secondary" } do
		local slotAmmo = if slot == "Primary" then ammo.Primary else ammo.Secondary
		local existing = viewmodels[slot]
		if not existing or existing.Def.Id ~= slotAmmo.Id then
			local def = Weapons.Get(slotAmmo.Id)
			if def then
				if existing then
					existing.Model:Destroy()
				end
				viewmodels[slot] = Viewmodel.Build(def)
				if slot == equipped then
					rebuiltEquipped = true
				end
			end
		end
	end

	local keep = equipped
	local serverEquipped = ammo.Equipped :: Slot
	State.Ammo = ammo
	if keep == nil or rebuiltEquipped then
		local target: Slot = keep or serverEquipped
		equipped = nil
		equip(target, true)
		if target ~= serverEquipped then
			equipRemote:FireServer(target)
		end
	else
		-- Keep the local choice. If the server disagrees (a switch was dropped
		-- or is still in flight), re-send it; repeats are harmless.
		ammo.Equipped = keep
		if keep ~= serverEquipped then
			equipRemote:FireServer(keep)
		end
	end
	if State.Reloading and equipped then
		-- The server finished a reload (or refilled us); trust its numbers.
		local slotAmmo = ammoFor(equipped)
		local vm = current()
		if slotAmmo and vm and slotAmmo.Mag >= vm.Def.MagSize then
			cancelReload()
		end
	end
	State.AmmoChanged:Fire()
end

local function onCharacterAdded(character: Model)
	local newHumanoid = character:WaitForChild("Humanoid", 10)
	local newRoot = character:WaitForChild("HumanoidRootPart", 10)
	if not newHumanoid or not newHumanoid:IsA("Humanoid") or not newRoot or not newRoot:IsA("BasePart") then
		return
	end
	humanoid = newHumanoid
	rootPart = newRoot
	alive = true
	rayParams.FilterDescendantsInstances = { character, Effects.Folder() }
	newHumanoid.Died:Once(function()
		alive = false
		triggerHeld = false
		aimHeld = false
		State.AimHeld = false
		burstRemaining = 0
		cancelReload()
		clearViewmodels()
		State.Scoped = false
		State.Aiming = false
		State.Firing = false
	end)
end

local function bindInput()
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local inputType = input.UserInputType
		local key = input.KeyCode
		if inputType == Enum.UserInputType.MouseButton1 or key == Enum.KeyCode.ButtonR2 then
			if processed or State.UIOpen then
				return
			end
			triggerHeld = true
			onTriggerPressed()
		elseif inputType == Enum.UserInputType.MouseButton2 or key == Enum.KeyCode.ButtonL2 then
			if not processed then
				aimHeld = true
			end
		elseif processed then
			return
		elseif key == Enum.KeyCode.R or key == Enum.KeyCode.ButtonX then
			reload()
		elseif key == Enum.KeyCode.One then
			equip("Primary")
		elseif key == Enum.KeyCode.Two then
			equip("Secondary")
		elseif key == Enum.KeyCode.Q or key == Enum.KeyCode.ButtonY then
			swap()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		local inputType = input.UserInputType
		local key = input.KeyCode
		if inputType == Enum.UserInputType.MouseButton1 or key == Enum.KeyCode.ButtonR2 then
			triggerHeld = false
		elseif inputType == Enum.UserInputType.MouseButton2 or key == Enum.KeyCode.ButtonL2 then
			aimHeld = false
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.UserInputType == Enum.UserInputType.MouseWheel and not State.UIOpen then
			swap()
		end
	end)
end

function WeaponController.Init()
	Net.Event("AmmoUpdate").OnClientEvent:Connect(onAmmoUpdate)
	Net.Unreliable("ShotReplicated").OnClientEvent:Connect(Effects.RemoteShot)
	bindInput()
end

function WeaponController.Start()
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, onRender)
end

return WeaponController
