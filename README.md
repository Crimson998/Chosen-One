# Chosen One

A first-person shooter MMO for Roblox. Players spawn in **Haven**, a safe hub
city, then fight NPCs and each other across a chain of harder zones. Levels,
credits, weapons and bounties persist between sessions.

Everything is built from code. The map, guns, first-person viewmodels, enemies
and UI are generated at runtime from primitive parts, so the game runs from an
empty Baseplate with no uploaded assets.

## Features

- **Server-authoritative gunplay.** The client raycasts for instant feedback
  and the server decides. It validates shot origin, fire rate (a token bucket
  that tolerates network jitter), ammo, reload timing, range, line of sight
  and each claimed hit position, with extra leeway for fast-moving targets.
- **10 weapons, 2 loadout slots.** Pistol, machine pistol, revolver, SMG,
  assault rifle, burst rifle, shotgun, DMR, LMG and sniper. Weapons have
  damage falloff, headshot multipliers, spread and bloom, recoil,
  aim-down-sights with zoom and matched sensitivity, and scope overlays.
- **First-person feel.** Procedural viewmodels with arms, sway, bob, kick,
  sprint pose, reload and equip animations, muzzle flash, tracers, impacts,
  bullet holes, hitmarkers and floating damage numbers.
- **Persistent world.** One hub and three combat zones:
  | Zone | Rules | Level | Enemies |
  |---|---|---|---|
  | Haven | Safe | – | Training dummies, Armory, transit pads, global leaderboard |
  | The Outskirts | PvE | 1+ | Scavengers, Raiders |
  | The Wastes | **PvP** | 10+ | Raiders, Marauders, Sharpshooters |
  | The Core | **PvP** | 25+ | Enforcers, Sharpshooters, **The Juggernaut** (world boss) |
- **NPC AI.** Enemies wander, spot you with line of sight, fight back when
  shot, chase, strafe, fire with range-based accuracy, and leash back home if
  pulled too far. They never enter the safe zone.
- **MMO progression.** 60 levels, credits, and shared kill credit: anyone who
  deals at least 10% of an enemy's health gets full XP. Enemies far below your
  level give reduced XP. Three rotating bounties per player, PvP rewards, a
  world boss and a cross-server leaderboard.
- **Safe persistence.** Profiles save to DataStores with session locking, so a
  profile is never live on two servers at once. That stops duplication.
  Profiles autosave, save on shutdown, retry on failure, and fall back to an
  in-memory store in Studio when API access is off.
- **Interface.** HUD with health, XP, credits, ammo, weapon slots, kill feed,
  zone banners, bounty tracker, damage-direction indicators, low-health
  vignette, boss health bar and death screen. Also an Armory shop window and a
  Tab scoreboard.

## Getting started

