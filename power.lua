-- power.lua
-- Tracks electric network statistics for Prometheus export
-- Maintains state of electric producers/consumers with caching optimizations
-- Handles power switches and ignored networks

-- Constants
local FAILED_LOOKUP_BACKOFF_TICKS = 600  -- 10 seconds (at 60 ticks/second)
local CLEANUP_INTERVAL_TICKS = 3600      -- 1 minute

--- @class PowerNetworkEntry
--- @field entity_number uint Unit number of the representative electric pole
--- @field prev {input: table<string, number>, output: table<string, number>} Previous tick's statistics

--- @class PowerScriptData
--- @field has_checked boolean Whether the initial world rescan has been performed this session
--- @field networks table<uint, PowerNetworkEntry> Electric network ID -> network entry
--- @field switches table<uint, integer|LuaEntity> Power switch tracking (unit_number -> 1 sentinel or legacy entity ref)
--- @field ignored_networks_cache table<uint, boolean>? Cached set of network IDs to ignore (behind power switches)
--- @field ignored_networks_dirty boolean Whether the ignored networks cache needs recalculation
--- @field failed_lookups table<uint, uint> Entity unit_number -> tick of last failed lookup (for backoff)

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
	--- @type PowerNetworkEntry
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
		return map[unit_number]
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

--- Rebuild the entity cache by rescanning all surfaces for electric poles.
--- Cleans up invalid or orphaned network entries.
local function rescan_worlds()
	local networks = script_data.networks
	--- @type table<uint, boolean>
	local invalids = {}
	--- @type table<uint, boolean>
	local remove = {}
	for idx, network in pairs(networks) do
		if network.entity then
			network.entity_number = network.entity.unit_number
			network.entity = nil
		end

		if network.entity_number then
			local assoc = find_entity(network.entity_number, "electric-pole")
			if not assoc then
				invalids[idx] = true
			end
		else
			remove[idx] = true
		end
	end
	for _, surface in pairs(game.surfaces) do
		local ents = surface.find_entities_filtered({ type = "electric-pole" })
		for _, entity in pairs(ents) do
			if not networks[entity.electric_network_id] or invalids[entity.electric_network_id] then
				new_entity_entry(entity)
				invalids[entity.electric_network_id] = nil
			end
		end
	end

	if table_size(remove) > 0 then
		for idx, _ in pairs(remove) do
			networks[idx] = nil
		end
	end
end

--- Get the set of electric network IDs that should be ignored (networks behind power switches).
--- Uses a dirty-flag cache to avoid recalculating every tick.
--- @return table<uint, boolean> ignored Set of network IDs to skip
local function get_ignored_networks_by_switches()
	-- Return cached result if not dirty
	if not script_data.ignored_networks_dirty and script_data.ignored_networks_cache then
		return script_data.ignored_networks_cache
	end

	-- Recalculate ignored networks
	--- @type table<uint, boolean>
	local ignored = {}
	local max = math.max
	for switch_id, val in pairs(script_data.switches) do
		-- assume old entity
		if val ~= 1 and val and val.valid then
			script_data.switches[val.unit_number] = 1
			script_data.switches[switch_id] = nil
		end
		local switch = find_entity(switch_id, "power-switch")
		if switch and switch.power_switch_state and #switch.neighbours.copper > 1 then
			local network =
				max(switch.neighbours.copper[1].electric_network_id, switch.neighbours.copper[2].electric_network_id)
			ignored[network] = true
		end
	end

	-- Cache the result
	script_data.ignored_networks_cache = ignored
	script_data.ignored_networks_dirty = false
	return ignored
end

--- Handle entity build events for electric poles and power switches.
--- @param event EventData.on_built_entity|EventData.on_robot_built_entity|EventData.script_raised_built
function on_power_build(event)
	local entity = event.entity or event.created_entity
	if entity and entity.type == "electric-pole" then
		if not script_data.networks[entity.electric_network_id] then
			new_entity_entry(entity)
		end
	elseif entity and entity.type == "power-switch" then
		script_data.switches[entity.unit_number] = 1
		map[entity.unit_number] = entity
		-- Invalidate ignored networks cache when switch is built
		script_data.ignored_networks_dirty = true
	end
