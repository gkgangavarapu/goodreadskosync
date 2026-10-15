--[[--
Diagnostic report builder (pure).

Turns a plain snapshot of plugin state into an ordered list of connection
checks and a support-safe text report. There is no KOReader dependency and no
user-facing, translated text here: the UI layer (`ui/diagnostics.lua`) supplies
the labels and gathers the snapshot, which keeps this module unit-testable
off-device.

Every value taken from the device passes through `Logging.redact`, so a
credential can never reach an exported report.

@module koplugin.goodreads.diagnostics
--]]

local Logging = require("goodreadskosync.logging")

local Diagnostics = {}

Diagnostics.STATUS = {
    OK = "ok",
    WARN = "warn",
    FAIL = "fail",
}

-- Check ids, in the order they are shown. `ui/diagnostics.lua` maps each id to
-- a translated name and remedy hints.
Diagnostics.CHECKS = {
    "network",
    "provider",
    "account",
    "session",
    "session_live",
    "queue",
    "clock",
    "logging",
}

-- Settings that may appear in a report. Anything not listed here (the saved
-- password, session cookies, the account id) is never written.
Diagnostics.SETTINGS_ALLOWLIST = {
    "sync_preset", "auto_shelf", "auto_progress", "sync_on_open",
    "sync_on_close", "sync_interval", "track_mode", "track_percent_step",
    "mark_started_immediately", "auto_link", "remember_password",
    "update_progress_after_finished", "conflict_policy", "completion_behavior",
    "update_channel", "logging",
}

local ORDER = {}
for _i, id in ipairs(Diagnostics.CHECKS) do
    ORDER[id] = _i
end

local TAGS = {
    [Diagnostics.STATUS.OK] = "[ OK ]",
    [Diagnostics.STATUS.WARN] = "[WARN]",
    [Diagnostics.STATUS.FAIL] = "[FAIL]",
}

local function check(id, status, detail)
    return { id = id, status = status, detail = detail }
end

-- Tag shown before a check line. ASCII so it stays readable in an exported
-- file regardless of the reader's fonts.
function Diagnostics.tag(status)
    return TAGS[status] or "[????]"
end

