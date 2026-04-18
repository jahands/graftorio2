-- events.lua
-- Main metric collection event handler for Space Age metrics.

--- @type table<defines.space_platform_state, string>
local platform_state_names = {
	[defines.space_platform_state.waiting_for_starter_pack] = "waiting_for_starter_pack",
	[defines.space_platform_state.starter_pack_requested] = "starter_pack_requested",
	[defines.space_platform_state.starter_pack_on_the_way] = "starter_pack_on_the_way",
	[defines.space_platform_state.on_the_path] = "on_the_path",
	[defines.space_platform_state.waiting_for_departure] = "waiting_for_departure",
	[defines.space_platform_state.no_schedule] = "no_schedule",
	[defines.space_platform_state.no_path] = "no_path",
	[defines.space_platform_state.waiting_at_station] = "waiting_at_station",
	[defines.space_platform_state.paused] = "paused",
}

--- Collect the current rocket cargo totals for a force.
--- @param force LuaForce
local function collect_launched_items(force)
	for _, entry in ipairs(force.items_launched) do
		local quality_name = entry.quality and entry.quality.name or "normal"
		gauge_items_launched:set(entry.count, { force.name, entry.name, quality_name })
	end
end

--- Collect the current platform state for a force.
--- @param force LuaForce
local function collect_platforms(force)
	local platform_count = 0

	for _, platform in pairs(force.platforms or {}) do
		platform_count = platform_count + 1
		local platform_name = platform.name or tostring(platform.index)
		local labels = { force.name, platform_name }

		gauge_platform_state:set(1, { force.name, platform_name, platform_state_names[platform.state] or "unknown" })
		gauge_platform_weight:set(platform.weight, labels)
		gauge_platform_speed:set(platform.speed or 0, labels)
		gauge_platform_distance:set(platform.distance or 0, labels)
		gauge_platform_damaged_tiles:set(platform.damaged_tiles and #platform.damaged_tiles or 0, labels)
	end

	gauge_platform_count:set(platform_count, { force.name })
end

--- Main nth-tick event handler. Collects Space Age metrics and writes the Prometheus export file.
--- @param event NthTickEventData
function register_events(event)
	gauge_items_launched:reset()
	gauge_platform_count:reset()
	gauge_platform_state:reset()
	gauge_platform_weight:reset()
	gauge_platform_speed:reset()
	gauge_platform_distance:reset()
	gauge_platform_damaged_tiles:reset()

	for _, force in pairs(game.forces) do
		collect_launched_items(force)
		collect_platforms(force)
	end

	if server_save then
		helpers.write_file("graftorio2/game.prom", prometheus.collect(), false, 0)
	else
		helpers.write_file("graftorio2/game.prom", prometheus.collect(), false)
	end
end
