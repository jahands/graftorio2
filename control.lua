--- @type PrometheusModule
prometheus = require("prometheus/prometheus")
require("train")
require("yarm")
require("events")
require("power")
require("research")
require("circuit-network")

--- @type number[] Parsed histogram bucket boundaries for train metrics
bucket_settings = train_buckets(settings.startup["graftorio2-train-histogram-buckets"].value --[[@as string]])

--- @type integer Number of ticks between metric collection cycles
nth_tick = settings.startup["graftorio2-nth-tick"].value --[[@as integer]]

--- @type boolean Whether to write the .prom file in server-save mode (player 0)
server_save = settings.startup["graftorio2-server-save"].value --[[@as boolean]]

--- @type boolean Whether train statistics collection is disabled
disable_train_stats = settings.startup["graftorio2-disable-train-stats"].value --[[@as boolean]]

-- ============================================================================
-- Gauge metrics (no labels)
-- ============================================================================

--- @type Gauge
gauge_tick = prometheus.gauge("factorio_tick", "game tick")
--- @type Gauge
gauge_connected_player_count = prometheus.gauge("factorio_connected_player_count", "connected players")
--- @type Gauge
gauge_total_player_count = prometheus.gauge("factorio_total_player_count", "total registered players")

-- ============================================================================
-- Gauge metrics (with labels)
-- ============================================================================

--- @type Gauge
gauge_seed = prometheus.gauge("factorio_seed", "seed", { "surface" })
--- @type Gauge
gauge_mods = prometheus.gauge("factorio_mods", "mods", { "name", "version" })

--- @type Gauge
gauge_item_production_input = prometheus.gauge("factorio_item_production_input", "items produced", { "force", "name", "surface" })
--- @type Gauge
gauge_item_production_output =
	prometheus.gauge("factorio_item_production_output", "items consumed", { "force", "name", "surface" })

--- @type Gauge
gauge_fluid_production_input =
	prometheus.gauge("factorio_fluid_production_input", "fluids produced", { "force", "name", "surface" })
--- @type Gauge
gauge_fluid_production_output =
	prometheus.gauge("factorio_fluid_production_output", "fluids consumed", { "force", "name", "surface" })

--- @type Gauge
gauge_kill_count_input = prometheus.gauge("factorio_kill_count_input", "kills", { "force", "name", "surface" })
--- @type Gauge
gauge_kill_count_output = prometheus.gauge("factorio_kill_count_output", "losses", { "force", "name", "surface" })

--- @type Gauge
gauge_entity_build_count_input =
	prometheus.gauge("factorio_entity_build_count_input", "entities placed", { "force", "name", "surface" })
--- @type Gauge
gauge_entity_build_count_output =
	prometheus.gauge("factorio_entity_build_count_output", "entities removed", { "force", "name", "surface" })

--- @type Gauge
gauge_pollution_production_input =
	prometheus.gauge("factorio_pollution_production_input", "pollutions produced", { "name", "surface" })
--- @type Gauge
gauge_pollution_production_output =
	prometheus.gauge("factorio_pollution_production_output", "pollutions consumed", { "name", "surface" })

--- @type Gauge
gauge_evolution = prometheus.gauge("factorio_evolution", "evolution", { "force", "type", "surface" })

--- @type Gauge
gauge_research_queue = prometheus.gauge("factorio_research_queue", "research", { "force", "name", "level", "index" })

--- @type Gauge
gauge_items_launched =
	prometheus.gauge("factorio_items_launched_total", "items launched in rockets", { "force", "name", "quality" })

--- @type Gauge
gauge_yarm_site_amount =
	prometheus.gauge("factorio_yarm_site_amount", "YARM - site amount remaining", { "force", "name", "type" })
--- @type Gauge
gauge_yarm_site_ore_per_minute =
	prometheus.gauge("factorio_yarm_site_ore_per_minute", "YARM - site ore per minute", { "force", "name", "type" })
--- @type Gauge
gauge_yarm_site_remaining_permille = prometheus.gauge(
	"factorio_yarm_site_remaining_permille",
	"YARM - site permille remaining",
	{ "force", "name", "type" }
)

-- ============================================================================
-- Train metrics (gauges + histograms)
-- ============================================================================

