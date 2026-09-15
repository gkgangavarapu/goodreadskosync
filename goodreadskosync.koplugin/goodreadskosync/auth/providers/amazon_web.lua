--[[--
On-device email/password login mechanism.

Concrete "AuthProvider" for the web provider. It follows the email sign-in
flow the site serves: a form with hidden anti-CSRF fields and email/password
inputs. Credentials are supplied by the caller and are never persisted here.

When the site answers with an image challenge, it is parsed and surfaced to
the caller (and on to the UI) so the user can solve it on-device. A challenge
that needs a browser cannot be solved here; it is reported and stops the flow.

@module koplugin.goodreads.auth.providers.amazon_web
--]]

local Constants = require("goodreadskosync.constants")
local Logging = require("goodreadskosync.logging")
local Session = require("goodreadskosync.auth.session")

local AmazonWeb = {}
AmazonWeb.__index = AmazonWeb

local function parse_hidden_inputs(html)
    local fields = {}
    if type(html) ~= "string" then return fields end
    for tag in html:gmatch("<input[^>]*>") do
        local is_hidden = tag:find('type="hidden"', 1, true) or tag:find("type='hidden'", 1, true)
        if is_hidden then
            local name = tag:match('name="([^"]*)"') or tag:match("name='([^']*)'")
            local value = tag:match('value="([^"]*)"') or tag:match("value='([^']*)'")
            if name then fields[name] = value or "" end
        end
    end
    return fields
end

local function parse_form_with_password(html)
    if type(html) ~= "string" then return nil end
    for attrs, inner in html:gmatch("<form([^>]*)>(.-)</form>") do
        if inner:find('type="password"', 1, true) or inner:find("type='password'", 1, true) then
            local action = attrs:match('action="([^"]*)"') or attrs:match("action='([^']*)'")
            -- Goodreads historically used user[email]/user[password]; the
            -- Amazon AP form uses email/password (and sometimes ap_email).
            local email_name, password_name = "email", "password"
            for _, n in ipairs({ "user[email]", "ap_email", "email" }) do
                if inner:find('name="' .. n .. '"', 1, true) then
                    email_name = n
                    break
                end
            end
            for _, n in ipairs({ "user[password]", "ap_password", "password" }) do
                if inner:find('name="' .. n .. '"', 1, true) then
                    password_name = n
                    break
                end
            end
            local remember_name
            for tag in inner:gmatch("<input[^>]*>") do
                local name = tag:match('name="([^"]*)"') or tag:match("name='([^']*)'")
                if name and name:lower():find("remember", 1, true) then
                    remember_name = name
                    break
                end
            end
            return {
                action = action,
                hidden = parse_hidden_inputs(inner),
                email_field = email_name,
                password_field = password_name,
                remember_field = remember_name,
            }
        end
    end
    return nil
end

local function parse_otp_form(html)
    if type(html) ~= "string" then return nil end
    for attrs, inner in html:gmatch("<form([^>]*)>(.-)</form>") do
        local otp_name = inner:match('name="(otpCode)"')
            or inner:match('name="(code)"')
            or inner:match('name="([^"]*otp[^"]*)"')
        if otp_name then
            local action = attrs:match('action="([^"]*)"') or attrs:match("action='([^']*)'")
            return {
                action = action,
                hidden = parse_hidden_inputs(inner),
                otp_field = otp_name,
            }
        end
    end
    return nil
end

-- Find the challenge image. Only accept sources that look like a challenge so
-- we never mistake an ordinary page image for one.
local function find_challenge_image(html)
    if type(html) ~= "string" then return nil end
    for tag in html:gmatch("<img[^>]*>") do
        local src = tag:match('src="([^"]*)"') or tag:match("src='([^']*)'")
        if src then
            local l = src:lower()
            if l:find("captcha", 1, true) or l:find("validate", 1, true)
                or l:find("/errors/", 1, true) then
                return src
            end
        end
    end
    return nil
end

local function challenge_input_in(inner)
    if type(inner) ~= "string" then return nil end
    for tag in inner:gmatch("<input[^>]*>") do
        local typ = (tag:match('type="([^"]*)"') or tag:match("type='([^']*)'") or "text"):lower()
        local name = tag:match('name="([^"]*)"') or tag:match("name='([^']*)'")
        if name and (typ == "text" or typ == "search") then
            local l = name:lower()
            if l:find("captcha", 1, true) or l:find("keyword", 1, true) then
                return name
            end
        end
    end
    return nil
end

local function first_text_input_in(inner)
    if type(inner) ~= "string" then return nil end
    for tag in inner:gmatch("<input[^>]*>") do
        local typ = (tag:match('type="([^"]*)"') or tag:match("type='([^']*)'") or "text"):lower()
        local name = tag:match('name="([^"]*)"') or tag:match("name='([^']*)'")
        if name and (typ == "text" or typ == "search") then
            return name
        end
    end
    return nil
