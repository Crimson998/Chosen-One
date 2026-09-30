--!strict
-- Shared data shapes for persisted profiles and network payloads.

local Attributes = require(script.Parent.Config.Attributes)

export type Stats = {
	Kills: number, -- PvP kills
	Deaths: number,
	EnemyKills: number,
	BossKills: number,
	Headshots: number, -- headshot kills
	ShotsFired: number,
	ShotsHit: number,
	TotalXP: number, -- lifetime XP, drives the global leaderboard
	PlayTime: number, -- seconds
	BountiesCompleted: number,
}

export type BountyProgress = {
	Id: string,
	Progress: number,
}

export type Loadout = {
	Primary: string,
	Secondary: string,
}

export type Profile = {
	Version: number,
	Level: number,
	XP: number, -- progress toward the next level
	Credits: number,
	Attributes: Attributes.AttributeSet,
	AttributePoints: number, -- unspent
	OwnedWeapons: { [string]: boolean },
	Loadout: Loadout,
	Stats: Stats,
	Bounties: { BountyProgress },
}

export type AmmoSlot = {
	Id: string,
	Mag: number,
	Reserve: number,
}

-- Server -> client: authoritative loadout + ammo.
export type AmmoState = {
	Primary: AmmoSlot,
	Secondary: AmmoSlot,
	Equipped: string,
}

-- Client -> server: one trigger pull (several claims for shotguns).
export type ShotClaim = {
	Dir: Vector3,
	Hit: Instance?,
	Pos: Vector3?,
}

export type FirePayload = {
	Slot: string,
	Origin: Vector3,
	Shots: { ShotClaim },
}

-- Server -> shooter: confirmed hits for hitmarkers and damage numbers.
export type HitInfo = {
	Position: Vector3,
	Damage: number,
	Headshot: boolean,
	Critical: boolean,
	Killed: boolean,
}

-- Client -> server while aiming or holding the trigger (unreliable, ~8 Hz).
export type AimLine = {
	Origin: Vector3,
	Dir: Vector3,
}

-- Server -> client: a bullet prediction line. Lines with the same Id replace
-- each other; a line disappears after Duration seconds unless refreshed.
export type BulletLine = {
	Id: string,
	Shooter: Instance?, -- the line starts at this shooter's muzzle when visible
	From: Vector3,
	To: Vector3,
	Duration: number,
	TargetsYou: boolean,
}

-- Server -> other clients: tracer replication.
export type ShotReplication = {
	Shooter: Instance?,
	Weapon: string,
	Origin: Vector3,
	Ends: { Vector3 },
}

export type KillFeedEntry = {
	Killer: string,
	Victim: string,
	Weapon: string,
	Headshot: boolean,
	KillerIsEnemy: boolean,
	VictimIsEnemy: boolean,
}

export type NotifyKind = "XP" | "Credits" | "LevelUp" | "Bounty" | "Info" | "Warning" | "Boss" | "Jackpot"

export type Notification = {
	Kind: NotifyKind,
	Text: string,
	Amount: number?,
}

export type DeathInfo = {
	Killer: string?,
	Weapon: string?,
	RespawnTime: number,
}

return {}
