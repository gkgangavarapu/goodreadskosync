--[[--
Sync presets.

A single preset drives every sync behaviour, so users pick one profile instead
of tuning individual settings. Each preset expands to the underlying settings
consumed by the sync engine.

@module koplugin.goodreads.sync.presets
--]]

local Constants = require("goodreadskosync.constants")

local Presets = {}

Presets.ORDER = { "fastest", "faster", "medium", "relaxed" }
Presets.DEFAULT = "relaxed"

-- Values shared by every preset (kept here so a preset fully defines behaviour).
local COMMON = {
    auto_shelf = true,
    auto_progress = true,
    sync_on_open = true,
    sync_on_close = true,
    completion_behavior = Constants.COMPLETION_BEHAVIOR.EXPLICIT_ONLY,
    conflict_policy = Constants.CONFLICT_POLICY.PREFER_LOCAL,
    update_progress_after_finished = false,
}

local DEFINITIONS = {
    fastest = { track_mode = "percent", track_percent_step = 2, sync_interval = 120 },
    faster = { track_mode = "percent", track_percent_step = 5, sync_interval = 300 },
    medium = { track_mode = "time", track_percent_step = 5, sync_interval = 900 },
    relaxed = { track_mode = "time", track_percent_step = 5, sync_interval = 0 },
}

for _, id in ipairs(Presets.ORDER) do
    for key, value in pairs(COMMON) do
        DEFINITIONS[id][key] = value
    end
end

function Presets.is_valid(id)
    return DEFINITIONS[id] ~= nil
end

-- Returns the settings a preset applies, or nil for an unknown preset.
function Presets.get(id)
    return DEFINITIONS[id]
end

return Presets
