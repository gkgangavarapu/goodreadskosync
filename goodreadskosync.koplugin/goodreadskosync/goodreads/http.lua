--[[--
Session-aware HTTP transport for Goodreads.

Responsibilities:
  * maintain a raw Cookie header (Goodreads auth is a cookie bundle, not a
    single token);
  * merge and rotate cookies from Set-Cookie on every hop;
  * follow redirects manually so cookies survive the hop;
  * classify responses into the plugin's normalized error codes.

The transport itself is injectable so the whole layer can be unit tested
without network access. HTTPS only; certificate validation is never disabled.

@module koplugin.goodreads.goodreads.http
--]]

local Constants = require("goodreadskosync.constants")

local Http = {}
Http.__index = Http

local USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0"

local COOKIE_ATTR = {
    path = true, domain = true, expires = true, ["max-age"] = true,
    samesite = true, secure = true, httponly = true, version = true,
    partitioned = true, ["same-site"] = true,
}

-- A stale short-lived GraphQL JWT in the Cookie header makes Goodreads reject
-- the whole request, so it is always dropped.
local COOKIE_DROP = { jwt_token = true }

local SIGN_IN_MARKERS = {
    "/user/sign_in",
    "/ap/signin",
    'name="email"',
    "something wrong with your Goodreads cookie",
}

--------------------------------------------------------------------------------
-- Cookie helpers
--------------------------------------------------------------------------------

