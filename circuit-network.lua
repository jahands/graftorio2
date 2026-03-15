-- circuit-network.lua
-- Monitors circuit network signals from constant combinators
-- Uses incremental updates to track combinators without expensive full rescans
-- Exports signal values to Prometheus metrics

local PREPARE_GROUP_COMBINATORS_PER_TICK = 256
local PREPARE_RESCAN_SURFACES_PER_TICK = 1

--- @class CircuitPrepareState
--- @field stage string
--- @field surfaces LuaSurface[]
--- @field surface_idx integer
--- @field combinator_ids uint[]
--- @field combinator_idx integer
--- @field by_surface table<string, LuaEntity[]>

--- @class CircuitNetworkData
--- @field inited boolean Whether the initial rescan has been completed
--- @field combinators table<uint, LuaEntity> Map of unit_number -> combinator entity
--- @field _combinators_by_surface table<string, LuaEntity[]>? Pre-grouped combinators by surface name (set during prepare phase)
--- @field _prepare CircuitPrepareState? Runtime state for resumable prepare work

--- @type CircuitNetworkData
local data = {
	inited = false,
	combinators = {},
}

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

local function reset_prepare_state()
	data._prepare = nil
	data._combinators_by_surface = nil
end

local function begin_circuit_prepare()
	gauge_circuit_network_monitored:reset()
	gauge_circuit_network_signal:reset()
	reset_prepare_state()

	---@type LuaSurface[]
	local surfaces = {}
	for _, surface in pairs(game.surfaces) do
		surfaces[#surfaces + 1] = surface
	end

	---@type CircuitPrepareState
	local state = {
		stage = data.inited and "group" or "rescan",
		surfaces = surfaces,
		surface_idx = 1,
		combinator_ids = {},
		combinator_idx = 1,
		by_surface = {},
	}

	if not data.inited then
		data.combinators = {}
	end

	if state.stage == "group" then
		state.combinator_ids = collect_uint_keys(data.combinators)
	end

	data._prepare = state
end

--- @param state CircuitPrepareState
--- @return boolean
local function step_circuit_rescan(state)
	local processed = 0
	while processed < PREPARE_RESCAN_SURFACES_PER_TICK and state.surface_idx <= #state.surfaces do
		local surface = state.surfaces[state.surface_idx]
		if surface and surface.valid then
			for _, combinator in pairs(surface.find_entities_filtered({ type = "constant-combinator" })) do
				data.combinators[combinator.unit_number] = combinator
			end
		end
		state.surface_idx = state.surface_idx + 1
		processed = processed + 1
	end

	if state.surface_idx > #state.surfaces then
		data.inited = true
		state.stage = "group"
		state.combinator_ids = collect_uint_keys(data.combinators)
		state.combinator_idx = 1
		return true
	end

	return false
end

--- @param state CircuitPrepareState
--- @return boolean
local function step_circuit_group(state)
	local processed = 0
	while processed < PREPARE_GROUP_COMBINATORS_PER_TICK and state.combinator_idx <= #state.combinator_ids do
		local unit_number = state.combinator_ids[state.combinator_idx]
		local combinator = data.combinators[unit_number]
		if not combinator or not combinator.valid then
			data.combinators[unit_number] = nil
		else
			local surface_name = combinator.surface.name
			if not state.by_surface[surface_name] then state.by_surface[surface_name] = {} end
			state.by_surface[surface_name][#state.by_surface[surface_name] + 1] = combinator
		end
		state.combinator_idx = state.combinator_idx + 1
		processed = processed + 1
	end

	if state.combinator_idx > #state.combinator_ids then
		data._combinators_by_surface = state.by_surface
		data._prepare = nil
		return true
	end

	return false
end

--- Handle entity build events. Adds new constant combinators to tracking.
--- @param event EventData.on_built_entity|EventData.on_robot_built_entity|EventData.script_raised_built
function on_circuit_network_build(event)
	local entity = event.entity
	if entity and entity.name == "constant-combinator" then
		if data.inited then
			-- Incremental update: add single combinator instead of full rescan
			data.combinators[entity.unit_number] = entity
		else
			-- Not yet initialized, flag for rescan
			data.inited = false
		end
	end
end

--- Handle entity destroy events. Removes constant combinators from tracking.
--- @param event EventData.on_player_mined_entity|EventData.on_robot_mined_entity|EventData.on_entity_died|EventData.script_raised_destroy
function on_circuit_network_destroy(event)
	local entity = event.entity
	if entity and entity.name == "constant-combinator" then
		-- Incremental update: remove single combinator instead of full rescan
		data.combinators[entity.unit_number] = nil
	end
end

--- Initialize circuit network tracking (called on_init).
function on_circuit_network_init()
	data.inited = false
	reset_prepare_state()
end

--- Reset circuit network tracking state (called on_load).
function on_circuit_network_load()
	data.inited = false
	reset_prepare_state()
end

--- Prepare circuit network data for per-surface collection.
--- Runs as a resumable worker and returns true when the prepare phase is complete.
--- @param event EventData|NthTickEventData
--- @return boolean
function on_circuit_network_tick_prepare(event)
	if not event.tick then return true end

	if not data._prepare then
		begin_circuit_prepare()
	end

	local state = data._prepare
	if not state then return true end

	if state.stage == "rescan" then
		return step_circuit_rescan(state)
	elseif state.stage == "group" then
		return step_circuit_group(state)
	end

	return true
end

--- Collect circuit network signals for a single surface.
--- Must be called after on_circuit_network_tick_prepare() for the current cycle.
--- Circuit networks are per-surface, so the seen table is local to each surface call.
--- @param surface LuaSurface
function on_circuit_network_tick_surface(surface)
	local combinators = data._combinators_by_surface and data._combinators_by_surface[surface.name]
	if not combinators then return end

	---@type table<uint, boolean>
	local seen = {}
	for _, combinator in ipairs(combinators) do
		-- Re-validate in case combinator was destroyed between prepare and this tick
		if combinator.valid then
			-- Deduplicate networks at combinator level to avoid checking both wire types for same network
			---@type table<uint, boolean>
			local networks_checked = {}
			for _, wire_type in pairs({ defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }) do
				local network = combinator.get_circuit_network(wire_type)
				if network ~= nil and not seen[network.network_id] and not networks_checked[network.network_id] and network.signals ~= nil then
					-- Mark as checked for both seen (global) and this combinator
					networks_checked[network.network_id] = true
					seen[network.network_id] = true
					local network_id = tostring(network.network_id)
					gauge_circuit_network_monitored:set(
						1,
						{ combinator.force.name, combinator.surface.name, network_id }
					)
					for _, signal in ipairs(network.signals) do
						local quality_name = signal.signal.quality and signal.signal.quality.name or "normal"
						gauge_circuit_network_signal:set(signal.count, {
							combinator.force.name,
							combinator.surface.name,
							network_id,
							signal.signal.name,
							quality_name,
						})
					end
				end
			end
		end
	end
end

--- Collect circuit network signal metrics (monolithic). Delegates to prepare + per-surface.
--- Kept for backward compatibility; events.lua calls the granular functions directly.
--- @param event NthTickEventData|EventData
function on_circuit_network_tick(event)
	while not on_circuit_network_tick_prepare(event) do end
	if event.tick then
		for _, surface in pairs(game.surfaces) do
			on_circuit_network_tick_surface(surface)
		end
	end
end
