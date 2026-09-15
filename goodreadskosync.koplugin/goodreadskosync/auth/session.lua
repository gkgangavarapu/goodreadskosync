--[[--
Session state for the Goodreads web provider.

The session is the cookie bundle Goodreads issued at login, plus the
derived CSRF token and the legacy numeric user id. No password is stored here.

@module koplugin.goodreads.auth.session
--]]

local Constants = require("goodreadskosync.constants")
local CryptoUtil = require("goodreadskosync.crypto_util")
local Storage = require("goodreadskosync.storage")

local Session = {}

local function store()
    return Storage.open(Constants.STORAGE.SESSION)
end

function Session.new()
    return {
        cookies = "",
        csrf_token = nil,
        user_id = nil,
        username = nil,
        state = "unknown", -- unknown | valid | expired | blocked
        updated_at = nil,
        last_error = nil,
    }
end

function Session.load()
    local data = store():get("current", {})
    local session = Session.new()
    for key, value in pairs(data or {}) do session[key] = value end
    if session.cookies_encrypted then
        session.cookies = CryptoUtil.unprotect(session.cookies, true)
        session.cookies_encrypted = nil
    end
    return session
end

function Session.save(session)
    session = session or Session.new()
    session.updated_at = os.time()
    local stored = {}
    for key, value in pairs(session) do stored[key] = value end
    if type(session.cookies) == "string" and session.cookies ~= "" then
        local blob, encrypted = CryptoUtil.protect(session.cookies)
        stored.cookies = blob
        stored.cookies_encrypted = encrypted and true or false
    end
    local s = store()
    s:set("current", stored)
    return s:flush()
end

function Session.clear()
    local s = store()
    s:set("current", Session.new())
    return s:flush()
end

function Session.is_valid(session)
    return type(session) == "table"
        and (session.state == "valid" or session.state == "unknown")
        and type(session.cookies) == "string"
        and session.cookies ~= ""
end

function Session.mark_valid(session, fields)
    session.state = "valid"
    session.last_error = nil
    for key, value in pairs(fields or {}) do session[key] = value end
    return session
end

function Session.mark_expired(session, reason)
    session.state = "expired"
    session.last_error = reason or Constants.ERROR.AUTH_REQUIRED
    return session
end

function Session.mark_blocked(session, reason)
    session.state = "blocked"
    session.last_error = reason or Constants.ERROR.SIGNIN_BLOCKED
    return session
end

-- Copy cookie/CSRF/user state from an http.lua object back into the session.
function Session.absorb(session, http)
    session.cookies = http:get_cookie_header()
    if http.csrf_token then session.csrf_token = http.csrf_token end
    if http.user_id then session.user_id = http.user_id end
    return session
end

-- Build an http.lua object preloaded with this session.
function Session.to_http(session, opts)
    local Http = require("goodreadskosync.goodreads.http")
    opts = opts or {}
    return Http:new{
        cookies = session and session.cookies or "",
        csrf_token = session and session.csrf_token or nil,
        user_id = session and session.user_id or nil,
        base_url = opts.base_url,
        timeout = opts.timeout,
        transport = opts.transport,
    }
end

return Session
