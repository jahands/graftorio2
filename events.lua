-- events.lua
-- Main metric collection event handler
-- Spreads metric collection across 9 consecutive game ticks to amortize cost
-- Phase 1: globals (tick, seeds, mods, pollution)
-- Phase 2: item + fluid production stats
-- Phase 3: kill + entity build count stats
-- Phase 4: evolution factors + items launched
-- Phase 5: logistic networks
-- Phase 6: research queue + Space Age platforms
-- Phase 7: power networks
-- Phase 8: circuit networks + Krastorio2 reactors
-- Phase 9: serialize + write .prom file

-- Module-local state: resets to 0 on save/load (not persisted in storage)
local collection_phase = 0

--- Iterate game.players, deduplicate by force.name, call callback(player) once per unique force.
--- The callback receives a LuaPlayer so it can access both player.force and pass the player
--- to functions like on_research_tick that expect a LuaPlayer parameter.
--- @param callback fun(player: LuaPlayer)
local function for_each_force(callback)
	--- @type table<string, boolean>
	local processed_forces = {}
	for _, player in pairs(game.players) do
		if not processed_forces[player.force.name] then
			processed_forces[player.force.name] = true
			callback(player)
		end
	end
end

-- ============================================================================
-- Phase functions
-- ============================================================================

--- Phase 1: Globals — game tick, seeds, mods, pollution stats
local function collect_globals()
	gauge_tick:set(game.tick)

	for _, surface in pairs(game.surfaces) do
		gauge_seed:set(surface.map_gen_settings.seed, { surface.name })
	end

	for name, version in pairs(script.active_mods) do
		gauge_mods:set(1, { name, version })
	end

	for _, surface in pairs(game.surfaces) do
		local stats = game.get_pollution_statistics(surface)
		for name, n in pairs(stats.input_counts) do
			gauge_pollution_production_input:set(n, { name, surface.name })
		end
		for name, n in pairs(stats.output_counts) do
			gauge_pollution_production_output:set(n, { name, surface.name })
		end
	end
end

--- Phase 2: Item + fluid production stats (per force x surface)
local function collect_production()
	for_each_force(function(player)
		for _, surface in pairs(game.surfaces) do
			--- @type {[1]: LuaFlowStatistics, [2]: Gauge, [3]: Gauge}[]
			local stats = {
				{ player.force.get_item_production_statistics(surface), gauge_item_production_input, gauge_item_production_output },
				{ player.force.get_fluid_production_statistics(surface), gauge_fluid_production_input, gauge_fluid_production_output },
			}

			for _, stat in pairs(stats) do
				for name, n in pairs(stat[1].input_counts) do
					stat[2]:set(n, { player.force.name, name, surface.name })
				end
				for name, n in pairs(stat[1].output_counts) do
					stat[3]:set(n, { player.force.name, name, surface.name })
				end
			end
		end
	end)
end

--- Phase 3: Kill counts + entity build counts (per force x surface)
local function collect_military()
	for_each_force(function(player)
		for _, surface in pairs(game.surfaces) do
			--- @type {[1]: LuaFlowStatistics, [2]: Gauge, [3]: Gauge}[]
			local stats = {
				{ player.force.get_kill_count_statistics(surface), gauge_kill_count_input, gauge_kill_count_output },
				{ player.force.get_entity_build_count_statistics(surface), gauge_entity_build_count_input, gauge_entity_build_count_output },
			}

			for _, stat in pairs(stats) do
				for name, n in pairs(stat[1].input_counts) do
					stat[2]:set(n, { player.force.name, name, surface.name })
				end
				for name, n in pairs(stat[1].output_counts) do
					stat[3]:set(n, { player.force.name, name, surface.name })
				end
			end
		end
	end)
end