--- @type Gauge
gauge_train_trip_time = prometheus.gauge("factorio_train_trip_time", "train trip time", { "from", "to", "train_id" })
--- @type Gauge
gauge_train_wait_time = prometheus.gauge("factorio_train_wait_time", "train wait time", { "from", "to", "train_id" })

--- @type Histogram
histogram_train_trip_time = prometheus.histogram(
	"factorio_train_trip_time_groups",
	"train trip time",
	{ "from", "to", "train_id" },
	bucket_settings
)
--- @type Histogram
histogram_train_wait_time = prometheus.histogram(
	"factorio_train_wait_time_groups",
	"train wait time",
	{ "from", "to", "train_id" },
	bucket_settings
)

--- @type Gauge
gauge_train_direct_loop_time =
	prometheus.gauge("factorio_train_direct_loop_time", "train direct loop time", { "a", "b" })
--- @type Histogram
histogram_train_direct_loop_time = prometheus.histogram(
	"factorio_train_direct_loop_time_groups",
	"train direct loop time",
	{ "a", "b" },
	bucket_settings
)

--- @type Gauge
gauge_train_arrival_time = prometheus.gauge("factorio_train_arrival_time", "train arrival time", { "station" })
--- @type Histogram
histogram_train_arrival_time =
	prometheus.histogram("factorio_train_arrival_time_groups", "train arrival time", { "station" }, bucket_settings)

-- ============================================================================
-- Logistic network metrics
-- ============================================================================

--- @type Gauge
gauge_logistic_network_all_construction_robots = prometheus.gauge(
	"factorio_logistic_network_all_construction_robots",
	"the total number of construction robots in the network (idle and active + in roboports)",
	{ "force", "surface", "network" }
)
--- @type Gauge
gauge_logistic_network_available_construction_robots = prometheus.gauge(
	"factorio_logistic_network_available_construction_robots",
	"the number of construction robots available for a job",
	{ "force", "surface", "network" }
)

--- @type Gauge
gauge_logistic_network_all_logistic_robots = prometheus.gauge(
	"factorio_logistic_network_all_logistic_robots",
	"the total number of logistic robots in the network (idle and active + in roboports)",
	{ "force", "surface", "network" }
)
--- @type Gauge
gauge_logistic_network_available_logistic_robots = prometheus.gauge(
	"factorio_logistic_network_available_logistic_robots",
	"the number of logistic robots available for a job",
	{ "force", "surface", "network" }
)

--- @type Gauge
gauge_logistic_network_robot_limit = prometheus.gauge(
	"factorio_logistic_network_robot_limit",
	"the maximum number of robots the network can work with",
	{ "force", "surface", "network" }
)

--- @type Gauge
gauge_logistic_network_items = prometheus.gauge(
	"factorio_logistic_network_items",
	"the number of items in a logistic network",
	{ "force", "surface", "network", "name", "quality" }
)

-- ============================================================================
-- Circuit network metrics
-- ============================================================================

--- @type Gauge
gauge_circuit_network_signal = prometheus.gauge(
	"factorio_circuit_network_signal",
	"the value of a signal in a circuit network",
	{ "force", "surface", "network", "name", "quality" }
)

--- @type Gauge
gauge_circuit_network_monitored = prometheus.gauge(
	"factorio_circuit_network_monitored",
	"whether a circuit network with given ID is being monitored",
	{ "force", "surface", "network" }
)

-- ============================================================================
-- Power metrics
-- ============================================================================

--- @type Gauge
gauge_power_production_input =
	prometheus.gauge("factorio_power_production_input", "power produced", { "force", "name", "network", "surface" })
--- @type Gauge
gauge_power_production_output =
	prometheus.gauge("factorio_power_production_output", "power consumed", { "force", "name", "network", "surface" })

-- ============================================================================
-- Space Age platform metrics
-- ============================================================================

