--[[--
Redacting logging facade.

All plugin logging goes through this module so that credentials can never be
written to the KOReader log, even accidentally. It also degrades gracefully
when `logger` is not available (e.g. under the unit test runner).

@module koplugin.goodreads.logging
--]]

local Constants = require("goodreadskosync.constants")

local Logging = {}

local LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

local current_level = LEVELS.INFO
local prefix = "[goodreads]"

local ok, klogger = pcall(require, "logger")
if not ok then klogger = nil end

local fallback = {
    dbg = function(...) io.write("[goodreads] ", table.concat({ ... }, " "), "\n") end,
    info = function(...) io.write("[goodreads] ", table.concat({ ... }, " "), "\n") end,
    warn = function(...) io.write("[goodreads] ", table.concat({ ... }, " "), "\n") end,
    err = function(...) io.write("[goodreads] ", table.concat({ ... }, " "), "\n") end,
}

-- Patterns whose values must never reach the log. The replacement keeps the
-- key (useful for diagnostics) but drops the secret.
local REDACTIONS = {
    { "([Tt]oken[%s=:]+)[%w%._%-]+", "%1<redacted>" },
    { "([Cc]ookie[%s=:]+)[^\r\n]+", "%1<redacted>" },
    { "([Aa]uthorization[%s=:]+)[^\r\n]+", "%1<redacted>" },
    { "([Ss]ession[%s_]?[Ii][Dd][%s=:]+)[%w%._%-]+", "%1<redacted>" },
    { "([Pp]assword[%s=:]+)[^\r\n]+", "%1<redacted>" },
    { "([Aa]ccess[%s_]?[Tt]oken[%s=:]+)[%w%._%-]+", "%1<redacted>" },
    { "([Rr]efresh[%s_]?[Tt]oken[%s=:]+)[%w%._%-]+", "%1<redacted>" },
    { "([Cc]srf[%s=:]+)[%w%._%-]+", "%1<redacted>" },
}

function Logging.redact(value)
    if value == nil then return "" end
    local s = tostring(value)
    for _, rule in ipairs(REDACTIONS) do
        s = s:gsub(rule[1], rule[2])
    end
    return s
end

local LEVEL_METHOD = {
    DEBUG = "dbg",
    INFO = "info",
    WARN = "warn",
    ERROR = "err",
}

local function emit(level, ...)
    if LEVELS[level] < current_level then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = Logging.redact((select(i, ...)))
    end
    local line = table.concat(parts, " ")
    if klogger then
        klogger[LEVEL_METHOD[level]](line)
    else
        fallback[LEVEL_METHOD[level]](prefix, level, line)
    end
end

function Logging.setLevel(level)
    if LEVELS[level] then current_level = LEVELS[level] end
end

function Logging.getLevel()
    for name, value in pairs(LEVELS) do
        if value == current_level then return name end
    end
    return "INFO"
end

function Logging.debug(...) emit("DEBUG", ...) end
function Logging.info(...) emit("INFO", ...) end
function Logging.warn(...) emit("WARN", ...) end
function Logging.error(...) emit("ERROR", ...) end

-- Redacted trace that is also appended to a small file next to the plugin
-- settings, so a failed on-device login can always be diagnosed over USB
-- regardless of how KOReader persists its own log.
local function trace_path()
    local has_storage, Storage = pcall(require, "storage")
    local dir = has_storage and Storage.getBaseDir() or "."
    return dir .. "/login.log"
end

local function append_trace(line)
    local path = trace_path()
    local file = io.open(path, "a")
    if not file then
        local dir = path:match("^(.*)[/\\][^/\\]*$")
        if dir then
            if os.getenv("OS") ~= nil then
                os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
            else
                os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
            end
        end
        file = io.open(path, "a")
    end
    if file then
        file:write(line)
        file:close()
    end
end

function Logging.trace(...)
    emit("INFO", ...)
    if current_level <= LEVELS.INFO then
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = Logging.redact((select(i, ...)))
        end
        append_trace(os.date("%Y-%m-%d %H:%M:%S ")
            .. table.concat(parts, " ") .. "\n")
    end
end

-- Build a support-safe diagnostic summary. Only allowlisted scalar fields are
-- included; book titles, authors, credentials, and response bodies never are.
function Logging.diagnosticSummary(fields)
    fields = fields or {}
    local order = {
        "koreader_version", "plugin_version", "device_family", "provider",
        "provider_available", "last_stage", "http_status", "queue_size",
        "mappings_count", "last_sync_at",
    }
    local lines = {}
    for _, key in ipairs(order) do
        local value = fields[key]
        if value ~= nil then
            lines[#lines + 1] = string.format("%s=%s", key, Logging.redact(value))
        end
    end
    return table.concat(lines, "\n")
end

Logging.LEVELS = LEVELS
Logging.VERSION = Constants.VERSION

return Logging
