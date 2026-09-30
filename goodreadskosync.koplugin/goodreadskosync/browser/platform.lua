--[[--
Platform abstraction for the generic browser.

This is the **only** place the browser touches OS facilities (processes, files,
temp dirs). Engine implementations receive a platform object so they stay free
of direct filesystem/process/display assumptions, and so tests can inject a
fake.

Methods:
    run(argv)        -> ok, stdout, stderr, exit_code
    read(path)       -> string | nil
    write(path,data) -> true|false
    remove(path)     -> void
    exists(path)     -> bool
    tmp_dir()        -> string

`Platform.new(overrides)` returns an object with any subset overridden.

@module koplugin.goodreads.browser.platform
--]]

local Platform = {}

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local DEFAULTS = {}

function DEFAULTS:tmp_dir()
    return os.getenv("TMPDIR") or "/tmp"
end

function DEFAULTS:run(argv)
    local parts = {}
    for i = 1, #argv do parts[i] = shell_quote(argv[i]) end
    local cmd = table.concat(parts, " ") .. " 2>&1"
    local handle = io.popen(cmd)
    if not handle then return nil, "", "io.popen failed", -1 end
    local out = handle:read("*a") or ""
    local ok = handle:close()
    local code = 0
    if ok == nil then code = 1 end
    return true, out, "", code
end

function DEFAULTS:read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

function DEFAULTS:write(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

function DEFAULTS:remove(path)
    os.remove(path)
end

function DEFAULTS:exists(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

-- Returns a platform object; `overrides` replaces any subset of methods.
function Platform.new(overrides)
    local obj = {}
    for k, v in pairs(DEFAULTS) do obj[k] = v end
    for k, v in pairs(overrides or {}) do obj[k] = v end
    return obj
end

return Platform
