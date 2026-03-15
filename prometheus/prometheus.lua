-- vim: ts=2:sw=2:sts=2:expandtab
-- luacheck: globals box

local INF = math.huge
local NAN = math.huge * 0

--- Default histogram bucket boundaries (seconds).
--- @type number[]
local DEFAULT_BUCKETS = { 0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0, INF }

--- @type Registry?
local REGISTRY = nil

--- @class Registry
--- @field collectors table<string, Counter|Gauge|Histogram>
--- @field callbacks fun()[]
local Registry = {}
Registry.__index = Registry

--- Create a new Registry instance.
--- @return Registry
function Registry.new()
	local obj = {}
	setmetatable(obj, Registry)
	obj.collectors = {}
	obj.callbacks = {}
	return obj
end

--- Register a collector with this registry. Returns existing collector if name is already registered.
--- @param collector Counter|Gauge|Histogram
--- @return Counter|Gauge|Histogram
function Registry:register(collector)
	if self.collectors[collector.name] ~= nil then
		return self.collectors[collector.name]
	end
	self.collectors[collector.name] = collector
	return collector
end

--- Unregister a collector from this registry.
--- @param collector Counter|Gauge|Histogram
function Registry:unregister(collector)
	if self.collectors[collector.name] ~= nil then
		self.collectors[collector.name] = nil
	end
end

--- Register a callback to be invoked before metric collection.
--- @param callback fun()
function Registry:register_callback(callback)
	local found = false
	for _, registered_callback in ipairs(self.callbacks) do
		if registered_callback == callback then
			found = true
		end
	end
	if not found then
		table.insert(self.callbacks, callback)
	end
end

--- Get or create the singleton registry.
--- @return Registry
local function get_registry()
	if not REGISTRY then
		REGISTRY = Registry.new()
	end
	return REGISTRY
end

--- Register a collector with the global singleton registry.
--- @generic T: Counter|Gauge|Histogram
--- @param collector T
--- @return T
local function register(collector)
	local registry = get_registry()
	registry:register(collector)

	return collector
end

--- Register a callback with the global singleton registry.
--- @param callback fun()
local function register_callback(callback)
	local registry = get_registry()
	registry:register_callback(callback)
end