You need [Roblox Studio](https://create.roblox.com/) and
[Rojo](https://rojo.space/). The toolchain versions are pinned in
`rokit.toml`:

```sh
rokit install        # installs rojo, stylua, selene
```

**Option A: live sync (for development)**

1. Create a new place in Studio from the **Baseplate** template.
2. Install the Rojo Studio plugin (`rojo plugin install`).
3. Run `rojo serve` in this folder, then click **Connect** in the Rojo plugin.
4. Press **Play**. The world generates on server start (the template's
   Baseplate is removed automatically).

**Option B: build a place file**

```sh
rojo build -o ChosenOne.rbxlx
```

Open `ChosenOne.rbxlx` in Studio and press **Play**.

### Saving progress in Studio

Without API access, Studio uses an in-memory store and prints a warning.
Progress doesn't persist and the leaderboard stays offline. To test real saves,
publish the place and enable **Game Settings → Security → Enable Studio Access
to API Services**.

### Publishing

- Publish the place, then set **max players** per server in Game Settings.
  30–50 suits an MMO-style server.
- Add sound effects. Roblox audio is permission-gated, so the game ships
  without sound ids. Paste audio ids you own or that are public into
  `src/shared/Config/Sounds.luau`. Empty entries are skipped silently.

## Controls

| Input | Action |
|---|---|
| WASD | Move |
| Shift | Sprint |
| Left mouse | Fire |
| Right mouse | Aim down sights |
| R | Reload |
| 1 / 2, Q, mouse wheel | Switch weapon |
| E | Interact (Armory, resupply, transit, return beacon) |
| B | Armory (inside Haven) |
| Tab | Scoreboard |
| H | Toggle controls help |

A gamepad works too: R2 fire, L2 aim, X reload, Y swap, L3 sprint.

## Project layout

```
default.project.json          Rojo project (maps src/ into the DataModel)
src/shared/   → ReplicatedStorage.Shared
  Config/                     All tuning: Weapons, Enemies, Zones, Progression, Bounties, Sounds
  Net.luau                    Every RemoteEvent/RemoteFunction, declared in one place
  Types.luau                  Profile and network payload types
  Ballistics.luau             Damage falloff and spread (shared by client and server)
  WeaponModel.luau            Procedural gun builder (viewmodels and world models)
  Signal, Spring, Audio, Format
src/server/   → ServerScriptService.Server
  Main.server.luau            Boots services in dependency order (Init, then Start)
  Services/
    WorldService              Generates the map, hub props and lighting
    DataService               Session-locked DataStore profiles
    ProgressionService        XP, levels, credits, stats, leaderstats, profile replication
    BountyService             Rotating objectives
    CombatService             All damage: zone rules, kill credit, rewards, regeneration
    WeaponService             Server-side ammo, fire-rate and hit validation, ammo drops
    EnemyService              NPC spawning and AI
    ShopService               Armory purchases and loadouts
    LeaderboardService        Cross-server leaderboard (OrderedDataStore)
    PlayerService             Spawning, nametags, death and respawn, transit
  Util/                       RateLimiter, EnemyRig (procedural R6 NPCs)
src/client/   → StarterPlayerScripts.Client
  Main.client.luau            Boots controllers
  State.luau                  Shared client state and signals
  Controllers/                Weapon, Viewmodel, Effects, HUD, Movement, Shop, Scoreboard
src/character/Health.server.luau  Stubs out default regen (CombatService handles it)
```

### How a shot works

1. **Client** (`WeaponController`): applies spread, raycasts from the camera,
   plays effects right away, and sends `{ Origin, Shots = { Dir, Hit, Pos } }`.
2. **Server** (`WeaponService`): checks rate limits, weapon state, the fire-rate
   budget and magazine, and that the origin is near the shooter's head. For
   each claim it checks the point is on the ray, in range, near the claimed
   part (allowing for latency) and not blocked by world geometry. It then
   applies damage with falloff and headshots.
3. **CombatService** enforces zone rules and spawn protection, credits
   contributors on kills, and pays out XP, credits and bounties.
4. The server confirms hits to the shooter (hitmarkers and damage numbers) and
   replicates tracers to nearby players over an unreliable remote.

## Tuning and extending

- **New weapon:** add an entry to `Config/Weapons.luau`. Pick a `Model.Style`
  or add a style to `WeaponModel.luau`. The shop, HUD and server validation
  pick it up automatically.
- **New enemy:** add it to `Config/Enemies.luau` and reference it from a
  zone's `Enemies` list in `Config/Zones.luau`.
- **New zone:** add it to `Config/Zones.luau` north of the others, with a
  seed, theme and enemy list. Give it a prop mix in `PROP_WEIGHTS` in
  `WorldService`, or it uses the Wastes mix. The layout, gate, transit pad and
  return beacon are generated for it.
- **Progression:** edit the XP curve, rewards, regeneration and respawn timing
  in `Config/Progression.luau`.

## Development

```sh
rojo sourcemap default.project.json -o sourcemap.json   # for luau-lsp
stylua src                                              # format
selene src                                              # lint
```

All code is `--!strict` Luau and type-checks cleanly with
[luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) against the Roblox type
definitions.

## Ideas for next steps

- Parties and squads with shared XP, party chat and markers
- Mobile touch controls (fire and aim buttons)
- Cosmetics: weapon skins, charms and titles bought with credits
- Pathfinding for enemies around large buildings
- Cross-server events via MessagingService (for example, synchronised boss spawns)
