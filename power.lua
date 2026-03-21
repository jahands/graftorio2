-- power.lua
-- Tracks electric network statistics for Prometheus export
-- Maintains state of electric producers/consumers with caching optimizations
-- Handles power switches and ignored networks

-- Constants
local FAILED_LOOKUP_BACKOFF_TICKS = 600  -- 10 seconds (at 60 ticks/second)
local CLEANUP_INTERVAL_TICKS = 3600      -- 1 minute
local PREPARE_SWITCHES_PER_TICK = 64
local PREPARE_FAILED_LOOKUPS_PER_TICK = 128
local PREPARE_NETWORKS_PER_TICK = 128
local PREPARE_RESCAN_SURFACES_PER_TICK = 1

--- @class PowerNetworkEntry
--- @field entity_number uint Unit number of the representative electric pole
--- @field prev {input: table<string, number>, output: table<string, number>} Previous tick's statistics

--- @class PowerPrepareState
--- @field stage string
--- @field surfaces LuaSurface[]
--- @field surface_idx integer
--- @field switch_ids uint[]
--- @field switch_idx integer
--- @field failed_lookup_ids uint[]
--- @field failed_lookup_idx integer
--- @field network_ids uint[]
--- @field network_idx integer
--- @field cleanup_threshold uint?
--- @field ignored table<uint, boolean>
--- @field by_surface table<string, {idx: uint, entity: LuaEntity}[]>

--- @class PowerScriptData
--- @field has_checked boolean Whether the initial world rescan has been performed this session
--- @field networks table<uint, PowerNetworkEntry> Electric network ID -> network entry
--- @field switches table<uint, integer> Power switch tracking (unit_number -> 1 sentinel)
--- @field ignored_networks_cache table<uint, boolean>? Cached set of network IDs to ignore (behind power switches)
--- @field ignored_networks_dirty boolean Whether the ignored networks cache needs recalculation
--- @field failed_lookups table<uint, uint> Entity unit_number -> tick of last failed lookup (for backoff)
--- @field _networks_by_surface table<string, {idx: uint, entity: LuaEntity}[]>? Pre-grouped networks by surface name (set during prepare phase)
--- @field _prepare PowerPrepareState? Runtime state for resumable prepare work
--- @field _live_ignored_tick uint? Tick when `_live_ignored` was last rebuilt
--- @field _live_ignored table<uint, boolean>? Ignored networks rebuilt for the current tick

--- @type PowerScriptData
local script_data = {
	has_checked = false,
	networks = {},
	switches = {},
	ignored_networks_cache = nil,
	ignored_networks_dirty = true,
	failed_lookups = {},
}

--- @type table<uint, LuaEntity> Runtime entity cache (unit_number -> entity), rebuilt on load
local map = {}

--- Create or update a network entry for the given electric pole entity.
--- @param entity LuaEntity An electric pole entity
local function new_entity_entry(entity)
	---@type PowerNetworkEntry
	local base = {
		entity_number = entity.unit_number,
		prev = { input = {}, output = {} },
	}
	if script_data.networks[entity.electric_network_id] then
		base.prev = script_data.networks[entity.electric_network_id].prev
	end
	script_data.networks[entity.electric_network_id] = base
	map[entity.unit_number] = entity
end

--- Find an entity by unit number, using the local cache or falling back to surface search.
--- @param unit_number uint
--- @param entity_type string Entity prototype type to filter by
--- @return LuaEntity?
local function find_entity(unit_number, entity_type)
	if map[unit_number] then
		local entity = map[unit_number]
		if entity.valid then
			return entity
		end
		map[unit_number] = nil
	end

	for _, surface in pairs(game.surfaces) do
		local ents = surface.find_entities_filtered({ type = entity_type })
		for _, entity in pairs(ents) do
			if entity.unit_number == unit_number then
				map[entity.unit_number] = entity
				return entity
			end
		end
	end
end

