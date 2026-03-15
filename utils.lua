-- utils.lua
-- Utility functions for string manipulation

--- Split a string by a separator character.
--- @param inputstr string The string to split
--- @param sep string Single-character separator
--- @return string[] parts The split substrings
function split(inputstr, sep)
	local t = {}
	for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
		table.insert(t, str)
	end
	return t
end
