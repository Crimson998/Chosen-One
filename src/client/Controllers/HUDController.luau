--!strict
-- Heads-up display: vitals, progression, ammo, crosshair, hitmarkers, kill
-- feed, notifications, zone banners, bounties, damage indicators, scope
-- overlay, boss health and the death screen. Also tracks which zone the
-- local player is standing in.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Attributes = require(ReplicatedStorage.Shared.Config.Attributes)
local Inventory = require(ReplicatedStorage.Shared.Inventory)
local Items = require(ReplicatedStorage.Shared.Config.Items)
local Audio = require(ReplicatedStorage.Shared.Audio)
local Bounties = require(ReplicatedStorage.Shared.Config.Bounties)
local Create = require(script.Parent.Parent.UI.Create)
local Effects = require(script.Parent.Effects)
local Enemies = require(ReplicatedStorage.Shared.Config.Enemies)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Progression = require(ReplicatedStorage.Shared.Config.Progression)
local State = require(script.Parent.Parent.State)
local Theme = require(script.Parent.Parent.UI.Theme)
local Types = require(ReplicatedStorage.Shared.Types)
local Version = require(ReplicatedStorage.Shared.Version)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local Zones = require(ReplicatedStorage.Shared.Config.Zones)

type HitInfo = Types.HitInfo
type KillFeedEntry = Types.KillFeedEntry
type Notification = Types.Notification
type DeathInfo = Types.DeathInfo
type ZoneDef = Zones.ZoneDef

local HUD = {}

local player = Players.LocalPlayer

local KILLFEED_MAX = 6
local KILLFEED_LIFETIME = 7
local BOSS_BAR_RANGE = 260
local HELP_TEXT =
	"WASD Move  •  Shift Sprint  •  LMB Fire  •  RMB Aim/Guard  •  R Reload  •  1/2/Q Switch  •  F Med Kit  •  G Grenade  •  E Interact/Loot  •  Tab Inventory  •  B Armory  •  C Stats  •  M Settings  •  P Scores  •  H Help"
local CIRCLE_COLOR = Color3.fromRGB(80, 255, 140)

local gui: ScreenGui
local humanoid: Humanoid? = nil

-- Element references (assigned in build()).
local crosshair: Frame
local circleStroke: UIStroke
local hitmarker: Frame
local hitBars: { Frame } = {}
local healthFill: Frame
local healthText: TextLabel
local bpmLabel: TextLabel
local pointsLabel: TextLabel
local levelLabel: TextLabel
local xpFill: Frame
local xpText: TextLabel
local creditsLabel: TextLabel
local weaponLabel: TextLabel
local suppliesLabel: TextLabel
local magLabel: TextLabel
local reserveLabel: TextLabel
local modeLabel: TextLabel
local slotLabels: { [string]: TextLabel } = {}
local reloadBack: Frame
local reloadFill: Frame
local zoneLabel: TextLabel
local zoneTag: TextLabel
local zoneBanner: Frame
local zoneBannerTitle: TextLabel
local zoneBannerSub: TextLabel
local killFeed: Frame
local rewardFeed: Frame
local banner: Frame
local bannerTitle: TextLabel
local bannerSub: TextLabel
local toast: TextLabel
local bountyList: Frame
local damageRing: Frame
local vignette: Frame
local deathScreen: Frame
local deathSub: TextLabel
local deathTimer: TextLabel
local scopeOverlay: Frame
local bossBar: Frame
local bossName: TextLabel
local bossFill: Frame
local helpLabel: TextLabel

local bannerQueue: { { Title: string, Subtitle: string, Color: Color3 } } = {}
local bannerBusy = false
local deathDeadline = 0
local toastToken = 0

---------------------------------------------------------------------------
-- Construction helpers
---------------------------------------------------------------------------

local function text(props: { [string]: any }): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		TextColor3 = Theme.Text,
		TextSize = 16,
		TextStrokeTransparency = 0.7,
	}
	for key, value in props do
		defaults[key] = value
	end
	return Create("TextLabel", defaults)
end

local function corner(radius: number): UICorner
	return Create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function bar(parent: Instance, position: UDim2, size: UDim2, color: Color3): (Frame, Frame)
	local back: Frame = Create("Frame", {
		Position = position,
		Size = size,
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Parent = parent,
	}, { corner(3) })
	local fill: Frame = Create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = back,
	}, { corner(3) })
	return back, fill
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