end

-- Parse an image challenge. The image is often outside the form, and the
-- answer field may be named in a few different ways, so the image and the
-- input are located independently.
local function parse_challenge(html)
    if type(html) ~= "string" then return nil end
    local image_url = find_challenge_image(html)
    if not image_url then return nil end

    local fallback
    for attrs, inner in html:gmatch("<form([^>]*)>(.-)</form>") do
        local action = attrs:match('action="([^"]*)"') or attrs:match("action='([^']*)'")
        local hidden = parse_hidden_inputs(inner)
        local input = challenge_input_in(inner)
        if input then
            return {
                action = action,
                hidden = hidden,
                image_url = image_url,
                input_name = input,
            }
        end
        if not fallback then
            local any_input = first_text_input_in(inner)
            if any_input then
                fallback = {
                    action = action,
                    hidden = hidden,
                    image_url = image_url,
                    input_name = any_input,
                }
            end
        end
    end
    return fallback
end

local function collect_sign_in_links(html)
    local links = {}
    if type(html) ~= "string" then return links end
    for href in html:gmatch('href="(https?://[^"]*/ap/signin%?[^"]*)"') do
        links[#links + 1] = (href:gsub("&amp;", "&"))
    end
    for href in html:gmatch("href='(https?://[^']*/ap/signin%?[^']*)'") do
        links[#links + 1] = (href:gsub("&amp;", "&"))
    end
    return links
end

local function sign_in_link(html)
    local links = collect_sign_in_links(html)
    -- Prefer the straightforward sign-in flow over the third-party buttons.
    for _, link in ipairs(links) do
        if not link:find("identityProvider", 1, true) then return link end
    end
    return links[1]
end

local function lower(s)
    return type(s) == "string" and s:lower() or ""
end

local function contains_any(haystack, needles)
    local h = lower(haystack)
    for _, needle in ipairs(needles) do
        if h:find(needle, 1, true) then return true end
    end
    return false
end

-- Only strong, challenge-specific phrases. Bare generic words also appear on
-- ordinary pages, so they must NOT be used to detect a challenge.
local CHALLENGE_MARKERS = {
    "enter the characters you see",
    "type the characters you see",
    "characters you see",
}
local OTP_MARKERS = { "auth-mfa", "otpcode", "verification code", "two-step verification", "enter otp" }
local BAD_CREDENTIALS_MARKERS = {
    "password is incorrect",
    "problem with your password",
    "cannot find an account",
    "your password is incorrect",
    "there was a problem with your request",
}

-- A compact, non-secret fingerprint of a page, for diagnostics only.
local function page_markers(body)
    local l = lower(body)
    local markers = {
        "form=" .. tostring(l:find("<form", 1, true) ~= nil),
        "password=" .. tostring(l:find('type="password"', 1, true) ~= nil),
        "email=" .. tostring(l:find('name="email"', 1, true) ~= nil),
        "signin=" .. tostring(l:find("sign_in", 1, true) ~= nil or l:find("signin", 1, true) ~= nil),
        "check=" .. tostring(contains_any(body, CHALLENGE_MARKERS)),
        "consent=" .. tostring(l:find("consent", 1, true) ~= nil),
        "intercept=" .. tostring(l:find("challenge", 1, true) ~= nil),
    }
    return table.concat(markers, " ")
end

function AmazonWeb:new(opts)
    opts = opts or {}
    return setmetatable({
        base_url = opts.base_url or "https://www.goodreads.com",
        transport = opts.transport,
        -- Login round-trips can be slow; allow more than the
        -- generic 15s used for routine calls.
        timeout = opts.timeout or 30,
    }, self)
end

function AmazonWeb:_new_http()
    local Http = require("goodreadskosync.goodreads.http")
    return Http:new{
        base_url = self.base_url,
        transport = self.transport,
        timeout = self.timeout,
    }
end

-- Fetch the sign-in page and locate the credential form.
-- Returns ctx or nil, error.
local function host_of(url)
    if type(url) ~= "string" then return "?" end
    return url:match("^https?://([^/]+)") or url
end

function AmazonWeb:start()
    local http = self:_new_http()
    local resp = http:get(self.base_url .. "/user/sign_in", {
        follow = true,
        detect_auth = false,
    })
    Logging.trace("login/start: sign_in status=", tostring(resp.status),
        "url=", tostring(resp.url), "bytes=", tostring(resp.body and #resp.body),
        "error=", tostring(resp.error))
    if resp.body then
        Logging.trace("login/start: sign_in page ", page_markers(resp.body))
    end

    if resp.error == Constants.ERROR.SIGNIN_BLOCKED then
        return nil, Constants.ERROR.SIGNIN_BLOCKED
    end
    if resp.error then return nil, resp.error end

    local form = parse_form_with_password(resp.body)
    if form and form.action then
        form.action = require("goodreadskosync.goodreads.http").absolute(self.base_url, form.action)
        Logging.trace("login/start: direct form host=", host_of(form.action))
        return { http = http, form = form }
    end

    local link = sign_in_link(resp.body)
    if not link then
        Logging.trace("login/start: no sign-in link found")
        return nil, Constants.ERROR.INVALID_RESPONSE
    end
    Logging.trace("login/start: following sign-in link host=", host_of(link))
    local form_resp = http:get(link, { follow = true, detect_auth = false })
    Logging.trace("login/start: form page status=", tostring(form_resp.status),
        "url=", tostring(form_resp.url),
        "bytes=", tostring(form_resp.body and #form_resp.body),
        "error=", tostring(form_resp.error))
    if form_resp.body then
        Logging.trace("login/start: form page ", page_markers(form_resp.body))
    end

    if form_resp.error == Constants.ERROR.SIGNIN_BLOCKED then
        return nil, Constants.ERROR.SIGNIN_BLOCKED
    end
    if form_resp.error then return nil, form_resp.error end

    form = parse_form_with_password(form_resp.body)
    if not form or not form.action then
        local challenge = parse_challenge(form_resp.body)
        if challenge then
            Logging.trace("login/start: challenge on the form page")
            return {
                http = http,
                challenge = challenge,
                challenge_url = form_resp.url,
            }
        end
        if contains_any(form_resp.body, CHALLENGE_MARKERS) then
            return nil, Constants.ERROR.SIGNIN_BLOCKED
        end
        Logging.trace("login/start: no credential form on form page")
        return nil, Constants.ERROR.INVALID_RESPONSE
    end
    form.action = require("goodreadskosync.goodreads.http").absolute(form_resp.url, form.action)
    Logging.trace("login/start: form action host=", host_of(form.action))
    return { http = http, form = form }
end

function AmazonWeb:_interpret(ctx, resp)
    Logging.trace("login/interpret: status=", tostring(resp.status),
        "url=", tostring(resp.url), "bytes=", tostring(resp.body and #resp.body),
        "error=", tostring(resp.error))

    local body = resp.body or ""
    ctx.last_body = body
    ctx.challenge_url = resp.url or ctx.challenge_url

    -- A real image challenge is treated as solvable and takes priority, so the
    -- user can complete it on-device.
    local challenge = parse_challenge(body)
    if challenge then
        ctx.challenge = challenge
        Logging.trace("login/interpret: challenge image host=",
            host_of(challenge.image_url), " input=", tostring(challenge.input_name))
        return {
            ok = false,
            needs_challenge = true,
            ctx = ctx,
            challenge = challenge,
            stage = "challenge",
        }
    end

    if resp.error == Constants.ERROR.SIGNIN_BLOCKED then
        -- The landing page is frequently intercepted even when the credential
        -- POST already established a session. Validate against a normally
        -- served page before failing.
        local verified = self:_finalize(ctx)
        if verified.ok then return verified end
        return { ok = false, error = Constants.ERROR.SIGNIN_BLOCKED, stage = "blocked" }
    end
    if resp.error == Constants.ERROR.NETWORK_ERROR
        or resp.error == Constants.ERROR.SERVER_ERROR then
        return { ok = false, error = resp.error, stage = "network" }
    end

    -- Strong challenge text without a parseable image: an unsolvable challenge.
    -- Ordinary pages that merely mention it must NOT land here, or a successful
    -- login would be reported as blocked.
    if contains_any(body, CHALLENGE_MARKERS) then
        Logging.trace("login/interpret: challenge page without a parseable image ",
            page_markers(body))
        return { ok = false, error = Constants.ERROR.SIGNIN_BLOCKED, stage = "challenge" }
    end
    if contains_any(body, OTP_MARKERS) then
        Logging.trace("login/interpret: OTP/MFA required")
        return { ok = false, needs_otp = true, ctx = ctx, stage = "otp" }
    end
    if contains_any(body, BAD_CREDENTIALS_MARKERS) then
        Logging.trace("login/interpret: bad credentials marker present")
        return { ok = false, error = Constants.ERROR.INVALID_CREDENTIALS, stage = "credentials" }
    end
    -- If the response is still a credential form, the attempt did not progress.
    if parse_form_with_password(body) then
        Logging.trace("login/interpret: still on credential form")
        return { ok = false, error = Constants.ERROR.INVALID_CREDENTIALS, stage = "credentials" }
    end

    return self:_finalize(ctx)
end

function AmazonWeb:_finalize(ctx)
    local http = ctx.http
    -- Validate against a normally-served page that, when signed in, contains
    -- the user id and a CSRF token.
    local resp = http:get(http.base_url .. "/review/list", { follow = true, detect_auth = false })
    local looks_signin = require("goodreadskosync.goodreads.http")._looks_like_sign_in(resp.url, resp.body)
    local body = resp.body or ""
    local user_id = body:match("/user/show/(%d+)")
    local csrf = body:match(
        '<meta%s+[^>]-name=["\']csrf%-token["\']%s+[^>]-content=["\']([^"\']+)["\']')
    Logging.trace("login/finalize: status=", tostring(resp.status),
        "url=", tostring(resp.url), "bytes=", tostring(resp.body and #resp.body),
        "error=", tostring(resp.error),
        "user_id=", tostring(user_id),
        "csrf=", tostring(csrf ~= nil),
        "looks_like_signin=", tostring(looks_signin))

    if resp.error == Constants.ERROR.SIGNIN_BLOCKED then
        return { ok = false, error = Constants.ERROR.SIGNIN_BLOCKED, stage = "blocked" }
    end
    if resp.error then
        return { ok = false, error = resp.error, stage = "finalize" }
    end

    -- Only trust a page that clearly belongs to a signed-in account.
    if not user_id or looks_signin then
        return { ok = false, error = Constants.ERROR.INVALID_CREDENTIALS, stage = "finalize" }
    end

    http.csrf_token = csrf
    http.user_id = user_id

    local session = Session.new()
    Session.absorb(session, http)
    Session.mark_valid(session)
    return {
        ok = true,
        session = session,
        account = { id = http.user_id, username = http.user_id },
    }
end

-- Submit credentials. `email`/`password` come from the UI and are not stored.
function AmazonWeb:submit(ctx, email, password)
    if not ctx or not ctx.form then
        return { ok = false, error = Constants.ERROR.AUTH_REQUIRED, stage = "submit" }
    end
    local fields = {}
    for key, value in pairs(ctx.form.hidden or {}) do fields[key] = value end
    fields[ctx.form.email_field or "email"] = email
    fields[ctx.form.password_field or "password"] = password
    -- "Keep me signed in" — request a long-lived session.
    local remember_field = ctx.form.remember_field or "rememberMe"
    if not fields[remember_field] then fields[remember_field] = "true" end

    Logging.trace("login/submit: posting to host=", host_of(ctx.form.action),
        "email_field=", tostring(ctx.form.email_field))

    local resp = ctx.http:post_form(ctx.form.action, fields, {
        follow = true,
        detect_auth = false,
    })
    return self:_interpret(ctx, resp)
end

function AmazonWeb:submit_otp(ctx, otp)
    if not ctx then
        return { ok = false, error = Constants.ERROR.AUTH_REQUIRED, stage = "otp" }
    end
    local otp_form = parse_otp_form(ctx.last_body)
    if not otp_form or not otp_form.action then
        return { ok = false, error = Constants.ERROR.INVALID_RESPONSE, stage = "otp" }
    end
    local fields = {}
    for key, value in pairs(otp_form.hidden or {}) do fields[key] = value end
    fields[otp_form.otp_field] = otp

    local action = require("goodreadskosync.goodreads.http").absolute(ctx.http.base_url, otp_form.action)
    local resp = ctx.http:post_form(action, fields, {
        follow = true,
        detect_auth = false,
    })
    return self:_interpret(ctx, resp)
end

function AmazonWeb:submit_challenge(ctx, answer)
    if not ctx or not ctx.challenge then
        return { ok = false, error = Constants.ERROR.INVALID_RESPONSE, stage = "challenge" }
    end
    local fields = {}
    for key, value in pairs(ctx.challenge.hidden or {}) do fields[key] = value end
    fields[ctx.challenge.input_name] = answer

    local base_action = ctx.challenge.action or (ctx.form and ctx.form.action)
    local action = base_action
        and require("goodreadskosync.goodreads.http").absolute(ctx.http.base_url, base_action)
    if not action then
        return { ok = false, error = Constants.ERROR.INVALID_RESPONSE, stage = "challenge" }
    end

    Logging.trace("login/challenge: submitting answer to host=", host_of(action))
    local resp = ctx.http:post_form(action, fields, {
        follow = true,
        detect_auth = false,
    })
    return self:_interpret(ctx, resp)
end

AmazonWeb._parse_hidden_inputs = parse_hidden_inputs
AmazonWeb._parse_form_with_password = parse_form_with_password
AmazonWeb._parse_otp_form = parse_otp_form
AmazonWeb._parse_challenge = parse_challenge
AmazonWeb._sign_in_link = sign_in_link

return AmazonWeb
