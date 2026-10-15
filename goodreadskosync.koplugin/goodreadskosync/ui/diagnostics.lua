--[[--
Diagnostics UI: the connection doctor and the diagnostic-log export.

Mixed into the plugin as methods (`self` is the plugin instance). The report is
assembled by `goodreadskosync/diagnostics.lua` (pure); this module only labels
it, gathers the on-device snapshot and shows the dialogs.

The exported report and the copied summary are English and technical on
purpose: they are meant to be attached to a bug report and read by whoever
troubleshoots it, whatever language the app is running in. It never contains
passwords, cookies, session tokens or response bodies.

@module koplugin.goodreads.ui.diagnostics
--]]

local Auth = require("goodreadskosync.auth.manager")
local ButtonDialog = require("ui/widget/buttondialog")
local Constants = require("goodreadskosync.constants")
local Diagnostics = require("goodreadskosync.diagnostics")
local Logging = require("goodreadskosync.logging")
local Mappings = require("goodreadskosync.mappings")
local Queue = require("goodreadskosync.sync.queue")
local Storage = require("goodreadskosync.storage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local Widgets = require("goodreadskosync.ui.widgets")
local _ = require("gettext")

local DiagnosticsUI = {}

-- How much of each log is bundled. Bounded so the report stays small and the
-- export can never balloon on a device that is short on memory.
local LOG_TAIL_LINES = 200
local LOG_TAIL_BYTES = 32 * 1024
local CRASH_TAIL_LINES = 120
local CRASH_TAIL_BYTES = 24 * 1024

local VERDICT_TEXT = {
    [Diagnostics.STATUS.OK] = _("Everything looks fine."),
    [Diagnostics.STATUS.WARN] = _("Mostly fine - see the notes below."),
    [Diagnostics.STATUS.FAIL] = _("Problems found - see the notes below."),
}

-- Translated names and remedies for each check id.
local function checkLabels()
    return {
        network = {
            name = _("Network"),
            hints = { fail = _("Turn on Wi-Fi and run the doctor again.") },
        },
        provider = {
            name = _("Goodreads backend"),
            hints = { fail = _("The Goodreads backend could not be loaded; reinstall the plugin.") },
        },
        account = {
            name = _("Signed in"),
            hints = { fail = _("Sign in to Goodreads, then run the doctor again.") },
        },
        session = {
            name = _("Saved session"),
            hints = {
                fail = _("Log in again to refresh the saved session."),
                warn = _("Sign in to Goodreads."),
            },
        },
        session_live = {
            name = _("Goodreads reachable"),
            hints = {
                fail = _("Log in again: Goodreads rejected the saved session."),
                warn = _("Goodreads was slow or asked for a sign-in check. Try again later."),
            },
        },
        queue = {
            name = _("Pending syncs"),
            hints = { warn = _("Open \"Waiting to sync\" to retry or clear them.") },
        },
        clock = {
            name = _("Device clock"),
            hints = { fail = _("Set the device's date and time; a wrong clock breaks the connection.") },
        },
        logging = {
            name = _("Diagnostic logging"),
            hints = { warn = _("Turn on \"Diagnostic logging\" in Settings to capture more detail.") },
        },
    }
end

local function koreaderVersion()
    local ok, Version = pcall(require, "version")
    if ok and Version and type(Version.getShortVersion) == "function" then
        local got, version = pcall(function() return Version:getShortVersion() end)
        if got and version then return version end
    end
    return "unknown"
end

local function deviceModel()
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.model then return tostring(Device.model) end
    return "unknown"
end

local function canCopyToClipboard()
    local ok, Device = pcall(require, "device")
    if not ok or not Device then return false end
    local has = false
    local got, value = pcall(function() return Device:hasClipboard() end)
    if got then has = value == true end
    return has and Device.input ~= nil
        and type(Device.input.setClipboardText) == "function"
end

local function copyToClipboard(text)
    local ok, Device = pcall(require, "device")
    if not ok or not Device or not Device.input then return false end
    local done = pcall(function() Device.input.setClipboardText(text) end)
    return done
end

-- The KOReader data directory holds crash.log; the plugin's own logs live next
-- to the plugin settings.
local function crashLogPath()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage then return nil end
    local got, dir = pcall(function() return DataStorage:getDataDir() end)
    if got and dir and dir ~= "" then
        return dir .. "/crash.log"
    end
    return nil
end

-- KOReader's data directory is relative on some setups (it is "." on Kindle,
-- resolved against the process working directory), which makes for a useless
-- path in a report the user has to find over USB. Resolve the working directory
-- once and use it to make every path we show absolute.
local working_dir
local working_dir_done = false