end

--- Handle entity destroy events for electric poles and power switches.
--- When an electric pole is destroyed, updates neighboring network entries.
--- @param event EventData.on_player_mined_entity|EventData.on_robot_mined_entity|EventData.on_entity_died|EventData.script_raised_destroy
function on_power_destroy(event)
	local entity = event.entity
	if entity.type == "electric-pole" then
		local pos = entity.position
		local max = entity.prototype and entity.prototype.max_wire_distance
			or game.max_electric_pole_connection_distance
		local area = { { pos.x - max, pos.y - max }, { pos.x + max, pos.y + max } }
		local surface = entity.surface
		local networks = script_data.networks
		local current_idx = entity.electric_network_id
		-- Make sure to create the new network ids before collecting new info
		if entity.neighbours.copper and event.damage_type == nil then
			entity.disconnect_neighbour()
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
	end

	-- if some unexpected stuff occurs, try enabling rescan_worlds
	-- rescan_worlds()
end

--- Restore power tracking state after a save/load cycle.
--- Resets runtime-only flags; entity cache (`map`) is rebuilt lazily via `rescan_worlds()`.
function on_power_load()
	script_data.has_checked = false
	script_data.ignored_networks_dirty = true
	script_data.ignored_networks_cache = nil
end

--- Initialize power tracking state for a new game.
function on_power_init()
	script_data.has_checked = false
	script_data.ignored_networks_dirty = true
	script_data.ignored_networks_cache = nil
	script_data.failed_lookups = {}
end

--- Collect electric network statistics. Called every nth-tick from events.lua.
--- Iterates all tracked networks, looks up their representative entity, and exports
--- input/output power statistics per force, network, and surface.
--- @param event EventData.on_nth_tick
function on_power_tick(event)
	if event.tick then
		local ignored = get_ignored_networks_by_switches()

		if not script_data.has_checked then
			rescan_worlds()
			script_data.has_checked = true
		end

		-- Periodic cleanup of failed lookups
		if event.tick % CLEANUP_INTERVAL_TICKS == 0 then
			local cleanup_threshold = event.tick - CLEANUP_INTERVAL_TICKS
			for entity_number, failed_tick in pairs(script_data.failed_lookups) do
				if failed_tick < cleanup_threshold then
					script_data.failed_lookups[entity_number] = nil
				end
			end
		end

		gauge_power_production_input:reset()
		gauge_power_production_output:reset()

		for idx, network in pairs(script_data.networks) do
			-- reset old style in case it still is old
			if network.entity then
				network.entity_number = network.entity.unit_number
				network.entity = nil
			end

			-- Check if this entity has failed lookups recently
			if script_data.failed_lookups[network.entity_number] and
			   event.tick - script_data.failed_lookups[network.entity_number] < FAILED_LOOKUP_BACKOFF_TICKS then
				goto skip_network
			end

			local entity = find_entity(network.entity_number, "electric-pole")

			if not entity then
				-- Mark as failed lookup and remove invalid network instead of rescanning
				script_data.failed_lookups[network.entity_number] = event.tick
				script_data.networks[idx] = nil
				goto skip_network
			end

			if
				entity
				and entity.valid
				and not ignored[entity.electric_network_id]
				and entity.electric_network_id == idx
			then
				-- Clear failed lookup tracking if entity is found and valid
				script_data.failed_lookups[network.entity_number] = nil
				local force_name = entity.force.name
				local surface_name = entity.surface.name
				for name, n in pairs(entity.electric_network_statistics.input_counts) do
					gauge_power_production_input:set(n, { force_name, name, idx, surface_name })
				end
				for name, n in pairs(entity.electric_network_statistics.output_counts) do
					gauge_power_production_output:set(n, { force_name, name, idx, surface_name })
				end
			elseif entity and entity.valid and entity.electric_network_id ~= idx then
				-- assume this network has been merged with some other so unset
				script_data.networks[idx] = nil
			elseif entity and not entity.valid then
				-- Invalid entity remove anyhow
				script_data.networks[idx] = nil
			end
			::skip_network::
		end
	end
end