function Http.sanitizeCookie(header)
    if type(header) ~= "string" or header == "" then return "" end
    local jar, order = {}, {}
    for name, value in header:gmatch("([%w_%-%.]+)=([^;]*)") do
        local lname = name:lower()
        if not COOKIE_ATTR[lname] and not COOKIE_DROP[name] and not COOKIE_DROP[lname] then
            value = value:match("^%s*(.-)%s*$") or value
            if value ~= "" then
                if not jar[name] then order[#order + 1] = name end
                jar[name] = value
            end
        end
    end
    local parts = {}
    for _, name in ipairs(order) do
        parts[#parts + 1] = name .. "=" .. jar[name]
    end
    return table.concat(parts, "; ")
end

-- LuaSocket comma-folds repeated Set-Cookie headers and Expires values also
-- contain commas, so walk name=value pairs and skip attribute keys.
function Http.mergeSetCookie(jar, set_cookie)
    if type(set_cookie) ~= "string" or set_cookie == "" then
        return Http.sanitizeCookie(jar)
    end
    local parsed = {}
    for name, value in (jar or ""):gmatch("([%w_%-%.]+)=([^;]*)") do
        if not COOKIE_ATTR[name:lower()] and not COOKIE_DROP[name] then
            parsed[#parsed + 1] = { name, value }
        end
    end
    for name, value in set_cookie:gmatch("([%w_%-%.]+)=([^;,]*)") do
        local lname = name:lower()
        if not COOKIE_ATTR[lname] and not COOKIE_DROP[name] and not COOKIE_DROP[lname] then
            value = value:match("^%s*(.-)%s*$") or value
            if value ~= "" then parsed[#parsed + 1] = { name, value } end
        end
    end
    local jar_map, order = {}, {}
    for _, pair in ipairs(parsed) do
        if not jar_map[pair[1]] then order[#order + 1] = pair[1] end
        jar_map[pair[1]] = pair[2]
    end
    local parts = {}
    for _, name in ipairs(order) do
        parts[#parts + 1] = name .. "=" .. jar_map[name]
    end
    return table.concat(parts, "; ")
end

--------------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------------

local function urlencode(value)
    if value == nil then return "" end
    value = tostring(value)
    value = value:gsub("\n", "\r\n")
    value = value:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return value
end

function Http.urlencode(value)
    return urlencode(value)
end

function Http.encodeForm(data)
    local parts = {}
    for key, value in pairs(data or {}) do
        parts[#parts + 1] = urlencode(key) .. "=" .. urlencode(value)
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

function Http.absolute(base, location)
    if not location or location == "" then return location end
    if location:match("^https?://") then return location end
    if location:sub(1, 2) == "//" then return "https:" .. location end
    local scheme_host = base:match("^(https?://[^/]+)")
    if location:sub(1, 1) == "/" then
        return (scheme_host or base) .. location
    end
    return (scheme_host or base) .. "/" .. location
end

--------------------------------------------------------------------------------
-- Default transport
--------------------------------------------------------------------------------

local function default_transport(req)
    local ok_http, http = pcall(require, "socket.http")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    local ok_sutil, socketutil = pcall(require, "socketutil")
    if not ok_http or not ok_ltn12 then
        return false, nil, nil, nil
    end

    local sink = {}
    local request = {
        url = req.url,
        method = req.method or "GET",
        headers = req.headers or {},
        sink = ltn12.sink.table(sink),
        redirect = false,
    }
    if req.body then request.source = ltn12.source.string(req.body) end

    if ok_sutil and socketutil then
        socketutil:set_timeout(req.timeout or 15, (req.timeout or 15) * 2)
    end
    -- LuaSocket's http.request returns (1, code, headers, statusline) on
    -- success or (nil, error). The first value is the success indicator, not
    -- the HTTP status code.
    local call_ok, ok, code, headers = pcall(http.request, request)
    if ok_sutil and socketutil then socketutil:reset_timeout() end

    if not call_ok or not ok then
        return false, nil, nil, nil
    end
    return true, code, headers, table.concat(sink)
end

local function normalize_headers(headers)
    local normalized = {}
    if type(headers) ~= "table" then return normalized end
    for key, value in pairs(headers) do
        normalized[tostring(key):lower()] = value
    end
    return normalized
end

--------------------------------------------------------------------------------
-- Http object
--------------------------------------------------------------------------------

function Http:new(opts)
    opts = opts or {}
    return setmetatable({
        cookies = Http.sanitizeCookie(opts.cookies or ""),
        csrf_token = opts.csrf_token,
        user_id = opts.user_id,
        base_url = opts.base_url or "https://www.goodreads.com",
        timeout = opts.timeout or 15,
        max_hops = opts.max_hops or 6,
        transport = opts.transport or default_transport,
    }, self)
end

function Http:get_cookie_header()
    return self.cookies
end

function Http:set_cookie_header(cookie)
    self.cookies = Http.sanitizeCookie(cookie or "")
end

function Http:has_cookies()
    return self.cookies ~= nil and self.cookies ~= ""
end

local function base_headers(self, method)
    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Accept-Language"] = "en-US,en;q=0.9",
        ["Referer"] = self.base_url .. "/",
    }
    if self.cookies and self.cookies ~= "" then
        headers["Cookie"] = self.cookies
    end
    if method == "POST" then
        headers["Accept"] = "*/*"
        headers["Origin"] = self.base_url
        headers["X-Requested-With"] = "XMLHttpRequest"
        headers["Sec-Fetch-Site"] = "same-origin"
        headers["Sec-Fetch-Mode"] = "cors"
        headers["Sec-Fetch-Dest"] = "empty"
    else
        headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        headers["Sec-Fetch-Site"] = "same-origin"
        headers["Sec-Fetch-Mode"] = "navigate"
        headers["Sec-Fetch-Dest"] = "document"
        headers["Sec-Fetch-User"] = "?1"
        headers["Upgrade-Insecure-Requests"] = "1"
    end
    return headers
end

-- Some sign-in requests are intercepted before they reach the app page. We
-- detect this generically (an accepted-but-empty status, or a response header
-- carrying a challenge marker) without hard-coding any provider specifics.
local function is_intercepted(status, headers)
    if status == 202 then return true end
    if headers then
        for _, value in pairs(headers) do
            if type(value) == "string" and value:lower():find("challenge", 1, true) then
                return true
            end
        end
    end
    return false
end

local function classify(status, headers)
    if is_intercepted(status, headers) then
        return Constants.ERROR.SIGNIN_BLOCKED
    end
    if status == nil then return Constants.ERROR.NETWORK_ERROR end
    if status >= 200 and status < 300 then return nil end
    if status == 401 or status == 403 then return Constants.ERROR.AUTH_REQUIRED end
    if status == 404 then return Constants.ERROR.NOT_FOUND end
    if status == 409 then return Constants.ERROR.CONFLICT end
    if status == 422 then return Constants.ERROR.INVALID_REQUEST end
    if status == 429 then return Constants.ERROR.RATE_LIMITED end
    if status >= 500 then return Constants.ERROR.SERVER_ERROR end
    return Constants.ERROR.INVALID_RESPONSE
end

local function looks_like_sign_in(url, body)
    if url then
        for _, marker in ipairs(SIGN_IN_MARKERS) do
            if url:find(marker, 1, true) then return true end
        end
    end
    if body then
        if body:find('name="email"', 1, true) and body:find("/ap/signin", 1, true) then
            return true
        end
        if body:find("something wrong with your Goodreads cookie", 1, true) then
            return true
        end
    end
    return false
end

-- Perform a request. opts:
--   body, headers, follow (default true), detect_auth (default true),
--   csrf (bool: attach X-CSRF-Token)
-- Returns a response table:
--   { status, body, headers, url, error, blocked }
function Http:request(method, url, opts)
    opts = opts or {}
    method = method or "GET"
    local current_url = url
    local current_method = method
    local current_body = opts.body
    local hops = 0
    local last = { status = nil, body = nil, headers = {}, url = url }

    while true do
        local headers = base_headers(self, current_method)
        if opts.headers then
            for k, v in pairs(opts.headers) do headers[k] = v end
        end
        if current_body and not headers["Content-Type"] then
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        end
        if current_body then
            headers["Content-Length"] = tostring(#current_body)
        end
        if opts.csrf and self.csrf_token then
            headers["X-CSRF-Token"] = self.csrf_token
        end
        if self.cookies and self.cookies ~= "" then
            headers["Cookie"] = self.cookies
        end

        local transport_ok, status, raw_headers, body = self.transport({
            url = current_url,
            method = current_method,
            headers = headers,
            body = current_body,
            timeout = self.timeout,
        })
        if not transport_ok then status = nil end
        local resp_headers = normalize_headers(raw_headers)

        -- Rotate cookies before any redirect decision.
        local set_cookie = resp_headers["set-cookie"]
        if set_cookie then
            self.cookies = Http.mergeSetCookie(self.cookies, set_cookie)
        end

        last = {
            status = status,
            body = body,
            headers = resp_headers,
            url = current_url,
        }

        local location = resp_headers["location"]
        local is_redirect = status == 301 or status == 302 or status == 303
            or status == 307 or status == 308

        if opts.follow ~= false and is_redirect and location and hops < self.max_hops then
            current_url = Http.absolute(current_url, location)
            if status == 301 or status == 302 or status == 303 then
                current_method = "GET"
                current_body = nil
            end
            hops = hops + 1
        else
            break
        end
    end

    local error_code = classify(last.status, last.headers)
    local blocked = is_intercepted(last.status, last.headers)

    if opts.detect_auth ~= false and not error_code then
        if looks_like_sign_in(last.url, last.body) then
            error_code = Constants.ERROR.AUTH_REQUIRED
        end
    end

    last.error = error_code
    last.blocked = blocked
    return last
end

function Http:get(url, opts)
    return self:request("GET", url, opts)
end

function Http:post_form(url, form, opts)
    opts = opts or {}
    local body = type(form) == "string" and form or Http.encodeForm(form)
    local request_opts = {
        body = body,
        headers = opts.headers,
        follow = opts.follow,
        detect_auth = opts.detect_auth,
        csrf = opts.csrf,
    }
    return self:request("POST", url, request_opts)
end

Http.default_transport = default_transport
Http._classify = classify
Http._looks_like_sign_in = looks_like_sign_in

return Http