local function workingDirectory()
    if working_dir_done then return working_dir end
    working_dir_done = true
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil and type(ffiutil.realpath) == "function" then
        local got, resolved = pcall(ffiutil.realpath, ".")
        if got and resolved and resolved:sub(1, 1) == "/" then
            working_dir = resolved
            return working_dir
        end
    end
    local pwd = os.getenv("PWD")
    if pwd and pwd:sub(1, 1) == "/" then working_dir = pwd end
    return working_dir
end

local function absolute(path)
    return Diagnostics.absolutePath(path, workingDirectory())
end

local function redacted(lines)
    local out = {}
    for _i, line in ipairs(lines or {}) do
        out[#out + 1] = Logging.redact(line)
    end
    return out
end

local function showReportText(title, text)
    local viewer = TextViewer:new{
        title = title,
        text = text,
        justified = false,
        auto_para_direction = false,
    }
    UIManager:show(viewer)
    return viewer
end

-- Present the doctor's findings with a shortcut to the full export.
local function showChecks(plugin, checks)
    local counts = Diagnostics.counts(checks)
    local body = table.concat({
        VERDICT_TEXT[Diagnostics.verdict(counts)] or "",
        "",
        Diagnostics.formatChecks(checks, checkLabels()),
        "",
        _("The exported report includes your recent activity and the KOReader crash log."),
        _("Tap \"Export report\" to save it to a file you can attach to a bug report."),
    }, "\n")

    local viewer
    local buttons = {
        { {
            text = _("Export report"),
            callback = function()
                UIManager:close(viewer)
                plugin:exportDiagnostics()
            end,
        } },
        { {
            text = _("Close"),
            callback = function() UIManager:close(viewer) end,
        } },
    }
    viewer = TextViewer:new{
        title = _("Connection doctor"),
        text = body,
        justified = false,
        auto_para_direction = false,
        buttons_table = buttons,
    }
    UIManager:show(viewer)
end

local function showExportResult(path, bytes, summary)
    local dialog
    local buttons = {
        { {
            text = _("Show report"),
            callback = function()
                UIManager:close(dialog)
                local file = io.open(path, "r")
                local text = file and file:read("*a") or nil
                if file then file:close() end
                if text then
                    showReportText(_("Diagnostic report"), text)
                else
                    Widgets.message(_("Could not read the report."), 5, "warn")
                end
            end,
        } },
    }
    if canCopyToClipboard() then
        buttons[#buttons + 1] = { {
            text = _("Copy summary"),
            callback = function()
                UIManager:close(dialog)
                if copyToClipboard(summary) then
                    Widgets.message(_("Summary copied to the clipboard."))
                else
                    Widgets.message(_("Copying is not supported on this device."), 5, "warn")
                end
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    } }

    dialog = ButtonDialog:new{
        title = string.format(_("Report saved.\n%s\n(%.1f KB)"), path, bytes / 1024),
        buttons = buttons,
        width_factor = 0.9,
    }
    UIManager:show(dialog)
end

-- Absolute plugin data directory: holds login.log and the exported reports.
function DiagnosticsUI:_diagnosticsDir()
    return absolute(Storage.getBaseDir())
end

-- Absolute path of the plugin's trace log, for reports and the status summary.
function DiagnosticsUI:diagnosticLogPath()
    return self:_diagnosticsDir() .. "/login.log"
end

-- Snapshot everything the checks and the report need. All reads are local and
-- fast; the one network call (session validation) happens separately.
function DiagnosticsUI:_diagnosticsContext()
    local provider = self:getProvider()
    local available = false
    if provider then available = provider:is_available() == true end
    local session = Auth.get_session()
    local now = os.time()
    local failed = Queue.failed()
    return {
        online = self:isOnline(),
        provider_id = provider and provider:get_id() or nil,
        provider_available = available,
        authenticated = Auth.is_authenticated() == true,
        session_state = session and session.state or nil,
        session_expired = Auth.session_expired() == true,
        queue_pending = Queue.size(),
        queue_failed = #failed,
        mappings_count = Mappings.count() or 0,
        logging_enabled = Logging.isEnabled() == true,
        last_login = Auth.get_last_login(),
        last_sync_error = self:getSetting("last_sync_error"),
        clock_year = tonumber(os.date("%Y", now)),
        clock_text = os.date("%Y-%m-%d %H:%M", now),
        koreader_version = koreaderVersion(),
        device = deviceModel(),
    }
end

function DiagnosticsUI:_settingsSnapshot()
    local snapshot = {}
    for _i, key in ipairs(Diagnostics.SETTINGS_ALLOWLIST) do
        snapshot[key] = self:getSetting(key)
    end
    return snapshot
end