-- The bullet circle: shots land anywhere inside it. WeaponController sizes it
-- from the weapon, movement, stats and heart rate.
local function buildCrosshair()
	crosshair = Create("Frame", {
		Name = "BulletCircle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(40, 40),
		BackgroundTransparency = 1,
		ZIndex = 8,
		Parent = gui,
	}, {
		Create("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
	})
	circleStroke = Create("UIStroke", {
		Color = CIRCLE_COLOR,
		Thickness = 1.5,
		Transparency = 0.3,
		Parent = crosshair,
	})
	Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(3, 3),
		BackgroundColor3 = CIRCLE_COLOR,
		BorderSizePixel = 0,
		ZIndex = 8,
		Parent = crosshair,
	}, { Create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })

	hitmarker = Create("Frame", {
		Name = "Hitmarker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	for _, offset in { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(1, 1) } do
		local barFrame: Frame = Create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(offset.X * 9, offset.Y * 9),
			Size = UDim2.fromOffset(2, 10),
			Rotation = if offset.X * offset.Y > 0 then -45 else 45,
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = hitmarker,
		})
		table.insert(hitBars, barFrame)
	end
end

local function buildVitals()
	local status: Frame = Create("Frame", {
		Name = "Status",
		Position = UDim2.fromOffset(16, 60),
		Size = UDim2.fromOffset(300, 48),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.45,
		Parent = gui,
	}, { corner(6) })
	text({
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.fromOffset(200, 18),
		Font = Theme.FontHeavy,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = player.DisplayName,
		Parent = status,
	})
	bpmLabel = text({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 4),
		Size = UDim2.fromOffset(90, 18),
		TextSize = 14,
		TextColor3 = Theme.Bad,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "♥ 70",
		Parent = status,
	})
	local _, fill = bar(status, UDim2.fromOffset(10, 26), UDim2.fromOffset(280, 14), Theme.Good)
	healthFill = fill
	healthText = text({
		Position = UDim2.fromOffset(16, 25),
		Size = UDim2.fromOffset(200, 16),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 12,
		TextStrokeTransparency = 0.4,
		Text = "HP 100",
		Parent = status,
	})

	local panel: Frame = Create("Frame", {
		Name = "Progress",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -20),
		Size = UDim2.fromOffset(320, 66),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	pointsLabel = text({
		Position = UDim2.fromOffset(0, -22),
		Size = UDim2.fromOffset(320, 18),
		TextSize = 14,
		TextColor3 = Theme.XP,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Visible = false,
		Parent = panel,
	})

	levelLabel = text({
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(70, 26),
		Font = Theme.FontHeavy,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.XP,
		Text = "LV 1",
		Parent = panel,
	})
	local _, xp = bar(panel, UDim2.fromOffset(72, 10), UDim2.fromOffset(248, 8), Theme.XP)
	xpFill = xp
	xpText = text({
		Position = UDim2.fromOffset(72, 20),
		Size = UDim2.fromOffset(248, 16),
		TextSize = 13,
		TextColor3 = Theme.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "0 / 0 XP",
		Parent = panel,
	})
	creditsLabel = text({
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.fromOffset(320, 24),
		TextSize = 20,
		TextColor3 = Theme.Credits,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "¢ 0",
		Parent = panel,
	})
end

local function buildWeaponPanel()
	local panel: Frame = Create("Frame", {
		Name = "Weapon",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -20, 1, -20),
		Size = UDim2.fromOffset(320, 130),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	weaponLabel = text({
		Size = UDim2.fromOffset(320, 22),
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
		Parent = panel,
	})
	suppliesLabel = text({
		Position = UDim2.fromOffset(0, -20),
		Size = UDim2.fromOffset(320, 18),
		TextSize = 14,
		TextColor3 = Theme.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
		Parent = panel,
	})
	magLabel = text({
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.fromOffset(230, 50),
		Font = Theme.FontHeavy,
		TextSize = 48,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "0",
		Parent = panel,
	})
	reserveLabel = text({
		Position = UDim2.fromOffset(236, 38),
		Size = UDim2.fromOffset(84, 30),
		TextSize = 22,
		TextColor3 = Theme.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "/ 0",
		Parent = panel,
	})
	modeLabel = text({
		Position = UDim2.fromOffset(0, 72),
		Size = UDim2.fromOffset(320, 16),
		TextSize = 13,
		TextColor3 = Theme.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
		Parent = panel,
	})
	reloadBack, reloadFill = bar(panel, UDim2.fromOffset(120, 92), UDim2.fromOffset(200, 5), Theme.Accent)
	reloadBack.Visible = false
	for index, slot in { "Primary", "Secondary" } do
		slotLabels[slot] = text({
			Position = UDim2.fromOffset(0, 98 + (index - 1) * 16),
			Size = UDim2.fromOffset(320, 16),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "",
			Parent = panel,
		})
	end
end

local function buildTop()
	local zoneFrame: Frame = Create("Frame", {
		Name = "Zone",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(360, 44),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	zoneLabel = text({
		Size = UDim2.fromOffset(360, 24),
		Font = Theme.FontHeavy,
		TextSize = 20,
		Text = "",
		Parent = zoneFrame,
	})
	zoneTag = text({
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.fromOffset(360, 16),
		TextSize = 13,
		Text = "",
		Parent = zoneFrame,
	})

	bossBar = Create("Frame", {
		Name = "BossBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 58),
		Size = UDim2.fromOffset(460, 34),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	bossName = text({
		Size = UDim2.fromOffset(460, 18),
		Font = Theme.FontHeavy,
		TextSize = 16,
		TextColor3 = Theme.Bad,
		Text = "",
		Parent = bossBar,
	})
	local _, fill = bar(bossBar, UDim2.fromOffset(0, 20), UDim2.fromOffset(460, 10), Theme.Bad)
	bossFill = fill

	toast = text({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 100),
		Size = UDim2.fromOffset(520, 30),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 1,
		TextSize = 16,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Text = "",
		Parent = gui,
	})
	corner(6).Parent = toast

	zoneBanner = Create("Frame", {
		Name = "ZoneBanner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.fromOffset(700, 90),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	zoneBannerTitle = text({
		Size = UDim2.fromOffset(700, 54),
		Font = Theme.FontHeavy,
		TextSize = 46,
		TextStrokeTransparency = 0.5,
		Text = "",
		Parent = zoneBanner,
	})
	zoneBannerSub = text({
		Position = UDim2.fromOffset(0, 56),
		Size = UDim2.fromOffset(700, 24),
		TextSize = 18,
		TextColor3 = Theme.Muted,
		TextStrokeTransparency = 0.5,
		Text = "",
		Parent = zoneBanner,
	})

	banner = Create("Frame", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.2),
		Size = UDim2.fromOffset(640, 80),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	bannerTitle = text({
		Size = UDim2.fromOffset(640, 46),
		Font = Theme.FontHeavy,
		TextSize = 40,
		TextStrokeTransparency = 0.4,
		Text = "",
		Parent = banner,
	})
	bannerSub = text({
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.fromOffset(640, 24),
		TextSize = 18,
		TextStrokeTransparency = 0.5,
		Text = "",
		Parent = banner,
	})
end

local function buildFeeds()
	killFeed = Create("Frame", {
		Name = "KillFeed",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 60),
		Size = UDim2.fromOffset(420, 200),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		Create("UIListLayout", {
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	})

	rewardFeed = Create("Frame", {
		Name = "Rewards",
		Position = UDim2.new(0.5, 40, 0.5, 30),
		Size = UDim2.fromOffset(300, 140),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		Create("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
	})

	local bounties: Frame = Create("Frame", {
		Name = "Bounties",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0.36, 0),
		Size = UDim2.fromOffset(270, 190),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	text({
		Size = UDim2.fromOffset(270, 20),
		Font = Theme.FontHeavy,
		TextSize = 15,
		TextColor3 = Theme.XP,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "BOUNTIES",
		Parent = bounties,
	})
	bountyList = Create("Frame", {
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.fromOffset(270, 166),
		BackgroundTransparency = 1,
		Parent = bounties,
	}, {
		Create("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
	})
end

local function buildOverlays()
	damageRing = Create("Frame", {
		Name = "DamageRing",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		Parent = gui,
	})

	-- Red edges that intensify as health drops.
	vignette = Create("Frame", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 0,
		Parent = gui,
	})
	for _, spec in
		{
			{ Size = UDim2.fromScale(1, 0.25), Position = UDim2.fromScale(0, 0), Rotation = 90 },
			{ Size = UDim2.fromScale(1, 0.25), Position = UDim2.fromScale(0, 0.75), Rotation = -90 },
			{ Size = UDim2.fromScale(0.2, 1), Position = UDim2.fromScale(0, 0), Rotation = 0 },
			{ Size = UDim2.fromScale(0.2, 1), Position = UDim2.fromScale(0.8, 0), Rotation = 180 },
		}
	do
		Create("Frame", {
			Size = spec.Size,
			Position = spec.Position,
			BackgroundColor3 = Color3.fromRGB(200, 0, 0),
			BorderSizePixel = 0,
			ZIndex = 0,
			Parent = vignette,
		}, {
			Create("UIGradient", {
				Rotation = spec.Rotation,
				Transparency = NumberSequence.new(0, 1),
			}),
		})
	end
	vignette.Visible = false

	-- Scope: a clear circle with everything outside it blacked out by an
	-- oversized stroke, plus a thin reticle.
	scopeOverlay = Create("Frame", {
		Name = "Scope",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 5,
		Parent = gui,
	})
	local lens: Frame = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.88, 0.88),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = scopeOverlay,
	}, {
		Create("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Create("UIStroke", {
			Color = Color3.new(0, 0, 0),
			Thickness = 4000,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Outer,
		}),
	})
	for _, spec in
		{
			{ Size = UDim2.new(1, 0, 0, 1) },
			{ Size = UDim2.new(0, 1, 1, 0) },
		}
	do
		Create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = spec.Size,
			BackgroundColor3 = Color3.new(0, 0, 0),
			BorderSizePixel = 0,
			ZIndex = 6,
			Parent = lens,
		})
	end
	Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4),
		BackgroundColor3 = Color3.fromRGB(255, 40, 40),
		BorderSizePixel = 0,
		ZIndex = 7,
		Parent = lens,
	}, { Create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })

	deathScreen = Create("Frame", {
		Name = "Death",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(10, 0, 0),
		BackgroundTransparency = 0.45,
		Visible = false,
		ZIndex = 10,
		Parent = gui,
	})
	text({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(700, 70),
		Font = Theme.FontHeavy,
		TextSize = 64,
		TextColor3 = Theme.Bad,
		Text = "ELIMINATED",
		ZIndex = 11,
		Parent = deathScreen,
	})
	deathSub = text({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.4, 56),
		Size = UDim2.fromOffset(700, 28),
		TextSize = 22,
		Text = "",
		ZIndex = 11,
		Parent = deathScreen,
	})
	deathTimer = text({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.4, 96),
		Size = UDim2.fromOffset(700, 24),
		TextSize = 18,
		TextColor3 = Theme.Muted,
		Text = "",
		ZIndex = 11,
		Parent = deathScreen,
	})

	helpLabel = text({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(0.9, 0, 0, 18),
		TextSize = 13,
		TextColor3 = Theme.Muted,
		TextStrokeTransparency = 0.5,
		Text = HELP_TEXT,
		Parent = gui,
	})

	text({
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -8, 1, -8),
		Size = UDim2.fromOffset(160, 14),
		TextSize = 11,
		TextColor3 = Theme.Muted,
		TextTransparency = 0.4,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = `Chosen One v{Version}`,
		Parent = gui,
	})
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function refreshProfile()
	local profile = State.Profile
	if not profile then
		return
	end
	levelLabel.Text = `LV {profile.Level}`
	if profile.Level >= Progression.MaxLevel then
		xpFill.Size = UDim2.fromScale(1, 1)
		xpText.Text = "MAX LEVEL"
	else
		local needed = Progression.XPForLevel(profile.Level)
		xpFill.Size = UDim2.fromScale(math.clamp(profile.XP / needed, 0, 1), 1)
		xpText.Text = `{Format.Commas(profile.XP)} / {Format.Commas(needed)} XP`
	end
	creditsLabel.Text = `¢ {Format.Commas(profile.Credits)}`
	local medkits = Inventory.Count(profile, "MedKit") + Inventory.Count(profile, "MedKitPlus")
	local grenades = Inventory.Count(profile, "PlasmaGrenade")
	suppliesLabel.Text = `[F] MED KIT x{medkits}     [G] PLASMA x{grenades}`
	pointsLabel.Visible = profile.AttributePoints > 0
	pointsLabel.Text =
		`▲ {profile.AttributePoints} stat point{if profile.AttributePoints == 1 then "" else "s"} to spend (press C)`

	for _, child in bountyList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for index, progress in profile.Bounties do
		local def = Bounties.Get(progress.Id)
		if not def then
			continue
		end
		local entry: Frame = Create("Frame", {
			LayoutOrder = index,
			Size = UDim2.fromOffset(270, 46),
			BackgroundColor3 = Theme.Panel,
			BackgroundTransparency = 0.45,
			Parent = bountyList,
		}, { corner(6) })
		text({
			Position = UDim2.fromOffset(8, 3),
			Size = UDim2.fromOffset(254, 16),
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = def.Title,
			Parent = entry,
		})
		text({
			Position = UDim2.fromOffset(8, 19),
			Size = UDim2.fromOffset(254, 14),
			TextSize = 12,
			TextColor3 = Theme.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = `{def.Description}  ({progress.Progress}/{def.Goal})`,
			Parent = entry,
		})
		local _, fill = bar(entry, UDim2.fromOffset(8, 37), UDim2.fromOffset(254, 4), Theme.XP)
		fill.Size = UDim2.fromScale(math.clamp(progress.Progress / def.Goal, 0, 1), 1)
	end