--- @param tbl table<uint, any>
--- @return uint[]
local function collect_uint_keys(tbl)
	---@type uint[]
	local keys = {}
	for key, _ in pairs(tbl) do
		keys[#keys + 1] = key
	end
	return keys
end

--- Rebuild the set of ignored networks from tracked power switches.
--- @return table<uint, boolean>
local function rebuild_ignored_networks()
	---@type table<uint, boolean>
	local ignored = {}
	local max = math.max
	for switch_id, _ in pairs(script_data.switches) do
		local switch = find_entity(switch_id, "power-switch")
		if not switch or not switch.valid then
			script_data.switches[switch_id] = nil
		elseif switch.power_switch_state and #switch.neighbours.copper > 1 then
			local network =
				max(switch.neighbours.copper[1].electric_network_id, switch.neighbours.copper[2].electric_network_id)
			ignored[network] = true
		end
	end
	script_data.ignored_networks_cache = ignored
	script_data.ignored_networks_dirty = false
	return ignored
end

--- @return table<uint, boolean>
local function get_live_ignored_networks()
	if script_data._live_ignored_tick == game.tick and script_data._live_ignored then
		return script_data._live_ignored
	end

	local ignored = rebuild_ignored_networks()
	script_data._live_ignored = ignored
	script_data._live_ignored_tick = game.tick
	return ignored
end

local function reset_prepare_state()
	script_data._prepare = nil
	script_data._networks_by_surface = nil
end

--- @param event_tick uint
local function begin_power_prepare(event_tick)
	gauge_power_production_input:reset()
	gauge_power_production_output:reset()
	reset_prepare_state()

	---@type LuaSurface[]
	local surfaces = {}
	for _, surface in pairs(game.surfaces) do
		surfaces[#surfaces + 1] = surface
	end

	---@type PowerPrepareState
	local state = {
		stage = script_data.has_checked and "ignored" or "rescan",
		surfaces = surfaces,
		surface_idx = 1,
		switch_ids = {},
		switch_idx = 1,
		failed_lookup_ids = {},
		failed_lookup_idx = 1,
		network_ids = {},
		network_idx = 1,
		cleanup_threshold = event_tick % CLEANUP_INTERVAL_TICKS == 0 and event_tick - CLEANUP_INTERVAL_TICKS or nil,
		ignored = {},
		by_surface = {},
	}

	if not script_data.has_checked then
		script_data.networks = {}
		script_data.switches = {}
		map = {}
	end

	script_data._prepare = state
end

--- @param state PowerPrepareState
--- @return boolean
local function step_power_rescan(state)
	local processed = 0
	while processed < PREPARE_RESCAN_SURFACES_PER_TICK and state.surface_idx <= #state.surfaces do
		local surface = state.surfaces[state.surface_idx]
		if surface and surface.valid then
			for _, entity in pairs(surface.find_entities_filtered({ type = "electric-pole" })) do
				new_entity_entry(entity)
			end
			for _, entity in pairs(surface.find_entities_filtered({ type = "power-switch" })) do
				script_data.switches[entity.unit_number] = 1
				map[entity.unit_number] = entity
			end
		end
		state.surface_idx = state.surface_idx + 1
		processed = processed + 1
	end

	if state.surface_idx > #state.surfaces then
		script_data.has_checked = true
		script_data.ignored_networks_dirty = true
		state.switch_ids = collect_uint_keys(script_data.switches)
		state.switch_idx = 1
		state.stage = "ignored"
		return true
	end

	return false
end

--- @param state PowerPrepareState
--- @return boolean
local function step_power_ignored(state)
	if #state.switch_ids == 0 then
		state.switch_ids = collect_uint_keys(script_data.switches)
	end

	local processed = 0
	local max = math.max
	while processed < PREPARE_SWITCHES_PER_TICK and state.switch_idx <= #state.switch_ids do
		local switch_id = state.switch_ids[state.switch_idx]
		local switch = find_entity(switch_id, "power-switch")
		if not switch or not switch.valid then
			script_data.switches[switch_id] = nil
		elseif switch.power_switch_state and #switch.neighbours.copper > 1 then
			local network =
				max(switch.neighbours.copper[1].electric_network_id, switch.neighbours.copper[2].electric_network_id)
			state.ignored[network] = true
		end
		state.switch_idx = state.switch_idx + 1
		processed = processed + 1
	end

	if state.switch_idx > #state.switch_ids then
		script_data.ignored_networks_cache = state.ignored
		script_data.ignored_networks_dirty = false
		state.failed_lookup_ids = collect_uint_keys(script_data.failed_lookups)
		state.failed_lookup_idx = 1
		if state.cleanup_threshold then
			state.stage = "cleanup"
		else
			state.network_ids = collect_uint_keys(script_data.networks)
			state.network_idx = 1
			state.stage = "group"
		end
		return true
	end

	return false
end

--- @param state PowerPrepareState
--- @return boolean
local function step_power_cleanup(state)
	local processed = 0
	while processed < PREPARE_FAILED_LOOKUPS_PER_TICK and state.failed_lookup_idx <= #state.failed_lookup_ids do
		local entity_number = state.failed_lookup_ids[state.failed_lookup_idx]
		local failed_tick = script_data.failed_lookups[entity_number]
		if failed_tick and failed_tick < state.cleanup_threshold then
			script_data.failed_lookups[entity_number] = nil
		end
		state.failed_lookup_idx = state.failed_lookup_idx + 1
		processed = processed + 1
	end

	if state.failed_lookup_idx > #state.failed_lookup_ids then
		state.network_ids = collect_uint_keys(script_data.networks)
		state.network_idx = 1
		state.stage = "group"
		return true
	end

	return false
end

--- @param state PowerPrepareState
--- @return boolean
local function step_power_group(state)
	local processed = 0
	while processed < PREPARE_NETWORKS_PER_TICK and state.network_idx <= #state.network_ids do
		local idx = state.network_ids[state.network_idx]
		local network = script_data.networks[idx]
		if network and not (script_data.failed_lookups[network.entity_number] and game.tick - script_data.failed_lookups[network.entity_number] < FAILED_LOOKUP_BACKOFF_TICKS) then
			local entity = find_entity(network.entity_number, "electric-pole")
			if not entity then
				script_data.failed_lookups[network.entity_number] = game.tick
				script_data.networks[idx] = nil
			elseif entity.valid then
				local current_idx = entity.electric_network_id
				if current_idx ~= idx then
					script_data.networks[idx] = nil
					new_entity_entry(entity)
				else
					script_data.failed_lookups[network.entity_number] = nil
					local surface_name = entity.surface.name
					if not state.by_surface[surface_name] then state.by_surface[surface_name] = {} end
					state.by_surface[surface_name][#state.by_surface[surface_name] + 1] = { idx = idx, entity = entity }
				end
			else
				script_data.networks[idx] = nil
			end
		end

		state.network_idx = state.network_idx + 1
		processed = processed + 1
	end

	if state.network_idx > #state.network_ids then
		script_data._networks_by_surface = state.by_surface
		script_data._prepare = nil
		script_data._live_ignored_tick = nil
		script_data._live_ignored = nil
		return true
	end

	return false
end

--- Handle entity build events for electric poles and power switches.
--- @param event EventData.on_built_entity|EventData.on_robot_built_entity|EventData.script_raised_built
function on_power_build(event)
	local entity = event.entity
	if entity and entity.type == "electric-pole" then
		if not script_data.networks[entity.electric_network_id] then
			new_entity_entry(entity)
		end
	elseif entity and entity.type == "power-switch" then
		script_data.switches[entity.unit_number] = 1
		map[entity.unit_number] = entity
		-- Invalidate ignored networks cache when switch is built
		script_data.ignored_networks_dirty = true
		script_data._live_ignored_tick = nil
		script_data._live_ignored = nil
	end
end

--- Handle entity destroy events for electric poles and power switches.
--- When an electric pole is destroyed, updates neighboring network entries.
--- @param event EventData.on_player_mined_entity|EventData.on_robot_mined_entity|EventData.on_entity_died|EventData.script_raised_destroy
function on_power_destroy(event)
	local entity = event.entity
	if entity.type == "electric-pole" then
		local pos = entity.position
		local max = entity.prototype.get_max_wire_distance()
		local area = { { pos.x - max, pos.y - max }, { pos.x + max, pos.y + max } }
		local surface = entity.surface
		local networks = script_data.networks
		local current_idx = entity.electric_network_id
		-- Make sure to create the new network ids before collecting new info
		if entity.neighbours.copper and event.damage_type == nil then
			entity.disconnect_neighbour() ---@diagnostic disable-line: undefined-field -- Factorio API method not in stubs
		end
		local finds = surface.find_entities_filtered({ type = "electric-pole", area = area })
		for _, new_entity in pairs(finds) do
			if new_entity ~= entity then
				if new_entity.electric_network_id == current_idx or not networks[new_entity.electric_network_id] then
					-- here we need to add the new_entity
					new_entity_entry(new_entity)
				end
			end
		end
	elseif entity.type == "power-switch" then
		script_data.switches[entity.unit_number] = nil
		-- Invalidate ignored networks cache when switch is destroyed
		script_data.ignored_networks_dirty = true
		script_data._live_ignored_tick = nil
		script_data._live_ignored = nil
	end

	-- if some unexpected stuff occurs, try enabling rescan_worlds
	-- rescan_worlds()
end

--- Restore power tracking state after a save/load cycle.
--- Resets runtime-only flags; entity cache (`map`) is rebuilt lazily during prepare.
function on_power_load()
	script_data.has_checked = false
	script_data.ignored_networks_dirty = true
	script_data.ignored_networks_cache = nil
	reset_prepare_state()
	script_data._live_ignored_tick = nil
	script_data._live_ignored = nil
end

--- Initialize power tracking state for a new game.
function on_power_init()
	script_data.has_checked = false
	script_data.ignored_networks_dirty = true
	script_data.ignored_networks_cache = nil
	script_data.failed_lookups = {}
	reset_prepare_state()
	script_data._live_ignored_tick = nil
	script_data._live_ignored = nil
end

--- Prepare power network data for per-surface collection.
--- Runs as a resumable worker and returns true when the prepare phase is complete.
--- @param event EventData|NthTickEventData
--- @return boolean
function on_power_tick_prepare(event)
	if not event.tick then return true end

	if not script_data._prepare then
		begin_power_prepare(event.tick)
	end

	local state = script_data._prepare
	if not state then return true end

	if state.stage == "rescan" then
		return step_power_rescan(state)
	elseif state.stage == "ignored" then
		return step_power_ignored(state)
	elseif state.stage == "cleanup" then
		return step_power_cleanup(state)
	elseif state.stage == "group" then
		return step_power_group(state)
	end

	return true
end

--- Collect electric network statistics for a single surface.
--- Must be called after on_power_tick_prepare() for the current cycle.
--- @param surface LuaSurface
function on_power_tick_surface(surface)
	local networks = script_data._networks_by_surface and script_data._networks_by_surface[surface.name]
	if not networks then return end
	local ignored = get_live_ignored_networks()

	for _, entry in ipairs(networks) do
		local entity = entry.entity
		local idx = entry.idx
		-- Re-validate entity in case it was destroyed between prepare and this tick
		if entity.valid then
			local current_idx = entity.electric_network_id
			if entity.surface == surface and current_idx == idx and not ignored[current_idx] then
				local force_name = entity.force.name
				local surface_name = entity.surface.name
				for name, n in pairs(entity.electric_network_statistics.input_counts) do
					gauge_power_production_input:set(n, { force_name, name, idx, surface_name })
				end
				for name, n in pairs(entity.electric_network_statistics.output_counts) do
					gauge_power_production_output:set(n, { force_name, name, idx, surface_name })
				end
			elseif current_idx ~= idx then
				script_data.networks[idx] = nil
				new_entity_entry(entity)
			end
		else
			script_data.networks[idx] = nil
		end
	end
end

--- Collect electric network statistics (monolithic). Delegates to prepare + per-surface.
--- Kept for backward compatibility; events.lua calls the granular functions directly.
--- @param event NthTickEventData
function on_power_tick(event)
	while not on_power_tick_prepare(event) do end
	if event.tick then
		for _, surface in pairs(game.surfaces) do
			on_power_tick_surface(surface)
		end
	end
end
