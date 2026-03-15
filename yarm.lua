-- yarm.lua
-- Integration with YARM (Yet Another Resource Monitor) mod
-- Exports resource site metrics including amounts and mining rates

--- @class YarmSiteData
--- @field amount number Resource amount remaining
--- @field force_name string Name of the owning force
--- @field site_name string Name of the resource site
--- @field ore_type string Type of ore at the site
--- @field ore_per_minute number Mining rate in ore per minute
--- @field remaining_permille number Remaining resource as permille (0-1000)

--- Handle a YARM site update event. Called via remote interface when YARM mod is active.
--- @param site YarmSiteData
function handle_yarm(site)
	gauge_yarm_site_amount:set(site.amount, { site.force_name, site.site_name, site.ore_type })
	gauge_yarm_site_ore_per_minute:set(site.ore_per_minute, { site.force_name, site.site_name, site.ore_type })
	gauge_yarm_site_remaining_permille:set(site.remaining_permille, { site.force_name, site.site_name, site.ore_type })
end
