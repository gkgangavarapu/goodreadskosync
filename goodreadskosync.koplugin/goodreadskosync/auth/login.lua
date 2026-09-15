--[[--
Interactive login orchestration.

Keeps the UI independent of the concrete authentication mechanism: the UI
calls `Login.perform(email, password)` and, if the result asks for an OTP,
`Login.submit_otp(ctx, otp)`.

Transient failures (network/timeout, server error, unparseable response) are
retried a few times with a small backoff. Authentication outcomes (bad
credentials, OTP, challenge) are never retried.

@module koplugin.goodreads.auth.login
--]]

local Constants = require("goodreadskosync.constants")

local Login = {}

local TRANSIENT = {
    [Constants.ERROR.NETWORK_ERROR] = true,
    [Constants.ERROR.SERVER_ERROR] = true,
    [Constants.ERROR.INVALID_RESPONSE] = true,
}

local DEFAULT_ATTEMPTS = 3
local DEFAULT_RETRY_DELAY = 2

local function default_sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
    end
end

local function mechanism(opts)
    opts = opts or {}
    local AmazonWeb = require("goodreadskosync.auth.providers.amazon_web")
    return AmazonWeb:new{
        base_url = opts.base_url,
        transport = opts.transport,
        timeout = opts.timeout,
    }
end

-- A result is worth retrying only when it is a transient failure.
local function should_retry(result)
    return type(result) == "table"
        and not result.ok
        and not result.needs_otp
        and not result.needs_challenge
        and TRANSIENT[result.error] == true
end

local function with_retries(fn, opts)
    opts = opts or {}
    local attempts = tonumber(opts.attempts) or DEFAULT_ATTEMPTS
    if attempts < 1 then attempts = 1 end
    local delay = tonumber(opts.retry_delay) or DEFAULT_RETRY_DELAY
    local sleep = opts.sleep or default_sleep

    local result
    for attempt = 1, attempts do
        result = fn()
        if not should_retry(result) or attempt == attempts then
            return result
        end
        sleep(delay * attempt)
    end
    return result
end

-- Returns:
--   { ok = true, session = ..., account = ... }
--   { ok = false, error = <code>, stage = ... }
--   { ok = false, needs_otp = true, ctx = ... }
--   { ok = false, needs_challenge = true, ctx = ..., challenge = ... }
--   (the challenge fields are internal; the UI only needs `needs_challenge`)
function Login.perform(email, password, opts)
    if type(email) ~= "string" or email == ""
        or type(password) ~= "string" or password == "" then
        return { ok = false, error = Constants.ERROR.INVALID_REQUEST, stage = "input" }
    end

    return with_retries(function()
        local mech = mechanism(opts)
        local ctx, err = mech:start()
        if not ctx then
            return { ok = false, error = err or Constants.ERROR.PROVIDER_UNAVAILABLE, stage = "start" }
        end
        -- The sign-in page itself can present a challenge.
        if ctx.challenge then
            return { ok = false, needs_challenge = true, ctx = ctx, challenge = ctx.challenge, stage = "challenge" }
        end
        return mech:submit(ctx, email, password)
    end, opts)
end

function Login.submit_otp(ctx, otp, opts)
    if not ctx then
        return { ok = false, error = Constants.ERROR.AUTH_REQUIRED, stage = "otp" }
    end
    if type(otp) ~= "string" or otp == "" then
        return { ok = false, error = Constants.ERROR.INVALID_REQUEST, stage = "otp" }
    end
    return with_retries(function()
        local mech = mechanism(opts)
        return mech:submit_otp(ctx, otp)
    end, opts)
end

function Login.submit_challenge(ctx, answer, opts)
    if not ctx then
        return { ok = false, error = Constants.ERROR.AUTH_REQUIRED, stage = "challenge" }
    end
    if type(answer) ~= "string" or answer == "" then
        return { ok = false, error = Constants.ERROR.INVALID_REQUEST, stage = "challenge" }
    end
    return with_retries(function()
        local mech = mechanism(opts)
        return mech:submit_challenge(ctx, answer)
    end, opts)
end

return Login
