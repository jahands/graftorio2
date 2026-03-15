-- circuit-network.lua
-- Monitors circuit network signals from constant combinators
-- Uses incremental updates to track combinators without expensive full rescans
-- Exports signal values to Prometheus metrics

--- @class CircuitNetworkData
--- @field inited boolean Whether the initial rescan has been completed
--- @field combinators table<uint, LuaEntity> Map of unit_number -> combinator entity

--- @type CircuitNetworkData
local data = {
	inited = false,
	combinators = {},
}

--- Perform a full rescan of all constant combinators across all surfaces and forces.
local function rescan()
	data.combinators = {}
	for _, player in pairs(game.players) do
		for _, surface in pairs(game.surfaces) do
			for _, combinator in
				pairs(surface.find_entities_filtered({
					force = player.force,
					type = "constant-combinator",
				}))
			do
				data.combinators[combinator.unit_number] = combinator
			end
		end
	end
	data.inited = true
end

--- Handle entity build events. Adds new constant combinators to tracking.
--- @param event EventData.on_built_entity|EventData.on_robot_built_entity|EventData.script_raised_built
function on_circuit_network_build(event)
	local entity = event.entity or event.created_entity ---@diagnostic disable-line: undefined-field -- Factorio 1.x compat fallback
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
end

--- Reset circuit network tracking state (called on_load).
function on_circuit_network_load()
	data.inited = false
end

--- Collect circuit network signal metrics. Called every nth-tick from events.lua.
--- @param event NthTickEventData
function on_circuit_network_tick(event)
	if event.tick then
		if not data.inited then
			rescan()
		end

		gauge_circuit_network_monitored:reset()
		gauge_circuit_network_signal:reset()
		--- @type table<uint, boolean>
		local seen = {}
		for unit_number, combinator in pairs(data.combinators) do
			-- Validate entity and clean up invalid references
			if not combinator.valid then
				data.combinators[unit_number] = nil
				goto continue
			end

			-- Deduplicate networks at combinator level to avoid checking both wire types for same network
			--- @type table<uint, boolean>
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
			::continue::
		end
	end
end