--- @type Gauge
gauge_platform_count = prometheus.gauge("factorio_platform_count", "number of space platforms", { "force" })
--- @type Gauge
gauge_platform_state = prometheus.gauge("factorio_platform_state", "platform state (1=active)", { "force", "platform", "state" })
--- @type Gauge
gauge_platform_weight = prometheus.gauge("factorio_platform_weight", "platform total weight", { "force", "platform" })
--- @type Gauge
gauge_platform_speed = prometheus.gauge("factorio_platform_speed", "platform speed", { "force", "platform" })
--- @type Gauge
gauge_platform_distance = prometheus.gauge("factorio_platform_distance", "platform distance along connection (0-1)", { "force", "platform" })
--- @type Gauge
gauge_platform_damaged_tiles = prometheus.gauge("factorio_platform_damaged_tiles", "number of damaged platform tiles", { "force", "platform" })

-- ============================================================================
-- Krastorio2 metrics
-- ============================================================================

--- @type Gauge
gauge_kr_antimatter_reactors = prometheus.gauge("factorio_kr_antimatter_reactors", "number of antimatter reactors", { "force", "surface" })

-- ============================================================================
-- Event registration
-- ============================================================================

--- Register all event handlers. Called from both on_init and on_load to ensure
--- handlers are active in both new-game and save-load scenarios.
local function register_all_events()
	script.on_nth_tick(nth_tick, register_events)

	script.on_event(defines.events.on_player_joined_game, register_events_players)
	script.on_event(defines.events.on_player_left_game, register_events_players)
	script.on_event(defines.events.on_player_removed, register_events_players)
	script.on_event(defines.events.on_player_kicked, register_events_players)
	script.on_event(defines.events.on_player_banned, register_events_players)

	-- train events
	if not disable_train_stats then
		script.on_event(defines.events.on_train_changed_state, register_events_train)
	end

	-- power events
	script.on_event(defines.events.on_built_entity, on_power_build)
	script.on_event(defines.events.on_robot_built_entity, on_power_build)
	script.on_event(defines.events.script_raised_built, on_power_build)
	script.on_event(defines.events.on_player_mined_entity, on_power_destroy)
	script.on_event(defines.events.on_robot_mined_entity, on_power_destroy)
	script.on_event(defines.events.on_entity_died, on_power_destroy)
	script.on_event(defines.events.script_raised_destroy, on_power_destroy)

	-- research events
	script.on_event(defines.events.on_research_finished, on_research_finished)

	-- circuit-network events
	script.on_event(defines.events.on_built_entity, on_circuit_network_build)
	script.on_event(defines.events.on_robot_built_entity, on_circuit_network_build)
	if script.active_mods["space-exploration"] or (defines.events.on_space_platform_built_entity ~= nil) then
		script.on_event(defines.events.on_space_platform_built_entity, on_circuit_network_build)
		script.on_event(defines.events.on_space_platform_mined_entity, on_circuit_network_destroy)
	end
	script.on_event(defines.events.script_raised_built, on_circuit_network_build)
	script.on_event(defines.events.on_player_mined_entity, on_circuit_network_destroy)
	script.on_event(defines.events.on_robot_mined_entity, on_circuit_network_destroy)
	script.on_event(defines.events.on_entity_died, on_circuit_network_destroy)
	script.on_event(defines.events.script_raised_destroy, on_circuit_network_destroy)
end

script.on_init(function()
	if script.active_mods["YARM"] then
		storage.yarm_on_site_update_event_id = remote.call("YARM", "get_on_site_updated_event_id")
		script.on_event(storage.yarm_on_site_update_event_id --[[@as string]], handle_yarm)
	end

	on_power_init()
	on_circuit_network_init()

	register_all_events()
end)

script.on_load(function()
	-- Only register YARM event if YARM mod is actually active
	if storage.yarm_on_site_update_event_id and script.active_mods["YARM"] then
		-- Use pcall to safely check if the event ID is valid
		local success, handler = pcall(script.get_event_handler, storage.yarm_on_site_update_event_id)
		if success and handler then
			script.on_event(storage.yarm_on_site_update_event_id --[[@as string]], handle_yarm)
		end
	end

	on_power_load()
	on_circuit_network_load()

	register_all_events()
end)

script.on_configuration_changed(function(event)
	if script.active_mods["YARM"] then
		storage.yarm_on_site_update_event_id = remote.call("YARM", "get_on_site_updated_event_id")
		script.on_event(storage.yarm_on_site_update_event_id --[[@as string]], handle_yarm)
	end
end)
