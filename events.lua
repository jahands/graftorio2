-- events.lua
-- Main metric collection event handler
-- Spreads metric collection across multiple game ticks to amortize cost
-- Per-surface phases process one surface per tick for maximum granularity
--
-- Phase 1:  globals (tick, seeds, mods) — single tick
-- Phase 2:  pollution stats — per surface
-- Phase 3:  item production stats — per surface
-- Phase 4:  fluid production stats — per surface
-- Phase 5:  kill + entity build count stats — per surface
-- Phase 6:  evolution factors + items launched — per surface
-- Phase 7:  logistic networks — per surface
-- Phase 8:  research queue + Space Age platforms — single tick
-- Phase 9:  power prepare (rescan, cleanup, reset, group) — resumable
-- Phase 10: power network stats — per surface
-- Phase 11: circuit prepare (rescan, reset, group) — resumable
-- Phase 12: circuit network signals + K2 reactors — per surface
-- Phase 13: serialize metrics — single tick
-- Phase 14: write .prom file — single tick
--
-- Total ticks per cycle is now 8 + 8×S plus any extra ticks needed to finish
-- the resumable power/circuit prepare phases on large saves.

-- ============================================================================
-- Module-local state (resets on save/load — not persisted in storage)
-- ============================================================================

local collection_phase = 0
local cached_surfaces = {}      -- array of LuaSurface, snapshot captured at cycle start
local surface_idx = 0           -- current position within cached_surfaces for per-surface phases
local serialized_metrics = nil  -- holds prometheus.collect() output between serialize and write phases

-- Phase constants
local PHASE_IDLE = 0
local PHASE_GLOBALS = 1                -- single tick
local PHASE_POLLUTION = 2              -- per surface
local PHASE_ITEM_PRODUCTION = 3        -- per surface
local PHASE_FLUID_PRODUCTION = 4       -- per surface
local PHASE_MILITARY = 5               -- per surface
local PHASE_EVOLUTION = 6              -- per surface
local PHASE_LOGISTICS = 7              -- per surface
local PHASE_RESEARCH_PLATFORMS = 8     -- single tick
local PHASE_POWER_PREPARE = 9          -- resumable
local PHASE_POWER = 10                 -- per surface
local PHASE_CIRCUITS_PREPARE = 11      -- resumable
local PHASE_CIRCUITS = 12              -- per surface
local PHASE_SERIALIZE = 13             -- single tick
local PHASE_WRITE_FILE = 14            -- single tick
local PHASE_MAX = 14

-- Set of phases that iterate one surface per tick
local per_surface_phase = {
	[PHASE_POLLUTION] = true,
	[PHASE_ITEM_PRODUCTION] = true,
	[PHASE_FLUID_PRODUCTION] = true,
	[PHASE_MILITARY] = true,
	[PHASE_EVOLUTION] = true,
	[PHASE_LOGISTICS] = true,
	[PHASE_POWER] = true,
	[PHASE_CIRCUITS] = true,
}

-- ============================================================================
-- Helpers
-- ============================================================================

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

--- Phase 1: Globals — game tick, seeds, mods (single tick).
local function collect_globals()
	gauge_tick:set(game.tick)

	for _, surface in pairs(game.surfaces) do
		gauge_seed:set(surface.map_gen_settings.seed, { surface.name })
	end

	for name, version in pairs(script.active_mods) do
		gauge_mods:set(1, { name, version })
	end
end

--- Phase 2: Pollution stats for a single surface.
--- @param surface LuaSurface
local function collect_pollution_surface(surface)
	local stats = game.get_pollution_statistics(surface)
	for name, n in pairs(stats.input_counts) do
		gauge_pollution_production_input:set(n, { name, surface.name })
	end
	for name, n in pairs(stats.output_counts) do
		gauge_pollution_production_output:set(n, { name, surface.name })
	end
end

--- Phase 3: Item production stats for a single surface (all forces).
--- @param surface LuaSurface
local function collect_item_production_surface(surface)
	for_each_force(function(player)
		local stat = player.force.get_item_production_statistics(surface)
		for name, n in pairs(stat.input_counts) do
			gauge_item_production_input:set(n, { player.force.name, name, surface.name })
		end
		for name, n in pairs(stat.output_counts) do
			gauge_item_production_output:set(n, { player.force.name, name, surface.name })
		end
	end)
end