--- Zip two arrays into an array of pairs.
--- @param lhs string[]?
--- @param rhs (string|number)[]?
--- @return {[1]: string, [2]: string|number}[]
local function zip(lhs, rhs)
	if lhs == nil or rhs == nil then
		return {}
	end

	local len = math.min(#lhs, #rhs)
	local result = {}
	for i = 1, len do
		table.insert(result, { lhs[i], rhs[i] })
	end
	return result
end

--- Convert a numeric value to its Prometheus string representation.
--- @param value number
--- @return string
local function metric_to_string(value)
	if value == INF then
		return "+Inf"
	elseif value == -INF then
		return "-Inf"
	elseif value ~= value then
		return "Nan"
	else
		return tostring(value)
	end
end

--- Escape a string for Prometheus text format (backslashes, newlines, double-quotes).
--- @param str string
--- @return string
local function escape_string(str)
	return (str:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub('"', '\\"'))
end

--- Format label pairs as a Prometheus label string like `{key="value",...}`.
--- @param label_pairs {[1]: string, [2]: string|number}[]
--- @return string
local function labels_to_string(label_pairs)
	if #label_pairs == 0 then
		return ""
	end
	local label_parts = {}
	for _, label in ipairs(label_pairs) do
		local label_name = label[1]
		local label_value = label[2]
		local label_value_escaped = escape_string(string.format("%s", label_value))
		table.insert(label_parts, label_name .. '="' .. label_value_escaped .. '"')
	end
	return "{" .. table.concat(label_parts, ",") .. "}"
end

--- @class Counter
--- @field name string Metric name
--- @field help string Help text
--- @field labels string[] Label names
--- @field observations table<string, number> Keyed by concatenated label values
--- @field label_values table<string, (string|number)[]> Keyed by concatenated label values
local Counter = {}
Counter.__index = Counter

--- Create a new Counter instance.
--- @param name string Metric name (required)
--- @param help string? Help text
--- @param labels string[]? Label names
--- @return Counter
function Counter.new(name, help, labels)
	local obj = {}
	setmetatable(obj, Counter)
	if not name then
		error("Name should be set for Counter")
	end
	obj.name = name
	obj.help = help or ""
	obj.labels = labels or {}
	obj.observations = {}
	obj.label_values = {}

	return obj
end

--- Increment the counter by a non-negative number.
--- @param num number? Increment amount (default 1)
--- @param label_values (string|number)[]? Label values
function Counter:inc(num, label_values)
	num = num or 1
	label_values = label_values or {}
	if num < 0 then
		error("Counter increment should not be negative")
	end
	local key = table.concat(label_values, "\0")
	local old_value = self.observations[key] or 0
	self.observations[key] = old_value + num
	self.label_values[key] = label_values
end

--- Collect counter metrics as Prometheus text lines.
--- @return string[]
function Counter:collect()
	local result = {}

	if next(self.observations) == nil then
		return {}
	end

	table.insert(result, "# HELP " .. self.name .. " " .. escape_string(self.help))
	table.insert(result, "# TYPE " .. self.name .. " counter")

	for key, observation in pairs(self.observations) do
		local label_values = self.label_values[key]
		local prefix = self.name
		local labels = zip(self.labels, label_values)

		local str = prefix .. labels_to_string(labels) .. " " .. metric_to_string(observation)
		table.insert(result, str)
	end

	return result
end

--- Return sorted keys of all observations for chunked iteration.
--- @return string[]
function Counter:observation_keys()
	local keys = {}
	for key, _ in pairs(self.observations) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

--- Return the HELP/TYPE header lines for this counter.
--- @return string[]
function Counter:collect_header()
	return {
		"# HELP " .. self.name .. " " .. escape_string(self.help),
		"# TYPE " .. self.name .. " counter",
	}
end

--- Collect a single observation by key. Returns nil if the key no longer exists.
--- @param key string
--- @return string[]?
function Counter:collect_observation(key)
	local observation = self.observations[key]
	if observation == nil then
		return nil
	end
	local label_values = self.label_values[key]
	local labels = zip(self.labels, label_values)
	return { self.name .. labels_to_string(labels) .. " " .. metric_to_string(observation) }
end

--- @class Gauge
--- @field name string Metric name
--- @field help string Help text
--- @field labels string[] Label names
--- @field observations table<string, number> Keyed by concatenated label values
--- @field label_values table<string, (string|number)[]> Keyed by concatenated label values
local Gauge = {}
Gauge.__index = Gauge

--- Create a new Gauge instance.
--- @param name string Metric name (required)
--- @param help string? Help text
--- @param labels string[]? Label names
--- @return Gauge
function Gauge.new(name, help, labels)
	local obj = {}
	setmetatable(obj, Gauge)
	if not name then
		error("Name should be set for Gauge")
	end
	obj.name = name
	obj.help = help or ""
	obj.labels = labels or {}
	obj.observations = {}
	obj.label_values = {}

	return obj
end

--- Reset all observations and label values.
function Gauge:reset()
	self.observations = {}
	self.label_values = {}
end

--- Increment the gauge by a number.
--- @param num number? Increment amount (default 1)
--- @param label_values (string|number)[]? Label values
function Gauge:inc(num, label_values)
	num = num or 1
	label_values = label_values or {}
	local key = table.concat(label_values, "\0")
	local old_value = self.observations[key] or 0
	self.observations[key] = old_value + num
	self.label_values[key] = label_values
end

--- Decrement the gauge by a number.
--- @param num number? Decrement amount (default 1)
--- @param label_values (string|number)[]? Label values
function Gauge:dec(num, label_values)
	num = num or 1
	label_values = label_values or {}
	local key = table.concat(label_values, "\0")
	local old_value = self.observations[key] or 0
	self.observations[key] = old_value - num
	self.label_values[key] = label_values
end

--- Set the gauge to an absolute value.
--- @param num number? Value to set (default 0)
--- @param label_values (string|number)[]? Label values
function Gauge:set(num, label_values)
	num = num or 0
	label_values = label_values or {}
	local key = table.concat(label_values, "\0")
	self.observations[key] = num
	self.label_values[key] = label_values
end

--- Collect gauge metrics as Prometheus text lines.
--- @return string[]
function Gauge:collect()
	local result = {}

	if next(self.observations) == nil then
		return {}
	end

	table.insert(result, "# HELP " .. self.name .. " " .. escape_string(self.help))
	table.insert(result, "# TYPE " .. self.name .. " gauge")

	for key, observation in pairs(self.observations) do
		local label_values = self.label_values[key]
		local prefix = self.name
		local labels = zip(self.labels, label_values)

		local str = prefix .. labels_to_string(labels) .. " " .. metric_to_string(observation)
		table.insert(result, str)
	end

	return result
end

--- Return sorted keys of all observations for chunked iteration.
--- @return string[]
function Gauge:observation_keys()
	local keys = {}
	for key, _ in pairs(self.observations) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

--- Return the HELP/TYPE header lines for this gauge.
--- @return string[]
function Gauge:collect_header()
	return {
		"# HELP " .. self.name .. " " .. escape_string(self.help),
		"# TYPE " .. self.name .. " gauge",
	}
end

--- Collect a single observation by key. Returns nil if the key no longer exists.
--- @param key string
--- @return string[]?
function Gauge:collect_observation(key)
	local observation = self.observations[key]
	if observation == nil then
		return nil
	end
	local label_values = self.label_values[key]
	local labels = zip(self.labels, label_values)
	return { self.name .. labels_to_string(labels) .. " " .. metric_to_string(observation) }
end

--- @class Histogram
--- @field name string Metric name
--- @field help string Help text
--- @field labels string[] Label names
--- @field buckets number[] Sorted bucket boundaries (always ends with +Inf)
--- @field observations table<string, number[]> Bucket counts keyed by concatenated label values
--- @field label_values table<string, (string|number)[]> Keyed by concatenated label values
--- @field counts table<string, number> Total observation counts per key
--- @field sums table<string, number> Total observation sums per key
local Histogram = {}
Histogram.__index = Histogram

--- Create a new Histogram instance.
--- @param name string Metric name (required)
--- @param help string? Help text
--- @param labels string[]? Label names
--- @param buckets number[]? Bucket boundaries (defaults to DEFAULT_BUCKETS)
--- @return Histogram
function Histogram.new(name, help, labels, buckets)
	local obj = {}
	setmetatable(obj, Histogram)
	if not name then
		error("Name should be set for Histogram")
	end
	obj.name = name
	obj.help = help or ""
	obj.labels = labels or {}
	obj.buckets = buckets or DEFAULT_BUCKETS
	table.sort(obj.buckets)
	if obj.buckets[#obj.buckets] ~= INF then
		obj.buckets[#obj.buckets + 1] = INF
	end
	obj.observations = {}
	obj.label_values = {}
	obj.counts = {}
	obj.sums = {}

	return obj
end

--- Record an observation in the histogram.
--- @param num number? Observed value (default 0)
--- @param label_values (string|number)[]? Label values
function Histogram:observe(num, label_values)
	num = num or 0
	label_values = label_values or {}
	local key = table.concat(label_values, "\0")

	local obs
	if self.observations[key] == nil then
		obs = {}
		for i = 1, #self.buckets do
			obs[i] = 0
		end
		self.observations[key] = obs
		self.label_values[key] = label_values
		self.counts[key] = 0
		self.sums[key] = 0
	else
		obs = self.observations[key]
	end

	self.counts[key] = self.counts[key] + 1
	self.sums[key] = self.sums[key] + num
	for i, bucket in ipairs(self.buckets) do
		if num <= bucket then
			obs[i] = obs[i] + 1
		end
	end
end

--- Collect histogram metrics as Prometheus text lines.
--- @return string[]
function Histogram:collect()
	local result = {}

	if next(self.observations) == nil then
		return {}
	end

	table.insert(result, "# HELP " .. self.name .. " " .. escape_string(self.help))
	table.insert(result, "# TYPE " .. self.name .. " histogram")

	for key, observation in pairs(self.observations) do
		local label_values = self.label_values[key]
		local prefix = self.name
		local labels = zip(self.labels, label_values)
		labels[#labels + 1] = { le = "0" }
		for i, bucket in ipairs(self.buckets) do
			labels[#labels] = { "le", metric_to_string(bucket) }
			local str = prefix .. "_bucket" .. labels_to_string(labels) .. " " .. metric_to_string(observation[i])
			table.insert(result, str)
		end
		table.remove(labels, #labels)

		table.insert(result, prefix .. "_sum" .. labels_to_string(labels) .. " " .. self.sums[key])
		table.insert(result, prefix .. "_count" .. labels_to_string(labels) .. " " .. self.counts[key])
	end

	return result
end

--- Return sorted keys of all observations for chunked iteration.
--- @return string[]
function Histogram:observation_keys()
	local keys = {}
	for key, _ in pairs(self.observations) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

--- Return the HELP/TYPE header lines for this histogram.
--- @return string[]
function Histogram:collect_header()
	return {
		"# HELP " .. self.name .. " " .. escape_string(self.help),
		"# TYPE " .. self.name .. " histogram",
	}
end

--- Collect a single observation by key. Returns nil if the key no longer exists.
--- Replicates the le-label append/remove pattern from Histogram:collect().
--- @param key string
--- @return string[]?
function Histogram:collect_observation(key)
	local observation = self.observations[key]
	if observation == nil then
		return nil
	end
	local result = {}
	local label_values = self.label_values[key]
	local prefix = self.name
	local labels = zip(self.labels, label_values)
	labels[#labels + 1] = { le = "0" }
	for i, bucket in ipairs(self.buckets) do
		labels[#labels] = { "le", metric_to_string(bucket) }
		result[#result + 1] = prefix .. "_bucket" .. labels_to_string(labels) .. " " .. metric_to_string(observation[i])
	end
	table.remove(labels, #labels)

	result[#result + 1] = prefix .. "_sum" .. labels_to_string(labels) .. " " .. self.sums[key]
	result[#result + 1] = prefix .. "_count" .. labels_to_string(labels) .. " " .. self.counts[key]
	return result
end

-- #################### Public API ####################

--- Create and register a new Counter metric.
--- @param name string Metric name
--- @param help string? Help text
--- @param labels string[]? Label names
--- @return Counter
local function counter(name, help, labels)
	local obj = Counter.new(name, help, labels)
	obj = register(obj)
	return obj
end

--- Create and register a new Gauge metric.
--- @param name string Metric name
--- @param help string? Help text
--- @param labels string[]? Label names
--- @return Gauge
local function gauge(name, help, labels)
	local obj = Gauge.new(name, help, labels)
	obj = register(obj)
	return obj
end

--- Create and register a new Histogram metric.
--- @param name string Metric name
--- @param help string? Help text
--- @param labels string[]? Label names
--- @param buckets number[]? Bucket boundaries
--- @return Histogram
local function histogram(name, help, labels, buckets)
	local obj = Histogram.new(name, help, labels, buckets)
	obj = register(obj)
	return obj
end

--- Module-local state for chunked (multi-tick) collection.
--- @type {collector_keys: string[], collector_idx: integer, result: string[], obs_keys: string[]?, obs_idx: integer?}?
local chunked_state = nil

--- Begin a chunked collection pass. Invokes registered callbacks (once) and
--- snapshots collector names into a deterministic ordered array for stable
--- cursor iteration across ticks.
local function collect_chunked_start()
	local registry = get_registry()

	-- Invoke callbacks exactly once, before any collector iteration
	for _, registered_callback in ipairs(registry.callbacks) do
		registered_callback()
	end

	-- Snapshot collector keys into a sorted array for deterministic order
	local keys = {}
	for name, _ in pairs(registry.collectors) do
		keys[#keys + 1] = name
	end
	table.sort(keys)

	chunked_state = {
		collector_keys = keys,
		collector_idx = 1,
		result = {},
	}
end

--- Process observations across collectors, emitting up to `budget` output lines
--- per call. Tracks an intra-collector cursor (obs_keys / obs_idx) so that a
--- collector with many observations is spread across multiple ticks.
--- Returns `true` when all collectors have been fully processed, `false` otherwise.
--- @param budget integer  Number of output lines to emit this tick
--- @return boolean done
local function collect_chunked_next(budget)
	if not chunked_state then
		error("collect_chunked_next called without collect_chunked_start")
	end

	local registry = get_registry()
	local keys = chunked_state.collector_keys
	local result = chunked_state.result
	local lines_emitted = 0

	while chunked_state.collector_idx <= #keys and lines_emitted < budget do
		local collector_key = keys[chunked_state.collector_idx]
		local collector = registry.collectors[collector_key]

		if not collector then
			-- Collector was unregistered between start and now; skip it
			chunked_state.collector_idx = chunked_state.collector_idx + 1
			chunked_state.obs_keys = nil
			chunked_state.obs_idx = nil
		else
			-- Lazily initialize the observation cursor for this collector
			if not chunked_state.obs_keys then
				chunked_state.obs_keys = collector:observation_keys()
				chunked_state.obs_idx = 1

				-- Emit header lines if this collector has any observations
				if #chunked_state.obs_keys > 0 then
					for _, line in ipairs(collector:collect_header()) do
						result[#result + 1] = line
						lines_emitted = lines_emitted + 1
					end
				end
			end

			local obs_keys = chunked_state.obs_keys --[[@as string[] ]]
			local obs_idx = chunked_state.obs_idx --[[@as integer]]

			-- Process observations one at a time until budget exhausted or done
			while obs_idx <= #obs_keys and lines_emitted < budget do
				local obs_key = obs_keys[obs_idx]
				local obs_lines = collector:collect_observation(obs_key)
				if obs_lines then
					for _, line in ipairs(obs_lines) do
						result[#result + 1] = line
						lines_emitted = lines_emitted + 1
					end
				end
				obs_idx = obs_idx + 1
			end

			chunked_state.obs_idx = obs_idx

			if obs_idx > #obs_keys then
				-- This collector is fully processed
				-- Separator between collectors (matches Registry:collect() behavior)
				if #obs_keys > 0 then
					result[#result + 1] = ""
				end
				chunked_state.collector_idx = chunked_state.collector_idx + 1
				chunked_state.obs_keys = nil
				chunked_state.obs_idx = nil
			end
			-- else: budget exhausted mid-collector, cursor stays for next call
		end
	end

	return chunked_state.collector_idx > #keys and chunked_state.obs_keys == nil
end

--- Finalize the chunked collection: concat accumulated lines into a single
--- Prometheus text string, clear chunked state, and return the result.
--- @return string
local function collect_chunked_finish()
	if not chunked_state then
		error("collect_chunked_finish called without collect_chunked_start")
	end

	local output = table.concat(chunked_state.result, "\n") .. "\n"
	chunked_state = nil
	return output
end

--- @class PrometheusModule
--- @field counter fun(name: string, help?: string, labels?: string[]): Counter
--- @field gauge fun(name: string, help?: string, labels?: string[]): Gauge
--- @field histogram fun(name: string, help?: string, labels?: string[], buckets?: number[]): Histogram
--- @field collect_chunked_start fun()
--- @field collect_chunked_next fun(budget: integer): boolean
--- @field collect_chunked_finish fun(): string

--- @type PrometheusModule
return {
	counter = counter,
	gauge = gauge,
	histogram = histogram,
	collect_chunked_start = collect_chunked_start,
	collect_chunked_next = collect_chunked_next,
	collect_chunked_finish = collect_chunked_finish,
}
