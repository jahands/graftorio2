-- settings.lua
-- Mod startup settings for graftorio2
-- Runs in the data stage where `data:extend()` is the main API

data:extend({
	{
		type = "int-setting",
		name = "graftorio2-nth-tick",
		setting_type = "startup",
		default_value = 300,
		allow_blank = false,
	},
	{
		type = "bool-setting",
		name = "graftorio2-server-save",
		setting_type = "startup",
		default_value = true,
		allow_blank = false,
	},
})
