--!strict
-- Server entry point. Services are initialised in dependency order, then
-- started once everything is wired up.

local Services = script.Parent.Services

type Service = {
	Init: () -> (),
	Start: (() -> ())?,
}

local services: { [number]: Service } = {
	require(Services.WorldService) :: any,
	require(Services.DataService) :: any,
	require(Services.ProgressionService) :: any,
	require(Services.AttributeService) :: any,
	require(Services.BountyService) :: any,
	require(Services.CombatService) :: any,
	require(Services.WeaponService) :: any,
	require(Services.EnemyService) :: any,
	require(Services.ShopService) :: any,
	require(Services.LeaderboardService) :: any,
	require(Services.UntouchableService) :: any,
	require(Services.PlayerService) :: any,
}

for _, service in services do
	service.Init()
end

for _, service in services do
	local start = service.Start
	if start then
		task.spawn(start)
	end
end

print("[Chosen One] Server ready")
