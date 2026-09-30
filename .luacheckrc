-- luacheck configuration for goodreads.koplugin
-- Targets Lua 5.1 / LuaJIT semantics, as used by KOReader.

std = "lua51"

cache = false

-- Only lint our own source; never vendored tools or fixtures.
exclude_files = {
    "tools/**",
    "tests/fixtures/**",
}

files["goodreads.koplugin/**/*.lua"] = {
    globals = {
        -- KOReader-provided globals
        "G_reader_settings",
        "G_defaults",
        "G_reader_settings_migration",
        -- KOReader-provided modules injected via `package.preload`
        "DEBUG",
    },
}

files["tests/**/*.lua"] = {
    read_globals = {
        "describe",
        "it",
        "assert_equal",
        "assert_true",
        "assert_false",
        "assert_nil",
        "assert_not_nil",
        "assert_error",
    },
}

max_line_length = false
unused_args = false
