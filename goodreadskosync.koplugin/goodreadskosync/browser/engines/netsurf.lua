--[[--
NetSurf browser engine adapter (second local engine).

NetSurf has no embeddable "library" entry point, so it is driven through the
small native helper in `engines/netsurf/` (`netsurf_render`). The helper uses
NetSurf's core with an libnsfb **memory** surface and never touches /dev/fb0.
It writes an 8-bit PGM frame plus a JSON hitmap; this adapter runs it, reads
those files, and exposes the standard BrowserEngine contract.

The helper is optional: until it is built and present on the device, the host
keeps using the CRE fallback engine.

Contract implemented (see koplugin.goodreads.browser.engine):
  load() render() tap() scroll() back() forward() reload()
  title() url() capabilities()

@module koplugin.goodreads.browser.engines.netsurf
--]]

local Json = require("goodreadskosync.goodreads.json")
local Logging = require("goodreadskosync.logging")

local NetSurf = {}
NetSurf.__index = NetSurf

NetSurf.name = "netsurf"

-- Advertised capabilities. js is false until QuickJS (or similar) is added.
local CAPS = {
    js = false,
    css = "2.1",
    images = true,
    links = true,
    forms = true,
    https = true,
}

-- Escape one argument for POSIX sh.
local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Default runner: run the helper, return ok, stdout, stderr, exit_code.
-- Overridable via `opts.runner` so the adapter is testable without the binary.
local function default_runner(argv)
    local parts = {}
    for i = 1, #argv do parts[i] = shell_quote(argv[i]) end
    local cmd = table.concat(parts, " ") .. " 2>&1"
    Logging.trace("netsurf: exec ", cmd)
    local handle = io.popen(cmd)
    if not handle then return nil, "", "io.popen failed", -1 end
    local out = handle:read("*a") or ""
    local ok = handle:close()
    -- Lua 5.1 returns true/nil; a numeric code is returned on some builds.
    local code = 0
    if ok == nil then code = 1 end
    return true, out, "", code
end