--- Phase 4: Fluid production stats for a single surface (all forces).
--- @param surface LuaSurface
local function collect_fluid_production_surface(surface)
	for_each_force(function(player)
		local stat = player.force.get_fluid_production_statistics(surface)
		for name, n in pairs(stat.input_counts) do
			gauge_fluid_production_input:set(n, { player.force.name, name, surface.name })
		end
		for name, n in pairs(stat.output_counts) do
			gauge_fluid_production_output:set(n, { player.force.name, name, surface.name })
		end
	end)
end

--- Phase 5: Kill counts + entity build counts for a single surface (all forces).
--- @param surface LuaSurface
local function collect_military_surface(surface)
	for_each_force(function(player)
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
	end)
end

--- Phase 6: Evolution factors + items launched for a single surface (all forces).
--- @param surface LuaSurface
local function collect_evolution_surface(surface)
	for_each_force(function(player)
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
	end)
end

--- Phase 7: Logistic networks for a single surface (all forces).
--- Resets logistic gauges on the first surface of the phase (surface_idx == 1).
--- @param surface LuaSurface
local function collect_logistics_surface(surface)
	-- Reset logistic gauges once at the start of the logistics phase
	if surface_idx == 1 then
		gauge_logistic_network_all_logistic_robots:reset()
		gauge_logistic_network_available_logistic_robots:reset()
		gauge_logistic_network_all_construction_robots:reset()
		gauge_logistic_network_available_construction_robots:reset()
		gauge_logistic_network_robot_limit:reset()
		gauge_logistic_network_items:reset()
	end

	for_each_force(function(player)
		local networks = player.force.logistic_networks[surface.name]
		if networks then
			for _, network in ipairs(networks) do
				local network_id = tostring(network.network_id)
				gauge_logistic_network_all_logistic_robots:set(
					network.all_logistic_robots,
					{ player.force.name, surface.name, network_id }
				)
				gauge_logistic_network_available_logistic_robots:set(
					network.available_logistic_robots,
					{ player.force.name, surface.name, network_id }
				)
				gauge_logistic_network_all_construction_robots:set(
					network.all_construction_robots,
					{ player.force.name, surface.name, network_id }
				)
				gauge_logistic_network_available_construction_robots:set(
					network.available_construction_robots,
					{ player.force.name, surface.name, network_id }
				)
				gauge_logistic_network_robot_limit:set(network.robot_limit, { player.force.name, surface.name, network_id })
				-- Cache get_contents() call to avoid calling expensive API twice
				local contents = network.get_contents()
				if contents ~= nil then
					for _, entry in ipairs(contents) do
						local quality_name = entry.quality and entry.quality.name or "normal" ---@diagnostic disable-line: undefined-field -- quality.name exists at runtime
						gauge_logistic_network_items:set(entry.count, { player.force.name, surface.name, network_id, entry.name, quality_name })
					end
				end
			end
		end
	end)
end

--- Phase 8: Research queue + Space Age platforms (single tick, per force).
--- @param event EventData
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

--- Phase 9: Power prepare — rescan, cleanup, reset gauges, group networks by surface.
--- @param event EventData
local function collect_power_prepare(event)
	return on_power_tick_prepare(event)
end

--- Phase 10: Power network stats for a single surface.
--- @param surface LuaSurface
local function collect_power_surface(surface)
	on_power_tick_surface(surface)
end

--- Phase 11: Circuit prepare — rescan, reset gauges, group combinators by surface.
--- Also resets Krastorio2 gauge if the mod is loaded.
--- @param event EventData
local function collect_circuits_prepare(event)
	local done = on_circuit_network_tick_prepare(event)

	-- Reset K2 gauge before per-surface collection
	if script.active_mods["Krastorio2-spaced-out"] then
		gauge_kr_antimatter_reactors:reset()
	end

	return done
end

--- Phase 12: Circuit network signals + Krastorio2 reactors for a single surface.
--- @param surface LuaSurface
local function collect_circuits_surface(surface)
	on_circuit_network_tick_surface(surface)

	-- Krastorio2 antimatter reactor tracking for this surface
	if script.active_mods["Krastorio2-spaced-out"] then
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

--- Phase 13: Serialize all metrics into a string (single tick).
local function serialize_metrics()
	serialized_metrics = prometheus.collect()
end

