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

local export_path = "graftorio2-geo/game.prom"
local export_pipeline_interval = 60
local export_pipeline
local export_pipeline_output

local function reset_gauges()
	gauge_items_launched:reset()
	gauge_platform_count:reset()
	gauge_platform_state:reset()
	gauge_platform_weight:reset()
	gauge_platform_speed:reset()
	gauge_platform_distance:reset()
	gauge_platform_damaged_tiles:reset()
end

--- Collect the current rocket cargo totals for a force.
--- @param force LuaForce
local function collect_launched_items(force)
	for name, count in pairs(force.items_launched) do
		gauge_items_launched:set(count, { force.name, name, "normal" })
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

local function collect_metrics()
	reset_gauges()

	for _, force in pairs(game.forces) do
		collect_launched_items(force)
		collect_platforms(force)
	end
end

--- @param output string
local function write_metrics(output)
	if server_save then
		helpers.write_file(export_path, output, false, 0)
	else
		helpers.write_file(export_path, output, false)
	end
end

--- Start a new export cycle. Collection runs on this tick; later phases run on following ticks.
--- @param event NthTickEventData
function start_export_pipeline(event)
	if export_pipeline then
		return
	end

	export_pipeline_output = nil
	collect_metrics()
	export_pipeline = {
		phase = "stringify",
		next_tick = event.tick + export_pipeline_interval,
	}
end

--- Advance an active export cycle by at most one phase per tick.
--- @param event EventData.on_tick
function advance_export_pipeline(event)
	if not export_pipeline or event.tick < export_pipeline.next_tick then
		return
	end

	if export_pipeline.phase == "stringify" then
		export_pipeline_output = prometheus.collect()
		export_pipeline.phase = "write"
		export_pipeline.next_tick = event.tick + export_pipeline_interval
		return
	end

	if export_pipeline.phase == "write" then
		if export_pipeline_output then
			write_metrics(export_pipeline_output)
		end

		export_pipeline_output = nil
		export_pipeline = nil
		return
	end

	export_pipeline_output = nil
	export_pipeline = nil
end