--- Phase 4: Evolution factors + items launched (per force x surface)
local function collect_evolution()
	for_each_force(function(player)
		for _, surface in pairs(game.surfaces) do
			--- @type {[1]: number, [2]: string}[]
			local evolution = {
				{ player.force.get_evolution_factor(surface), "total" },
				{ player.force.get_evolution_factor_by_pollution(surface), "by_pollution" },
				{ player.force.get_evolution_factor_by_time(surface), "by_time" },
				{ player.force.get_evolution_factor_by_killing_spawners(surface), "by_killing_spawners" },
			}

			for _, stat in pairs(evolution) do
				gauge_evolution:set(stat[1], { player.force.name, stat[2], surface.name })
			end

			for _, entry in ipairs(player.force.items_launched) do
				local quality_name = entry.quality and entry.quality.name or "normal"
				gauge_items_launched:set(entry.count, { player.force.name, entry.name, quality_name })
			end
		end
	end)
end

--- Phase 5: Logistic networks — robot counts + get_contents() (per force)
local function collect_logistics()
	-- Reset logistic gauges before collecting new data
	gauge_logistic_network_all_logistic_robots:reset()
	gauge_logistic_network_available_logistic_robots:reset()
	gauge_logistic_network_all_construction_robots:reset()
	gauge_logistic_network_available_construction_robots:reset()
	gauge_logistic_network_robot_limit:reset()
	gauge_logistic_network_items:reset()

	for_each_force(function(player)
		for surface, networks in pairs(player.force.logistic_networks) do
			for _, network in ipairs(networks) do
				local network_id = tostring(network.network_id)
				gauge_logistic_network_all_logistic_robots:set(
					network.all_logistic_robots,
					{ player.force.name, surface, network_id }
				)
				gauge_logistic_network_available_logistic_robots:set(
					network.available_logistic_robots,
					{ player.force.name, surface, network_id }
				)
				gauge_logistic_network_all_construction_robots:set(
					network.all_construction_robots,
					{ player.force.name, surface, network_id }
				)
				gauge_logistic_network_available_construction_robots:set(
					network.available_construction_robots,
					{ player.force.name, surface, network_id }
				)
				gauge_logistic_network_robot_limit:set(network.robot_limit, { player.force.name, surface, network_id })
				-- Cache get_contents() call to avoid calling expensive API twice
				local contents = network.get_contents()
				if contents ~= nil then
					for _, entry in ipairs(contents) do
						local quality_name = entry.quality and entry.quality.name or "normal" ---@diagnostic disable-line: undefined-field -- quality.name exists at runtime
						gauge_logistic_network_items:set(entry.count, { player.force.name, surface, network_id, entry.name, quality_name })
					end
				end
			end
		end
	end)
end

