--[[--
Reading progress helpers.

Live in-memory progress is authoritative while a document is open; persisted
settings are only a fallback. Progress is always sent as a whole number.

@module koplugin.goodreads.sync.progress
--]]

local Util = require("goodreadskosync.util")
local Logging = require("goodreadskosync.logging")

local Progress = {}

-- Read the current fractional progress (0..1) from an open ReaderUI.
function Progress.fromReader(ui)
    if type(ui) ~= "table" then return nil end
    local module = ui.paging or ui.rolling
    if module and type(module.getLastPercent) == "function" then
        local ok, percent = pcall(module.getLastPercent, module)
        if ok and type(percent) == "number" then return percent end
    end
    local settings = ui.doc_settings
    if settings and type(settings.readSetting) == "function" then
        local ok, percent = pcall(settings.readSetting, settings, "percent_finished")
        if ok and type(percent) == "number" then return percent end
    end
    return nil
end

-- Whether KOReader has explicitly marked the document complete.
function Progress.isComplete(ui)
    if type(ui) ~= "table" or not ui.doc_settings then return false end
    local settings = ui.doc_settings
    if type(settings.readSetting) ~= "function" then return false end
    local ok, summary = pcall(settings.readSetting, settings, "summary")
    if ok and type(summary) == "table" and summary.status == "complete" then
        return true
    end
    return false
end

function Progress.toWhole(percent)
    return Util.percentToInt(percent)
end

-- Only sync when the whole-number percent actually changed, and never send a
-- zero percent (opening a book is not reading).
function Progress.shouldSync(state, whole_percent)
    if type(whole_percent) ~= "number" or whole_percent <= 0 then
        Logging.diag("progress.shouldSync pct=", tostring(whole_percent), "-> false")
        return false
    end
    local last = state and state.last_successful_percent
    local ok = state == nil or last ~= whole_percent
    Logging.diag("progress.shouldSync last=", tostring(last), " pct=",
        tostring(whole_percent), "-> ", tostring(ok))
    return ok
end

-- Update state only after a confirmed provider success.
function Progress.recordSuccess(state, whole_percent)
    state.last_local_percent = whole_percent
    state.last_successful_percent = whole_percent
    return state
end

return Progress
