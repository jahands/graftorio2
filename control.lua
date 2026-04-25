--- @type PrometheusModule
prometheus = require("prometheus/prometheus")
require("events")

--- @type integer Number of ticks between metric collection cycles
nth_tick = settings.startup["graftorio2-nth-tick"].value --[[@as integer]]

--- @type boolean Whether to write the .prom file in server-save mode (player 0)
server_save = settings.startup["graftorio2-server-save"].value --[[@as boolean]]

--- @type Gauge
gauge_items_launched =
	prometheus.gauge("factorio_items_launched_total", "items launched in rockets", { "force", "name", "quality" })

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

local function register_all_events()
	script.on_nth_tick(nth_tick, start_export_pipeline)
	script.on_event(defines.events.on_tick, advance_export_pipeline)
end

script.on_init(register_all_events)
script.on_load(register_all_events)