--- Phase 6: Research queue + Space Age platforms (per force)
--- @param event NthTickEventData|EventData
local function collect_research_platforms(event)
	for_each_force(function(player)
		-- research tick handler (process once per force, not per player)
		on_research_tick(player, event)

		-- Space Age platform metrics
		if player.force.platforms then
			local platform_count = 0
			gauge_platform_state:reset()
			gauge_platform_weight:reset()
			gauge_platform_speed:reset()
			gauge_platform_distance:reset()
			gauge_platform_damaged_tiles:reset()

			for _, platform in pairs(player.force.platforms) do
				platform_count = platform_count + 1
				local platform_name = platform.name or tostring(platform.index)

				-- Map state enum to readable string
				--- @type table<defines.space_platform_state, string>
				local state_names = {
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
				local state_name = state_names[platform.state] or "unknown"

				gauge_platform_state:set(1, { player.force.name, platform_name, state_name })
				gauge_platform_weight:set(platform.weight, { player.force.name, platform_name })

				if platform.speed then
					gauge_platform_speed:set(platform.speed, { player.force.name, platform_name })
				end

				if platform.distance then
					gauge_platform_distance:set(platform.distance, { player.force.name, platform_name })
				end

				if platform.damaged_tiles then
					gauge_platform_damaged_tiles:set(#platform.damaged_tiles, { player.force.name, platform_name })
				end
			end

			gauge_platform_count:set(platform_count, { player.force.name })
		end
	end)
end

--- Phase 7: Power networks — delegates to on_power_tick
--- @param event NthTickEventData|EventData
local function collect_power(event)
	on_power_tick(event)
end

--- Phase 8: Circuit networks + Krastorio2 reactors
--- @param event NthTickEventData|EventData
local function collect_circuits(event)
	-- circuit network tick handler
	on_circuit_network_tick(event)

	-- Krastorio2 antimatter reactor tracking (only if mod is loaded)
	if script.active_mods["Krastorio2-spaced-out"] then
		gauge_kr_antimatter_reactors:reset()
		for _, surface in pairs(game.surfaces) do
			local reactors = surface.find_entities_filtered({ name = "kr-antimatter-reactor" })
			if reactors and #reactors > 0 then
				-- Count reactors by force
				--- @type table<string, integer>
				local reactor_count_by_force = {}
				for _, reactor in pairs(reactors) do
					if reactor.valid then
						local force_name = reactor.force.name
						reactor_count_by_force[force_name] = (reactor_count_by_force[force_name] or 0) + 1
					end
				end
				-- Set gauge for each force
				for force_name, count in pairs(reactor_count_by_force) do
					gauge_kr_antimatter_reactors:set(count, { force_name, surface.name })
				end
			end
		end
	end
end

--- Phase 9: Serialize metrics and write .prom file
local function export_metrics()
	if server_save then
		helpers.write_file("graftorio2/game.prom", prometheus.collect(), false, 0)
	else
		helpers.write_file("graftorio2/game.prom", prometheus.collect(), false)
	end
end

-- ============================================================================
-- Phase dispatch table
-- ============================================================================

--- Phase dispatch: maps collection_phase number to the function to execute.
--- Phases 2–5 don't need the event; phases 6–8 pass it through for tick guards.
--- @type table<integer, fun(event: EventData)>
local phase_dispatch = {
	[2] = function(_event) collect_production() end,
	[3] = function(_event) collect_military() end,
	[4] = function(_event) collect_evolution() end,
	[5] = function(_event) collect_logistics() end,
	[6] = function(event) collect_research_platforms(event) end,
	[7] = function(event) collect_power(event) end,
	[8] = function(event) collect_circuits(event) end,
	[9] = function(_event) export_metrics() end,
}

-- ============================================================================
-- Event handlers
-- ============================================================================

--- Main nth-tick event handler. Starts a new collection cycle (Phase 1) and sets
--- collection_phase so that subsequent on_tick calls execute phases 2–9.
--- Re-entry guard: if a collection is already in progress, skip.
--- @param event NthTickEventData
function register_events(event)
	-- Re-entry guard: skip if a collection cycle is already in progress
	if collection_phase > 0 then
		return
	end

	-- Phase 1: globals (tick, seeds, mods, pollution)
	collect_globals()

	-- Start the phased collection cycle
	collection_phase = 2
end

--- On-tick handler for phased collection. Executes one phase per tick.
--- Fast path: returns immediately if no collection is in progress (collection_phase == 0).
--- @param event EventData.on_tick
function collection_tick(event)
	if collection_phase == 0 then
		return
	end

	local phase_fn = phase_dispatch[collection_phase]
	if phase_fn then
		phase_fn(event)
	end

	-- Advance to next phase, or reset to idle after phase 9
	if collection_phase >= 9 then
		collection_phase = 0
	else
		collection_phase = collection_phase + 1
	end
end

--- Handle player join/leave/kick/ban/remove events. Updates connected and total player count gauges.
--- @param event EventData.on_player_joined_game|EventData.on_player_left_game|EventData.on_player_removed|EventData.on_player_kicked|EventData.on_player_banned
function register_events_players(event)
	gauge_connected_player_count:set(#game.connected_players)
	gauge_total_player_count:set(#game.players)
end
