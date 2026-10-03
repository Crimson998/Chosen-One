--!strict
-- Declares every remote in one place. The server creates them on first
-- require; clients wait for them to replicate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"

local EVENTS = {
	-- client -> server
	"WeaponEquip",
	"WeaponFire",
	"WeaponReload",
	"WeaponGuard",
	"ThrowGrenade",
	"SaveSettings",
	-- server -> client
	"HitConfirm",
	"AmmoUpdate",
	"ProfileUpdate",
	"Notify",
	"KillFeed",
	"DamageTaken",
	"OpenShop",
	"Died",
	"BulletLine",
	"Explosion",
}

-- Cosmetic, high-frequency traffic that may be dropped.
local UNRELIABLE_EVENTS = {
	"ShotReplicated",
	"AimLine",
}

local FUNCTIONS = {
	"GetProfile",
	"ShopPurchase",
	"InventoryAction",
	"UseConsumable",
	"AllocateAttribute",
	"ResetAttributes",
}

local folder: Instance
if RunService:IsServer() then
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local newFolder = Instance.new("Folder")
	newFolder.Name = FOLDER_NAME
	for _, name in EVENTS do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = newFolder
	end
	for _, name in UNRELIABLE_EVENTS do
		local remote = Instance.new("UnreliableRemoteEvent")
		remote.Name = name
		remote.Parent = newFolder
	end
	for _, name in FUNCTIONS do
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = newFolder
	end
	newFolder.Parent = ReplicatedStorage
	folder = newFolder
else
	folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
end

local Net = {}

function Net.Event(name: string): RemoteEvent
	assert(table.find(EVENTS, name), `Unknown RemoteEvent "{name}"`)
	return folder:WaitForChild(name) :: RemoteEvent
end

function Net.Unreliable(name: string): UnreliableRemoteEvent
	assert(table.find(UNRELIABLE_EVENTS, name), `Unknown UnreliableRemoteEvent "{name}"`)
	return folder:WaitForChild(name) :: UnreliableRemoteEvent
end

function Net.Function(name: string): RemoteFunction
	assert(table.find(FUNCTIONS, name), `Unknown RemoteFunction "{name}"`)
	return folder:WaitForChild(name) :: RemoteFunction
end

return Net
