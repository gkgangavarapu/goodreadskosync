--[[--
Authentication manager.

Owns provider discovery/selection (moved here from the old auth.lua) and the
Goodreads session lifecycle. The rest of the plugin talks to this module, never
to a concrete login mechanism, so the mechanism can be replaced later.

@module koplugin.goodreads.auth.manager
--]]

local Constants = require("goodreadskosync.constants")
local Logging = require("goodreadskosync.logging")
local Session = require("goodreadskosync.auth.session")

local Manager = {}

local PROVIDER_MODULES = {
    [Constants.PROVIDER.GOODREADS_WEB] = "goodreadskosync.providers.goodreads_web",
    [Constants.PROVIDER.NATIVE_KINDLE] = "goodreadskosync.providers.native_kindle",
    [Constants.PROVIDER.OFFICIAL_API] = "goodreadskosync.providers.official_api",
    [Constants.PROVIDER.MOCK] = "goodreadskosync.providers.mock",
}

--------------------------------------------------------------------------------
-- Provider discovery / selection
--------------------------------------------------------------------------------

local function load_provider_class(id)
    local module_name = PROVIDER_MODULES[id]
    if not module_name then return nil end
    local ok, class = pcall(require, module_name)
    if not ok or type(class) ~= "table" then
        Logging.trace("auth: could not load provider", id)
        return nil
    end
    return class
end

function Manager.discover(opts)
    opts = opts or {}
    local discovered = {}
    for _, id in ipairs(Constants.PROVIDER_ORDER) do
        local class = load_provider_class(id)
        if class then
            local instance = class:new(opts.providers and opts.providers[id])
            local available, reason = instance:is_available()
            local implemented = true
            if type(instance.is_implemented) == "function" then
                implemented = instance:is_implemented()
            end
            discovered[#discovered + 1] = {
                id = id,
                name = instance:get_display_name(),
                available = available and true or false,
                implemented = implemented and true or false,
                reason = reason,
                provider = instance,
            }
        end
    end
    return discovered
end

function Manager.auto_select(discovered)
    for _, entry in ipairs(discovered) do
        if entry.available and entry.implemented then
            return entry
        end
    end
    return nil
end

local function account_store()
    local Storage = require("goodreadskosync.storage")
    return Storage.open(Constants.STORAGE.ACCOUNT)
end

function Manager.get_selected_id()
    return account_store():get("provider")
end

function Manager.set_selected_id(id)
    local store = account_store()
    store:set("provider", id)
    return store:flush()
end

function Manager.clear_selection()
    local store = account_store()
    store:delete("provider")
    return store:flush()
end

function Manager.get_provider(opts)
    opts = opts or {}
    local discovered = Manager.discover(opts)
    local selected_id = opts.provider_id or Manager.get_selected_id()

    if selected_id then
        for _, entry in ipairs(discovered) do
            if entry.id == selected_id and entry.available then
                return entry.provider, entry
            end
        end
    end

    local auto = Manager.auto_select(discovered)
    if auto then return auto.provider, auto end
    return nil, nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

--------------------------------------------------------------------------------
-- Session lifecycle
--------------------------------------------------------------------------------

function Manager.get_session()
    return Session.load()
end

function Manager.is_authenticated()
    return Session.is_valid(Session.load())
end

function Manager.session_expired()
    local session = Session.load()
    return session.state == "expired"
end

local function parse_csrf(html)
    if type(html) ~= "string" then return nil end
    return html:match('<meta%s+[^>]-name=["\']csrf%-token["\']%s+[^>]-content=["\']([^"\']+)["\']')
        or html:match('<meta%s+[^>]-content=["\']([^"\']+)["\']%s+[^>]-name=["\']csrf%-token["\']')
end

local function parse_user_id(html)
    if type(html) ~= "string" then return nil end
    return html:match("/user/show/(%d+)")
end