-- Every run touches the network once, so the doctor and the export share it:
-- validate the saved session in a fork (never on the UI thread) and skip it
-- when offline, since starting Wi-Fi is not this action's job.
function DiagnosticsUI:_withLiveSession(ctx, done)
    if not ctx.online then
        ctx.session_live_skipped = true
        done()
        return
    end
    self:runAsync(function()
        local completed, ok, err = self:runInBackground(
            _("Checking the Goodreads connection…"),
            function() return Auth.validate_session() end)
        if completed == false then return end
        ctx.session_live = Diagnostics.sessionCheck(ok, err)
        done()
    end)
end

function DiagnosticsUI:_stateLines(ctx)
    local lines = {
        "signed_in=" .. tostring(ctx.authenticated),
        "session_state=" .. tostring(ctx.session_state or "unknown"),
        "session_expired=" .. tostring(ctx.session_expired),
        "provider=" .. tostring(ctx.provider_id or "none"),
        "provider_available=" .. tostring(ctx.provider_available),
        "diagnostic_logging=" .. tostring(ctx.logging_enabled),
        string.format("queue_pending=%d queue_failed=%d",
            ctx.queue_pending or 0, ctx.queue_failed or 0),
        "mappings_count=" .. tostring(ctx.mappings_count or 0),
    }
    local last = ctx.last_login
    if last then
        lines[#lines + 1] = string.format("last_login ok=%s stage=%s error=%s at=%s",
            tostring(last.ok), tostring(last.stage), tostring(last.error),
            tostring(last.at))
    end
    if ctx.last_sync_error and ctx.last_sync_error ~= "" then
        lines[#lines + 1] = "last_sync_error=" .. tostring(ctx.last_sync_error)
    end
    return redacted(lines)
end

-- Returns summary, full: the summary is what is shown/copied, the full text
-- (summary + log tails) is what is written to the file.
function DiagnosticsUI:_reportText(ctx, checks, now)
    local counts = Diagnostics.counts(checks)
    local header = {
        "Goodreads KO Sync diagnostic report",
        "generated=" .. Diagnostics.timestamp(now),
        "plugin_version=" .. tostring(Constants.VERSION),
        "plugin_channel=" .. tostring(Constants.CHANNEL),
        "koreader_version=" .. tostring(ctx.koreader_version),
        "device=" .. tostring(ctx.device),
        string.format("checks ok=%d warn=%d fail=%d",
            counts.ok, counts.warn, counts.fail),
    }
    local sections = {
        {
            title = "connection checks",
            lines = { Diagnostics.formatChecks(checks, nil, { compact = true }) },
        },
        { title = "plugin state", lines = self:_stateLines(ctx) },
        {
            title = "settings (allow-listed; no secrets are included)",
            lines = Diagnostics.settingsLines(self:_settingsSnapshot()),
        },
    }
    local summary = Diagnostics.buildReport(header, sections)

    local log_path = self:diagnosticLogPath()
    local log_tail = Diagnostics.tailFile(log_path, LOG_TAIL_BYTES, LOG_TAIL_LINES)
    if log_tail and log_tail ~= "" then
        sections[#sections + 1] = {
            title = string.format("recent activity (%s, last %d lines)",
                log_path, LOG_TAIL_LINES),
            lines = { Logging.redact(log_tail) },
        }
    end
    local crash_path = absolute(crashLogPath())
    local crash_tail = crash_path
        and Diagnostics.tailFile(crash_path, CRASH_TAIL_BYTES, CRASH_TAIL_LINES)
    if crash_tail and crash_tail ~= "" then
        sections[#sections + 1] = {
            title = string.format("KOReader crash log (%s, last %d lines)",
                crash_path, CRASH_TAIL_LINES),
            lines = { Logging.redact(crash_tail) },
        }
    end
    return summary, Diagnostics.buildReport(header, sections)
end

-- Run the connection checks and show the result.
function DiagnosticsUI:runConnectionDoctor()
    local ctx = self:_diagnosticsContext()
    self:_withLiveSession(ctx, function()
        showChecks(self, Diagnostics.evaluate(ctx))
    end)
end

-- Write one self-contained report file next to the plugin's logs and offer to
-- show or copy it.
function DiagnosticsUI:exportDiagnostics()
    local now = os.time()
    local ctx = self:_diagnosticsContext()
    self:_withLiveSession(ctx, function()
        local checks = Diagnostics.evaluate(ctx)
        local summary, full = self:_reportText(ctx, checks, now)
        local path = self:_diagnosticsDir() .. "/" .. Diagnostics.fileName(now)
        local file = io.open(path, "w")
        if not file then
            Widgets.message(_("Could not save the report."), 5, "warn")
            return
        end
        file:write(full)
        file:close()
        Logging.diag("diagnostics: wrote ", path, " (", tostring(#full), " bytes)")
        showExportResult(path, #full, summary)
    end)
end

return DiagnosticsUI
