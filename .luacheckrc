-- Luacheck configuration for Factorio mod
-- See: https://luacheck.readthedocs.io/en/stable/

-- Standard Factorio globals
std = "lua52"
cache = true

-- Factorio API globals (read-only)
read_globals = {
  "data",
  "mods",
  "settings",
  "serpent",
  "table_size",
  "util",
  "defines",
  "remote",
  "commands",
  "script",
  "rendering",
  "game",
  "storage",
  "log",
  "localised_print",
}

-- Allow these to be written to
globals = {
  "storage",
}

-- Ignore line length warnings (Factorio code can be verbose)
max_line_length = false

-- Don't complain about unused loop variables
ignore = {
  "212", -- Unused argument
  "213", -- Unused loop variable
}

files["settings*.lua"] = {
  globals = {"data"},
}

files["data*.lua"] = {
  globals = {"data"},
}

-- Exclude generated or external files
exclude_files = {
  ".luacheckrc",
  "**/node_modules/**",
  "**/vendor/**",
}