-- Verify the stored session against Goodreads and refresh CSRF/user id.
-- Returns ok, error.
function Manager.validate_session(opts)
    opts = opts or {}
    local session = Session.load()
    if not session.cookies or session.cookies == "" then
        return false, Constants.ERROR.AUTH_REQUIRED
    end

    local http = Session.to_http(session, opts)
    local resp = http:get(http.base_url .. "/review/list", { follow = true, detect_auth = true })

    if resp.error == Constants.ERROR.SIGNIN_BLOCKED then
        Session.mark_blocked(session, Constants.ERROR.SIGNIN_BLOCKED)
        Session.save(session)
        return false, Constants.ERROR.SIGNIN_BLOCKED
    end
    if resp.error == Constants.ERROR.AUTH_REQUIRED then
        Session.mark_expired(session, Constants.ERROR.AUTH_REQUIRED)
        Session.save(session)
        return false, Constants.ERROR.AUTH_REQUIRED
    end
    if resp.error then
        -- Network/server error: do NOT discard the session.
        return false, resp.error
    end

    local csrf = parse_csrf(resp.body)
    if csrf then http.csrf_token = csrf end
    local user_id = parse_user_id(resp.body)
    if user_id then http.user_id = user_id end
    Session.absorb(session, http)
    Session.mark_valid(session)
    Session.save(session)
    return true
end

function Manager.refresh_session(opts)
    return Manager.validate_session(opts)
end

function Manager.get_account()
    local session = Session.load()
    if not Session.is_valid(session) then
        return nil, Constants.ERROR.AUTH_REQUIRED
    end
    return {
        id = session.user_id,
        username = session.username or session.user_id,
    }
end

-- Interactive login. `email` and `password` are supplied by the UI and are
-- never persisted by this module.
local function record_login_result(result)
    local store = account_store()
    store:set("last_login", {
        ok = result and result.ok or false,
        stage = result and result.stage or nil,
        error = result and result.error or nil,
        at = os.time(),
    })
    store:flush()
end

function Manager.get_last_login()
    return account_store():get("last_login")
end

-- Interactive login. `email` and `password` are supplied by the UI and are
-- never persisted by this module.
function Manager.login(email, password, opts)
    local Login = require("goodreadskosync.auth.login")
    local result = Login.perform(email, password, opts)
    record_login_result(result)
    if result.ok then
        Logging.trace("auth: login succeeded")
        Session.save(result.session)
        return true, result.account
    end
    Logging.trace("auth: login failed stage=", tostring(result.stage),
        "error=", tostring(result.error))
    if result.needs_otp or result.needs_challenge then
        Manager._pending_login = result.ctx
    end
    return false, result.error or Constants.ERROR.AUTH_REQUIRED, result
end

function Manager.submit_otp(otp, opts)
    if not Manager._pending_login then
        return false, Constants.ERROR.AUTH_REQUIRED
    end
    local Login = require("goodreadskosync.auth.login")
    local result = Login.submit_otp(Manager._pending_login, otp, opts)
    record_login_result(result)
    if result.ok then
        Manager._pending_login = nil
        Session.save(result.session)
        return true, result.account
    end
    if not (result.needs_otp or result.needs_challenge) then
        Manager._pending_login = nil
    end
    return false, result.error or Constants.ERROR.AUTH_REQUIRED, result
end

function Manager.submit_challenge(answer, opts)
    if not Manager._pending_login then
        return false, Constants.ERROR.AUTH_REQUIRED
    end
    local Login = require("goodreadskosync.auth.login")
    local result = Login.submit_challenge(Manager._pending_login, answer, opts)
    record_login_result(result)
    if result.ok then
        Manager._pending_login = nil
        Session.save(result.session)
        return true, result.account
    end
    if not (result.needs_otp or result.needs_challenge) then
        Manager._pending_login = nil
    end
    return false, result.error or Constants.ERROR.AUTH_REQUIRED, result
end

function Manager.logout()
    Manager._pending_login = nil
    Session.clear()
    return true
end

function Manager.handle_auth_failure(reason)
    local session = Session.load()
    Session.mark_expired(session, reason or Constants.ERROR.AUTH_REQUIRED)
    Session.save(session)
end

return Manager