--- Phase 14: Write the serialized .prom file (single tick).
local function write_metrics_file()
	if serialized_metrics then
		if server_save then
			helpers.write_file("graftorio2/game.prom", serialized_metrics, false, 0)
		else
			helpers.write_file("graftorio2/game.prom", serialized_metrics, false)
		end
		serialized_metrics = nil
	end
end

-- ============================================================================
-- Dispatch tables
-- ============================================================================

--- Per-surface phase dispatch: maps phase number to function(surface).
--- @type table<integer, fun(surface: LuaSurface)>
local surface_phase_dispatch = {
	[PHASE_POLLUTION] = collect_pollution_surface,
	[PHASE_ITEM_PRODUCTION] = collect_item_production_surface,
	[PHASE_FLUID_PRODUCTION] = collect_fluid_production_surface,
	[PHASE_MILITARY] = collect_military_surface,
	[PHASE_EVOLUTION] = collect_evolution_surface,
	[PHASE_LOGISTICS] = collect_logistics_surface,
	[PHASE_POWER] = collect_power_surface,
	[PHASE_CIRCUITS] = collect_circuits_surface,
}

--- Resumable phase dispatch: maps phase number to function(event) -> done.
--- @type table<integer, fun(event: EventData): boolean>
local resumable_phase_dispatch = {
	[PHASE_POWER_PREPARE] = collect_power_prepare,
	[PHASE_CIRCUITS_PREPARE] = collect_circuits_prepare,
}

--- Single-tick phase dispatch: maps phase number to function(event).
--- @type table<integer, fun(event: EventData)>
local single_phase_dispatch = {
	[PHASE_GLOBALS] = collect_globals,
	[PHASE_RESEARCH_PLATFORMS] = collect_research_platforms,
	[PHASE_SERIALIZE] = serialize_metrics,
	[PHASE_WRITE_FILE] = write_metrics_file,
}

-- ============================================================================
-- Event handlers
-- ============================================================================

--- Main nth-tick event handler. Starts a new collection cycle.
--- Snapshots the surface list and sets collection_phase to 1 so that
--- collection_tick begins executing phases on subsequent ticks.
--- Re-entry guard: if a collection is already in progress, skip.
--- @param event NthTickEventData
function register_events(event)
	-- Re-entry guard: skip if a collection cycle is already in progress
	if collection_phase > PHASE_IDLE then
		return
	end

	-- Snapshot the surface list for this cycle (stable across all per-surface phases)
	cached_surfaces = {}
	for _, surface in pairs(game.surfaces) do
		cached_surfaces[#cached_surfaces + 1] = surface
	end
	surface_idx = 1

	-- Start the phased collection cycle
	collection_phase = PHASE_GLOBALS
end

--- On-tick handler for phased collection. Executes one phase (or one surface of a
--- per-surface phase) per tick.
--- Fast path: returns immediately if no collection is in progress (collection_phase == 0).
--- @param event EventData.on_tick
function collection_tick(event)
	if collection_phase == PHASE_IDLE then
		return
	end

	if per_surface_phase[collection_phase] then
		-- Per-surface phase: process one surface this tick
		local surface = cached_surfaces[surface_idx]
		if surface and surface.valid then
			surface_phase_dispatch[collection_phase](surface)
		end

		if surface_idx >= #cached_surfaces then
			-- All surfaces done for this phase, advance to next phase
			surface_idx = 1
			collection_phase = collection_phase + 1
		else
			-- More surfaces remain, stay in this phase
			surface_idx = surface_idx + 1
		end
	elseif resumable_phase_dispatch[collection_phase] then
		-- Resumable phase: stay in this phase until the worker reports completion
		if resumable_phase_dispatch[collection_phase](event) then
			collection_phase = collection_phase + 1
		end
	else
		-- Single-tick phase: execute and advance
		local phase_fn = single_phase_dispatch[collection_phase]
		if phase_fn then
			phase_fn(event)
		end
		collection_phase = collection_phase + 1
	end

	-- Check if all phases are complete
	if collection_phase > PHASE_MAX then
		collection_phase = PHASE_IDLE
		cached_surfaces = {}
		surface_idx = 0
	end
end

--- Handle player join/leave/kick/ban/remove events. Updates connected and total player count gauges.
--- @param event EventData.on_player_joined_game|EventData.on_player_left_game|EventData.on_player_removed|EventData.on_player_kicked|EventData.on_player_banned
function register_events_players(event)
	gauge_connected_player_count:set(#game.connected_players)
	gauge_total_player_count:set(#game.players)
end
