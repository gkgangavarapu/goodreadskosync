--[[--
Cover image cache for the native (browser-free) Goodreads UI.

Downloads book covers with the plugin's existing authenticated session and keeps
them in a bounded on-disk cache, so shelf lists and book pages can show real
thumbnails without the HTML reader. Pure decision logic (paths, pruning) is
separated from I/O so it can be unit tested.

@module koplugin.goodreads.covers
--]]

local Covers = {}

local function deps()
    local Storage = require("goodreadskosync.storage")
    local Images = require("goodreadskosync.browse.images")
    local Util = require("goodreadskosync.util")
    return Storage, Images, Util
end

-- Directory holding downloaded covers (created on demand).
function Covers.dir()
    local Storage = deps()
    return Storage.getBaseDir() .. "/goodreads-covers"
end

function Covers.ensureDir(dir)
    local Storage = deps()
    dir = dir or (Storage.getBaseDir() .. "/goodreads-covers")
    -- `mkdir -p` via os.execute is what the storage layer uses and is reliable
    -- on Kindle/busybox; ffi/util.makePath is kept as a best-effort fallback.
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil and ffiutil.makePath then
        pcall(ffiutil.makePath, dir)
    end
    pcall(os.execute, 'mkdir -p "' .. dir .. '" 2>/dev/null')
    return dir
end

-- Deterministic cache path for a cover URL (same URL always maps to one file).
function Covers.pathFor(url, dir)
    local Storage, Images, Util = deps()
    if type(url) ~= "string" or url == "" then return nil end
    dir = dir or (Storage.getBaseDir() .. "/goodreads-covers")
    return dir .. "/" .. Util.sha256Hex(url):sub(1, 20) .. "." .. Images.extension(url)
end

function Covers.exists(path)
    if not path then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- Return the cached file for a URL, or nil when it has not been downloaded yet.
function Covers.cached(url)
    local path = Covers.pathFor(url)
    return Covers.exists(path) and path or nil
end

-- Download (or reuse) a cover and return its local path, or nil on failure.
-- Never throws: image handling must never break a shelf.
function Covers.fetch(url, opts)
    opts = opts or {}
    if type(url) ~= "string" or url == "" then return nil end
    local path = Covers.pathFor(url)
    if Covers.exists(path) then return path end
    Covers.ensureDir()
    local max_bytes = opts.max_bytes or 3000000
    local ok, file = pcall(function()
        local Session = require("goodreadskosync.auth.session")
        local http = Session.to_http(Session.load())
        local resp = http:get(url, { follow = true, detect_auth = false })
        if not resp or resp.error then return nil end
        local body = resp.body
        if type(body) ~= "string" or #body == 0 or #body > max_bytes then return nil end
        local f = io.open(path, "wb")
        if not f then return nil end
        f:write(body)
        f:close()
        return path
    end)
    if not ok then return nil end
    return file
end

-- Keep the on-disk cache bounded (missing directory is a no-op).
function Covers.prune(keep)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_lfs and lfs) then return 0 end
    local Images = deps()
    return Images.prune(Covers.dir(), keep or 120, lfs)
end

return Covers