end

local function refreshAmmo()
	local ammo = State.Ammo
	if not ammo then
		weaponLabel.Text = ""
		magLabel.Text = ""
		reserveLabel.Text = ""
		modeLabel.Text = ""
		return
	end
	local equippedSlot = if ammo.Equipped == "Secondary" then ammo.Secondary else ammo.Primary
	local def = Weapons.Get(equippedSlot.Id)
	local rarity = Items.RarityInfo(equippedSlot.Rarity)
	local rarityPrefix = if equippedSlot.Rarity ~= "Common" then `{string.upper(equippedSlot.Rarity)} ` else ""
	weaponLabel.Text = if def then rarityPrefix .. string.upper(def.DisplayName) else ""
	weaponLabel.TextColor3 = if equippedSlot.Rarity ~= "Common" then rarity.Color else Theme.Text
	local melee = def ~= nil and def.Melee == true
	magLabel.Text = if melee then "∞" else tostring(equippedSlot.Mag)
	reserveLabel.Text = if melee then "" else `/ {equippedSlot.Reserve}`
	magLabel.TextColor3 = if def
			and not melee
			and equippedSlot.Mag <= math.ceil(def.MagSize * 0.25)
		then Theme.Bad
		else Theme.Text

	if def then
		local mode = if melee
			then "MELEE  •  [RMB] GUARD"
			elseif def.FireMode == "Burst" then `BURST x{def.BurstCount or 3}`
			else string.upper(def.FireMode)
		local hint = if melee
			then ""
			elseif equippedSlot.Mag == 0 and equippedSlot.Reserve > 0 then "   •   [R] RELOAD"
			elseif equippedSlot.Mag == 0 then "   •   NO AMMO"
			else ""
		local ammoType = if def.Ammo == "Optical"
			then "  •  OPTICAL"
			elseif def.Ammo == "Solid" then "  •  SOLID"
			else ""
		local profile = State.Profile
		local overweight = profile ~= nil
			and Inventory.Weight(profile) > Attributes.CarryCapacity(profile.Attributes.STR)
		modeLabel.Text = `{if overweight then "OVERWEIGHT  •  " else ""}{def.Class}  •  {mode}{ammoType}{hint}`
		modeLabel.TextColor3 = if overweight then Theme.Warn else Theme.Muted
	end

	for index, slot in { "Primary", "Secondary" } do
		local slotAmmo = if slot == "Primary" then ammo.Primary else ammo.Secondary
		local slotDef = Weapons.Get(slotAmmo.Id)
		local label = slotLabels[slot]
		label.Text = `[{index}]  {if slotDef then slotDef.DisplayName else "?"}`
		label.TextColor3 = if ammo.Equipped == slot then Theme.Accent else Theme.Muted
	end
