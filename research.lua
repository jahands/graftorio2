-- research.lua
-- Monitors technology research progress and queue
-- Tracks completed research and exports progress metrics per force

--- @class ResearchRecord
--- @field researched integer 1 if completed
--- @field name string Technology prototype name
--- @field level integer Technology level

--- Handle research completion event. Stores the last completed research per force in `storage`.
--- @param event EventData.on_research_finished
function on_research_finished(event)
	local research = event.research
	if not storage.last_research then
		--- @type table<string, ResearchRecord>
		storage.last_research = {}
	end

	local level = research.level
	-- Previous research is incorrect lvl if it has more than one research
	if level > 1 then
		level = level - 1
	end

	storage.last_research[research.force.name] = {
		researched = 1,
		name = research.name,
		level = level,
	}
end

--- Collect research queue metrics for a force. Called once per force per nth-tick.
--- The argument comes from `for_each_force` in `events.lua` and only needs to provide
--- `player.force`, whether it is a real `LuaPlayer` or the zero-player fallback wrapper.
--- @param player LuaPlayer|{ force: LuaForce }
--- @param event NthTickEventData|EventData
function on_research_tick(player, event)
	if event.tick then
		--- @type ResearchRecord|false
		local researched_queue = storage.last_research and storage.last_research[player.force.name] or false
		if researched_queue then
			gauge_research_queue:set(
				researched_queue.researched and 1 or 0,
				{ player.force.name, researched_queue.name, researched_queue.level, -1 }
			)
		end

		-- Levels dont get matched properly so store and save
		--- @type table<string, integer>
		local levels = {}
		for idx, tech in pairs(player.force.research_queue or { player.force.current_research }) do
			levels[tech.name] = levels[tech.name] and levels[tech.name] + 1 or tech.level
			gauge_research_queue:set(
				idx == 1 and player.force.research_progress or 0,
				{ player.force.name, tech.name, levels[tech.name], idx }
			)
		end
	end
end