-- Read a whole file as a binary string.
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Parse a binary PGM (P5) into width/height/pixels. Pure, unit-testable.
function NetSurf.parse_pgm(data)
    if type(data) ~= "string" or data == "" then return nil, "empty" end
    if data:sub(1, 2) ~= "P5" then return nil, "not P5" end
    local pos = 3
    local function token()
        while pos <= #data do
            local c = data:sub(pos, pos)
            if c == "#" then
                pos = (data:find("\n", pos, true) or #data) + 1
            elseif c:match("%s") then
                pos = pos + 1
            else
                break
            end
        end
        local start = pos
        while pos <= #data and not data:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        return data:sub(start, pos - 1)
    end
    local width = tonumber(token())
    local height = tonumber(token())
    local maxval = tonumber(token())
    if not (width and height and maxval) then return nil, "bad header" end
    local pixels = data:sub(pos + 1)
    return { width = width, height = height, maxval = maxval, pixels = pixels }
end

-- Topmost hit region containing (x, y), or nil. Pure, unit-testable.
function NetSurf.hit_at(hits, x, y)
    local list = hits or {}
    for i = #list, 1, -1 do
        local r = list[i]
        local rx, ry = tonumber(r.x) or 0, tonumber(r.y) or 0
        local rw, rh = tonumber(r.w) or 0, tonumber(r.h) or 0
        if x >= rx and x < rx + rw and y >= ry and y < ry + rh then
            return r
        end
    end
    return nil
end

-- opts: bin, cookie_file, viewport = {w, h}, runner, tmp_dir
function NetSurf.new(opts)
    opts = opts or {}
    local self = setmetatable({}, NetSurf)
    self.bin = opts.bin or ""
    self.cookie_file = opts.cookie_file or ""
    self.runner = opts.runner or default_runner
    self.tmp_dir = opts.tmp_dir or "/tmp"
    self.viewport = {
        w = tonumber(opts.viewport and opts.viewport.w) or 600,
        h = tonumber(opts.viewport and opts.viewport.h) or 800,
    }
    self._url = "about:blank"
    self._title = ""
    self._history = {}
    self._index = 0
    self._scroll_y = 0
    self._frame = nil
    self._seq = 0
    return self
end

function NetSurf:capabilities() return CAPS end

function NetSurf:title() return self._title or "" end

function NetSurf:url() return self._url or "about:blank" end

-- Parse a "name=value; name2=value2" Cookie header into Netscape cookie-file
-- lines that NetSurf's cookie jar understands. Pure, unit-testable.
-- tab-separated: domain, includeSubdomains, path, secure, expiry, name, value
function NetSurf.netscape_cookie_lines(header, domain, expires)
    local lines = {}
    if type(header) ~= "string" or header == "" then return lines end
    domain = domain or ".goodreads.com"
    local include = (domain:sub(1, 1) == ".") and "TRUE" or "FALSE"
    local expiry = tostring(tonumber(expires) or 0)
    for pair in header:gmatch("[^;]+") do
        local name, value = pair:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if name and name ~= "" and value then
            lines[#lines + 1] = table.concat(
                { domain, include, "/", "FALSE", expiry, name, value }, "\t")
        end
    end
    return lines
end

-- Write the session cookies to the helper's Netscape cookie jar (best effort).
function NetSurf:set_cookies(cookie_header, domain, expires)
    if not self.cookie_file or self.cookie_file == "" then return end
    local lines = NetSurf.netscape_cookie_lines(cookie_header, domain, expires)
    if #lines == 0 then return end
    local f = io.open(self.cookie_file, "w")
    if not f then return end
    f:write("# Netscape HTTP Cookie File\n")
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
end

-- Run the helper for `url` at the stored viewport/scroll. Returns true, or nil+err.
function NetSurf:_invoke(url, scroll_y)
    if self.bin == "" then return nil, "no helper binary" end
    self._seq = self._seq + 1
    local prefix = string.format("%s/netsurf-%d", self.tmp_dir, self._seq)
    local argv = {
        self.bin,
        "--url", url,
        "--width", tostring(self.viewport.w),
        "--height", tostring(self.viewport.h),
        "--scroll", tostring(scroll_y or 0),
        "--out", prefix,
    }
    if self.cookie_file and self.cookie_file ~= "" then
        argv[#argv + 1] = "--cookies"
        argv[#argv + 1] = self.cookie_file
    end
    local ok, out, err, code = self.runner(argv)
    if not ok then return nil, err or "runner failed" end
    if code and code ~= 0 then
        Logging.trace("netsurf: helper failed code=", tostring(code), " out=", tostring(out))
        return nil, "helper exit " .. tostring(code)
    end
    local meta_raw = read_file(prefix .. ".json")
    local pgm_raw = read_file(prefix .. ".pgm")
    if not meta_raw or not pgm_raw then return nil, "missing output files" end
    os.remove(prefix .. ".json")
    os.remove(prefix .. ".pgm")
    local meta = Json.decode(meta_raw)
    if type(meta) ~= "table" then return nil, "bad meta json" end
    local pgm = NetSurf.parse_pgm(pgm_raw)
    if not pgm then return nil, "bad pgm" end
    meta.width = meta.width or pgm.width
    meta.height = meta.height or pgm.height
    meta.bitmap = pgm.pixels
    meta.hits = meta.hits or {}
    self._frame = meta
    self._url = meta.url or url
    self._title = meta.title or self._title
    self._scroll_y = tonumber(meta.scroll_y) or (scroll_y or 0)
    return true
end

-- load(url, cookies, viewport) -> ok, err
function NetSurf:load(url, cookies, viewport)
    if url and url ~= "" then self._url = url end
    if viewport then
        self.viewport = {
            w = tonumber(viewport.w) or self.viewport.w,
            h = tonumber(viewport.h) or self.viewport.h,
        }
    end
    if cookies then self:set_cookies(cookies) end
    local ok, err = self:_invoke(self._url, 0)
    if not ok then return nil, err end
    -- Record history only after a successful load.
    while #self._history > self._index do table.remove(self._history) end
    self._history[#self._history + 1] = self._url
    self._index = #self._history
    return true
end

-- render() -> { bitmap, width, height, scroll_h, hits }
function NetSurf:render()
    local frame = self._frame
    if not frame then
        return { bitmap = "", width = 0, height = 0, scroll_h = 0, hits = {} }
    end
    return {
        bitmap = frame.bitmap,
        width = frame.width,
        height = frame.height,
        scroll_h = frame.scroll_h or frame.height,
        scroll_y = frame.scroll_y or self._scroll_y,
        hits = frame.hits,
    }
end

-- tap(x, y) -> ok, action. Follows a link when one is hit.
function NetSurf:tap(x, y)
    local hit = NetSurf.hit_at(self._frame and self._frame.hits, x, y)
    if not hit then return true end
    if hit.href and hit.href ~= "" then
        local ok, err = self:load(hit.href)
        if not ok then return nil, err end
        return true, "navigate"
    end
    return true, hit.action
end

-- scroll(dx, dy) -> ok
function NetSurf:scroll(_dx, dy)
    local next_y = math.max(0, (self._scroll_y or 0) + (tonumber(dy) or 0))
    self._scroll_y = next_y
    return self:_invoke(self._url, next_y)
end

function NetSurf:_goto(index)
    local url = self._history[index]
    if not url then return nil, "no history" end
    local ok, err = self:_invoke(url, 0)
    if not ok then return nil, err end
    self._index = index
    self._scroll_y = 0
    return true
end

function NetSurf:back()
    if self._index <= 1 then return nil, "no back" end
    return self:_goto(self._index - 1)
end

function NetSurf:forward()
    if self._index >= #self._history then return nil, "no forward" end
    return self:_goto(self._index + 1)
end

function NetSurf:reload()
    return self:_invoke(self._url, self._scroll_y or 0)
end

return NetSurf