-- Sort checks into the canonical display order. Ids not listed in CHECKS are
-- kept, after the known ones.
function Diagnostics.order(checks)
    local out = {}
    for _i, c in ipairs(checks or {}) do
        out[#out + 1] = c
    end
    table.sort(out, function(a, b)
        return (ORDER[a.id] or #Diagnostics.CHECKS + 1)
            < (ORDER[b.id] or #Diagnostics.CHECKS + 1)
    end)
    return out
end

-- Map the outcome of a live session validation into a check. Pure, so the error
-- mapping is covered by tests without touching the network.
function Diagnostics.sessionCheck(ok, err)
    if ok then
        return check("session_live", Diagnostics.STATUS.OK, "validate_session: ok")
    end
    if err == "AUTH_REQUIRED" then
        return check("session_live", Diagnostics.STATUS.FAIL,
            "validate_session: AUTH_REQUIRED")
    end
    if err == "SIGNIN_BLOCKED" then
        return check("session_live", Diagnostics.STATUS.WARN,
            "validate_session: SIGNIN_BLOCKED")
    end
    return check("session_live", Diagnostics.STATUS.WARN,
        "validate_session: " .. tostring(err or "unknown"))
end

-- Build the ordered checks from a snapshot. See ui/diagnostics.lua for the
-- fields; everything is optional so a partial snapshot still renders.
function Diagnostics.evaluate(ctx)
    ctx = ctx or {}
    local S = Diagnostics.STATUS
    local checks = {}

    if ctx.online == false then
        checks[#checks + 1] = check("network", S.FAIL, "offline")
    else
        checks[#checks + 1] = check("network", S.OK, "online")
    end

    if not ctx.provider_id then
        checks[#checks + 1] = check("provider", S.FAIL, "none registered")
    elseif ctx.provider_available then
        checks[#checks + 1] = check("provider", S.OK,
            string.format("provider=%s available=true", ctx.provider_id))
    else
        checks[#checks + 1] = check("provider", S.FAIL,
            string.format("provider=%s available=false", ctx.provider_id))
    end

    if ctx.authenticated then
        checks[#checks + 1] = check("account", S.OK, "signed_in=true")
    else
        checks[#checks + 1] = check("account", S.FAIL, "signed_in=false")
    end

    local session_detail = string.format("state=%s expired=%s",
        tostring(ctx.session_state or "unknown"),
        tostring(ctx.session_expired == true))
    if not ctx.authenticated then
        checks[#checks + 1] = check("session", S.WARN, session_detail)
    elseif ctx.session_expired then
        checks[#checks + 1] = check("session", S.FAIL, session_detail)
    else
        checks[#checks + 1] = check("session", S.OK, session_detail)
    end

    if ctx.session_live then
        checks[#checks + 1] = ctx.session_live
    elseif ctx.session_live_skipped then
        checks[#checks + 1] = check("session_live", S.WARN, "validate_session: skipped (offline)")
    end

    local pending = tonumber(ctx.queue_pending) or 0
    local failed = tonumber(ctx.queue_failed) or 0
    local queue_detail = string.format("pending=%d failed=%d", pending, failed)
    if failed > 0 then
        checks[#checks + 1] = check("queue", S.WARN, queue_detail)
    else
        checks[#checks + 1] = check("queue", S.OK, queue_detail)
    end

    local year = tonumber(ctx.clock_year)
    local clock_detail = string.format("device_clock=%s",
        tostring(ctx.clock_text or year or "unknown"))
    if year and (year < 2020 or year > 2100) then
        checks[#checks + 1] = check("clock", S.FAIL, clock_detail)
    else
        checks[#checks + 1] = check("clock", S.OK, clock_detail)
    end

    if ctx.logging_enabled then
        checks[#checks + 1] = check("logging", S.OK, "diagnostic_logging=true")
    else
        checks[#checks + 1] = check("logging", S.WARN, "diagnostic_logging=false")
    end

    return Diagnostics.order(checks)
end

-- Tally the checks by status.
function Diagnostics.counts(checks)
    local counts = { ok = 0, warn = 0, fail = 0 }
    for _i, c in ipairs(checks or {}) do
        local key = c.status
        if counts[key] then counts[key] = counts[key] + 1 end
    end
    return counts
end

-- Coarse outcome for the headline: "fail", "warn" or "ok".
function Diagnostics.verdict(counts)
    counts = counts or {}
    if (counts.fail or 0) > 0 then return Diagnostics.STATUS.FAIL end
    if (counts.warn or 0) > 0 then return Diagnostics.STATUS.WARN end
    return Diagnostics.STATUS.OK
end

-- Render checks for the screen (multi-line, indented detail + hint) or for a
-- file (opts.compact, one line per check, ids instead of translated names).
-- `labels` is id -> { name = <string>, hints = { fail = <string>, ... } }.
function Diagnostics.formatChecks(checks, labels, opts)
    opts = opts or {}
    local out = {}
    for _i, c in ipairs(checks or {}) do
        local entry = labels and labels[c.id] or nil
        local name = (entry and entry.name) or c.id
        local detail = c.detail or ""
        if opts.compact then
            out[#out + 1] = string.format("%s %s: %s",
                Diagnostics.tag(c.status), c.id, detail)
        else
            out[#out + 1] = string.format("%s %s", Diagnostics.tag(c.status), name)
            if detail ~= "" then
                out[#out + 1] = "       " .. detail
            end
            local hint = entry and entry.hints and entry.hints[c.status]
            if hint and c.status ~= Diagnostics.STATUS.OK then
                out[#out + 1] = "       -> " .. hint
            end
        end
    end
    return table.concat(out, "\n")
end

-- Keep only the last `max_lines` lines.
function Diagnostics.tail(text, max_lines)
    if not text or text == "" then return "" end
    -- Normalize to a trailing newline so the split yields exactly the lines and
    -- never a phantom empty one at the end.
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    local lines = {}
    for line in text:gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    local first = 1
    if max_lines and #lines > max_lines then
        first = #lines - max_lines + 1
    end
    local out = {}
    for i = first, #lines do
        out[#out + 1] = lines[i]
    end
    return table.concat(out, "\n")
end

-- Tail a file without loading it all into memory: seek to the last `max_bytes`
-- and keep the last `max_lines` lines. Returns nil when the file is unreadable.
function Diagnostics.tailFile(path, max_bytes, max_lines)
    if not path then return nil end
    local file = io.open(path, "r")
    if not file then return nil end
    local size = file:seek("end") or 0
    local start = math.max(0, size - (max_bytes or 65536))
    file:seek("set", start)
    local data = file:read("*a") or ""
    file:close()
    if start > 0 then
        -- Drop the partial first line produced by seeking into the middle.
        local nl = data:find("\n", 1, true)
        if nl then data = data:sub(nl + 1) end
    end
    return Diagnostics.tail(data, max_lines)
end

-- Allow-listed, redacted settings as `key=value` lines.
function Diagnostics.settingsLines(settings, allowlist)
    local out = {}
    for _i, key in ipairs(allowlist or Diagnostics.SETTINGS_ALLOWLIST) do
        local value = settings and settings[key]
        if value ~= nil then
            out[#out + 1] = string.format("%s=%s", key, Logging.redact(value))
        end
    end
    return out
end

-- Assemble the report text from a header and titled sections.
function Diagnostics.buildReport(header_lines, sections)
    local out = {}
    for _i, line in ipairs(header_lines or {}) do
        out[#out + 1] = line
    end
    for _i, section in ipairs(sections or {}) do
        out[#out + 1] = ""
        out[#out + 1] = "## " .. tostring(section.title or "")
        for _j, line in ipairs(section.lines or {}) do
            out[#out + 1] = line
        end
    end
    return table.concat(out, "\n") .. "\n"
end

function Diagnostics.timestamp(now)
    return os.date("%Y-%m-%d %H:%M:%S", now or os.time())
end

-- Make a path absolute so it is usable in a report or on screen. KOReader's
-- data directory is relative on some setups (it is "." on Kindle, resolved
-- against the process working directory), which tells a reader nothing. Pure:
-- the caller supplies the working directory.
function Diagnostics.absolutePath(path, cwd)
    if not path or path == "" then return path end
    if path:sub(1, 1) == "/" then return path end
    if not cwd or cwd == "" or cwd:sub(1, 1) ~= "/" then return path end
    local relative = path:gsub("^%./", "")
    if cwd:sub(-1) == "/" then return cwd .. relative end
    return cwd .. "/" .. relative
end

-- Stable, sortable file name for an exported report.
function Diagnostics.fileName(now)
    return "goodreads-diagnostics-" .. os.date("%Y%m%d-%H%M%S", now or os.time()) .. ".txt"
end

return Diagnostics