end

---------------------------------------------------------------------------
-- Transient elements
---------------------------------------------------------------------------

local function showToast(message: string, color: Color3?)
	toastToken += 1
	local token = toastToken
	toast.Text = message
	toast.TextColor3 = color or Theme.Text
	toast.TextTransparency = 0
	toast.TextStrokeTransparency = 0.6
	toast.BackgroundTransparency = 0.35
	task.delay(3, function()
		if token ~= toastToken then
			return
		end
		TweenService:Create(toast, TweenInfo.new(0.4), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
			BackgroundTransparency = 1,
		}):Play()
	end)
end

local function runBannerQueue()
	if bannerBusy then
		return
	end
	bannerBusy = true
	while #bannerQueue > 0 do
		local item = table.remove(bannerQueue, 1) :: { Title: string, Subtitle: string, Color: Color3 }
		bannerTitle.Text = item.Title
		bannerTitle.TextColor3 = item.Color
		bannerSub.Text = item.Subtitle
		bannerTitle.TextTransparency = 1
		bannerSub.TextTransparency = 1
		banner.Visible = true
		TweenService:Create(bannerTitle, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
		TweenService:Create(bannerSub, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
		task.wait(2.6)
		TweenService:Create(bannerTitle, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		TweenService:Create(bannerSub, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		task.wait(0.35)
		banner.Visible = false
	end
	bannerBusy = false
end

local function showBanner(title: string, subtitle: string, color: Color3)
	table.insert(bannerQueue, { Title = title, Subtitle = subtitle, Color = color })
	task.spawn(runBannerQueue)
end

local function addReward(message: string, color: Color3)
	local label = text({
		Size = UDim2.fromOffset(300, 20),
		TextSize = 16,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextStrokeTransparency = 0.5,
		Text = message,
		LayoutOrder = math.floor(os.clock() * 100),
		Parent = rewardFeed,
	})
	task.delay(1.6, function()
		TweenService:Create(label, TweenInfo.new(0.4), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		task.wait(0.45)
		label:Destroy()
	end)
	local labels = {}
	for _, child in rewardFeed:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(labels, child)
		end
	end
	if #labels > 6 then
		table.sort(labels, function(a: TextLabel, b: TextLabel)
			return a.LayoutOrder < b.LayoutOrder
		end)
		labels[1]:Destroy()
	end
end

local function addKillFeed(entry: KillFeedEntry)
	local function colorFor(name: string, isEnemy: boolean): string
		if isEnemy then
			return "#ff6b5a"
		elseif name == player.DisplayName then
			return "#00c8ff"
		end
		return "#ecf0f8"
	end
	local weapon = if entry.Weapon ~= "" then `  <font color="#96a0b0">[{entry.Weapon}]</font>` else ""
	local headshot = if entry.Headshot then `  <font color="#ffc828">HEADSHOT</font>` else ""
	local message =
		`<font color="{colorFor(entry.Killer, entry.KillerIsEnemy)}">{entry.Killer}</font>{weapon}  <font color="{colorFor(
			entry.Victim,
			entry.VictimIsEnemy
		)}">{entry.Victim}</font>{headshot}`

	local label = text({
		Size = UDim2.fromOffset(420, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.4,
		TextSize = 15,
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextStrokeTransparency = 1,
		Text = message,
		LayoutOrder = math.floor(os.clock() * 100),
		Parent = killFeed,
	})
	Create("UIPadding", {
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
		Parent = label,
	})
	corner(4).Parent = label

	local entries = {}
	for _, child in killFeed:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(entries, child)
		end
	end
	if #entries > KILLFEED_MAX then
		table.sort(entries, function(a: TextLabel, b: TextLabel)
			return a.LayoutOrder < b.LayoutOrder
		end)
		entries[1]:Destroy()
	end
	task.delay(KILLFEED_LIFETIME, function()
		if label.Parent then
			TweenService:Create(label, TweenInfo.new(0.5), { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
			task.wait(0.55)
			label:Destroy()
		end
	end)
end

local function showHitmarker(hits: { HitInfo })
	local killed, headshot = false, false
	for _, hit in hits do
		killed = killed or hit.Killed
		headshot = headshot or hit.Headshot
		Effects.DamageNumber(hit.Position, hit.Damage, hit.Headshot, hit.Killed, hit.Critical)
	end
	local color = if killed then Theme.Bad elseif headshot then Theme.Headshot else Color3.new(1, 1, 1)
	local size = if killed then 14 else 10
	for _, barFrame in hitBars do
		barFrame.BackgroundColor3 = color
		barFrame.BackgroundTransparency = 0
		barFrame.Size = UDim2.fromOffset(2, size)
		TweenService
			:Create(barFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.08), {
				BackgroundTransparency = 1,
			})
			:Play()
	end
	if killed then
		Audio.Play("Kill", 0.7)
	elseif headshot then
		Audio.Play("Headshot", 0.6)
	else
		Audio.Play("Hitmarker", 0.5)
	end
end

local function showDamageDirection(source: Vector3?)
	if typeof(source) ~= "Vector3" then
		return
	end
	local indicator: Frame = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(70, 8),
		BackgroundColor3 = Theme.Bad,
		BorderSizePixel = 0,
		Parent = damageRing,
	}, { corner(4) })
	local started = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local age = os.clock() - started
		if age > 1.4 or not indicator.Parent then
			connection:Disconnect()
			indicator:Destroy()
			return
		end
		local camera = workspace.CurrentCamera
		local toSource = source - camera.CFrame.Position
		local look = camera.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		local forward = if flatLook.Magnitude > 0.01 then flatLook.Unit else camera.CFrame.UpVector
		-- Screen angle: 0 = straight ahead (top of the ring), clockwise positive.
		local angle = math.atan2(toSource:Dot(camera.CFrame.RightVector), toSource:Dot(forward))
		local radius = 120
		indicator.Position = UDim2.fromOffset(math.sin(angle) * radius, -math.cos(angle) * radius)
		indicator.Rotation = math.deg(angle)
		indicator.BackgroundTransparency = math.clamp(age / 1.4, 0, 1)
	end)
end

local function onNotify(notification: Notification)
	if typeof(notification) ~= "table" then
		return
	end
	local kind = notification.Kind
	local amount = notification.Amount or 0
	if kind == "XP" then
		local suffix = if notification.Text ~= "" then `  {notification.Text}` else ""
		addReward(`+{Format.Commas(amount)} XP{suffix}`, Theme.XP)
	elseif kind == "Loot" then
		local rarity = notification.Rarity or "Common"
		local prefix = if rarity ~= "Common" then `{rarity} ` else ""
		local count = if amount > 1 then ` x{amount}` else ""
		addReward(`+ {prefix}{notification.Text}{count}`, Items.RarityInfo(rarity).Color)
	elseif kind == "Credits" then
		addReward(`+¢{Format.Commas(amount)}`, Theme.Credits)
	elseif kind == "LevelUp" then
		showBanner(notification.Text, `Level up!  +¢{Format.Commas(amount)}  •  new stat points (press C)`, Theme.XP)
		Audio.Play("LevelUp", 0.8)
	elseif kind == "Bounty" then
		showBanner("BOUNTY COMPLETE", notification.Text, Theme.XP)
		Audio.Play("BountyComplete", 0.8)
	elseif kind == "Boss" then
		showBanner("WORLD BOSS", notification.Text, Theme.Bad)
	elseif kind == "Jackpot" then
		showBanner("UNTOUCHABLE!", notification.Text, Theme.XP)
		Audio.Play("BountyComplete", 0.9)
	elseif kind == "Warning" then
		showToast(notification.Text, Theme.Warn)
	else
		showToast(notification.Text, Theme.Text)
	end
end

local function onZoneChanged(zone: ZoneDef?)
	if not zone then
		zoneLabel.Text = "WILDERNESS"
		zoneTag.Text = ""
		return
	end
	local tag: string
	local color: Color3
	if zone.Safe then
		tag, color = "SAFE ZONE  •  Press B for Armory", Theme.Good
	elseif zone.PvP then
		tag, color = "PVP ENABLED", Theme.Bad
	else
		tag, color = "PVE ZONE", Theme.Warn
	end
	zoneLabel.Text = string.upper(zone.DisplayName)
	zoneTag.Text = tag
	zoneTag.TextColor3 = color

	zoneBannerTitle.Text = string.upper(zone.DisplayName)
	zoneBannerTitle.TextColor3 = zone.Theme.Accent
	zoneBannerSub.Text = `{zone.Description}   •   Recommended Lv {zone.RecommendedLevel}+`
	zoneBanner.Visible = true
	zoneBannerTitle.TextTransparency = 0
	zoneBannerSub.TextTransparency = 0
	task.delay(2.5, function()
		if zoneLabel.Text ~= string.upper(zone.DisplayName) then
			return
		end
		TweenService:Create(zoneBannerTitle, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		TweenService:Create(zoneBannerSub, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
	end)
end

local function onDied(info: DeathInfo)
	if typeof(info) ~= "table" then
		return
	end
	local killer = if info.Killer then `by {info.Killer}` else "You died"
	local weapon = if info.Weapon then `  —  {info.Weapon}` else ""
	deathSub.Text = killer .. weapon
	deathDeadline = os.clock() + info.RespawnTime
	deathScreen.Visible = true
end

---------------------------------------------------------------------------
-- Per-frame / periodic updates
---------------------------------------------------------------------------

local function findBoss(): Model?
	local enemies = workspace:FindFirstChild("Enemies")
	local camera = workspace.CurrentCamera
	if not enemies then
		return nil
	end
	for _, model in enemies:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("Boss") then
			local root = model.PrimaryPart
			local bossHumanoid = model:FindFirstChildOfClass("Humanoid")
			if
				root
				and bossHumanoid
				and bossHumanoid.Health > 0
				and (root.Position - camera.CFrame.Position).Magnitude < BOSS_BAR_RANGE
			then
				return model
			end
		end
	end
	return nil
end

local function periodicUpdate()
	-- Zone tracking.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local zone = Zones.GetZoneAt(root.Position)
		local previous = State.Zone
		if zone ~= previous then
			State.Zone = zone
			State.ZoneChanged:Fire(zone)
		end
	end

	-- Boss bar.
	local boss = findBoss()
	if boss then
		local bossHumanoid = boss:FindFirstChildOfClass("Humanoid") :: Humanoid
		local def = Enemies.Get(boss:GetAttribute("EnemyId"))
		bossName.Text = string.upper(if def then def.DisplayName else boss.Name)
		bossFill.Size = UDim2.fromScale(math.clamp(bossHumanoid.Health / bossHumanoid.MaxHealth, 0, 1), 1)
		bossBar.Visible = true
	else
		bossBar.Visible = false
	end
end

local function renderUpdate()
	local camera = workspace.CurrentCamera
	local viewport = camera.ViewportSize

	-- The bullet circle is drawn at the true size of the spread cone.
	local fov = math.rad(camera.FieldOfView)
	local radius = math.tan(math.rad(State.Spread)) / math.tan(fov / 2) * (viewport.Y / 2)
	radius = math.clamp(radius, 4, 260)
	crosshair.Size = UDim2.fromOffset(radius * 2, radius * 2)
	circleStroke.Transparency = if State.Firing or State.AimHeld then 0.05 else 0.4
	local weapon = Weapons.Get(State.WeaponId)
	local alive = humanoid ~= nil and humanoid.Health > 0
	crosshair.Visible = alive and weapon ~= nil and not weapon.Melee and not State.Sprinting and not State.UIOpen

	bpmLabel.Text = `♥ {math.floor(State.HeartRate + 0.5)}`
	bpmLabel.TextTransparency = 0.45 - 0.45 * State.Pulse

	scopeOverlay.Visible = State.Scoped

	-- Vitals.
	if humanoid then
		local ratio = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
		healthFill.Size = UDim2.fromScale(ratio, 1)
		healthFill.BackgroundColor3 = Theme.Bad:Lerp(Theme.Good, ratio)
		healthText.Text = `HP {math.ceil(humanoid.Health)} / {math.floor(humanoid.MaxHealth)}`
		vignette.Visible = ratio < 0.5 and ratio > 0
		vignette.BackgroundTransparency = 1
		for _, edge in vignette:GetChildren() do
			if edge:IsA("Frame") then
				edge.BackgroundTransparency = 0.35 + ratio
			end
		end
	end

	-- Reload progress, or minigun spin-up.
	if State.Reloading and State.ReloadDuration > 0 then
		reloadBack.Visible = true
		reloadFill.BackgroundColor3 = Theme.Accent
		reloadFill.Size = UDim2.fromScale(math.clamp((os.clock() - State.ReloadStart) / State.ReloadDuration, 0, 1), 1)
	elseif weapon and weapon.SpinUp and State.SpinUp > 0 then
		reloadBack.Visible = true
		reloadFill.BackgroundColor3 = if State.SpinUp >= 1 then Theme.Bad else Theme.Warn
		reloadFill.Size = UDim2.fromScale(State.SpinUp, 1)
	else
		reloadBack.Visible = false
	end

	if deathScreen.Visible then
		deathTimer.Text = `Respawning in {math.max(0, math.ceil(deathDeadline - os.clock()))}...`
	end
end

local function onCharacterAdded(character: Model)
	deathScreen.Visible = false
	local newHumanoid = character:WaitForChild("Humanoid", 10)
	if newHumanoid and newHumanoid:IsA("Humanoid") then
		humanoid = newHumanoid
	end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function HUD.Init()
	gui = Create("ScreenGui", {
		Name = "HUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	buildOverlays()
	buildCrosshair()
	buildVitals()
	buildWeaponPanel()
	buildTop()
	buildFeeds()

	State.ProfileChanged:Connect(refreshProfile)
	State.AmmoChanged:Connect(refreshAmmo)
	State.ZoneChanged:Connect(onZoneChanged)

	Net.Event("HitConfirm").OnClientEvent:Connect(showHitmarker)
	Net.Event("KillFeed").OnClientEvent:Connect(addKillFeed)
	Net.Event("Notify").OnClientEvent:Connect(onNotify)
	Net.Event("Died").OnClientEvent:Connect(onDied)
	Net.Event("DamageTaken").OnClientEvent:Connect(function(source: Vector3?, amount: number)
		if amount == 0 then
			addReward("DEFLECTED", Color3.fromRGB(170, 140, 255))
			Audio.Play("Deflect", 0.6)
			return
		end
		showDamageDirection(source)
		Audio.Play("Hurt", 0.5)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.H then
			helpLabel.Visible = not helpLabel.Visible
		end
	end)
end

function HUD.Start()
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
	RunService.RenderStepped:Connect(renderUpdate)
	task.spawn(function()
		while true do
			periodicUpdate()
			task.wait(0.25)
		end
	end)
	task.delay(25, function()
		helpLabel.Visible = false
	end)
	refreshProfile()
	refreshAmmo()
end

function HUD.Toast(message: string, color: Color3?)
	showToast(message, color)
end

return HUD
