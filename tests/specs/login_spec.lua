local AmazonWeb = require("goodreadskosync.auth.providers.amazon_web")
local Constants = require("goodreadskosync.constants")
local FakeHttp = require("support.fake_http")
local Login = require("goodreadskosync.auth.login")

local SIGN_IN = [[<html><body>
<a href="https://www.goodreads.com/ap/signin?language=en_US&amp;openid.assoc_handle=web_na">Sign in with email</a>
</body></html>]]

local AP_FORM = [[<html><body>
<form name="signIn" method="post" action="https://www.goodreads.com/ap/signin/123-456">
<input type="hidden" name="formToken" value="tok"/>
<input type="hidden" name="formAction" value="SIGNIN"/>
<input type="email" name="email"/>
<input type="password" name="password"/>
</form>
</body></html>]]

local OTP_FORM = [[<html><body>
<form action="https://www.goodreads.com/ap/mfa/1">
<input type="hidden" name="formToken" value="t2"/>
<input type="text" name="otpCode"/>
</form>
</body></html>]]

local CHALLENGE_FORM = [[<html><body>
<form name="signIn" method="post" action="https://www.goodreads.com/ap/signin/123-456">
<input type="hidden" name="formToken" value="tok2"/>
<img src="/errors/validate?x=1">
<input type="text" name="captcha_input"/>
</form>
</body></html>]]

local HOME = [[<html><head><meta name="csrf-token" content="CSRF"></head>
<body><a href="/user/show/999">me</a></body></html>]]

describe("auth provider parsing", function()
    it("extracts the sign-in link and decodes entities", function()
        assert_equal("https://www.goodreads.com/ap/signin?language=en_US&openid.assoc_handle=web_na",
            AmazonWeb._sign_in_link(SIGN_IN))
    end)

    it("parses the credential form", function()
        local form = AmazonWeb._parse_form_with_password(AP_FORM)
        assert_not_nil(form)
        assert_equal("https://www.goodreads.com/ap/signin/123-456", form.action)
        assert_equal("email", form.email_field)
        assert_equal("password", form.password_field)
        assert_equal("tok", form.hidden.formToken)
    end)

    it("parses the OTP form", function()
        local form = AmazonWeb._parse_otp_form(OTP_FORM)
        assert_not_nil(form)
        assert_equal("otpCode", form.otp_field)
        assert_equal("https://www.goodreads.com/ap/mfa/1", form.action)
    end)

    it("parses the challenge form", function()
        local challenge = AmazonWeb._parse_challenge(CHALLENGE_FORM)
        assert_not_nil(challenge)
        assert_equal("/errors/validate?x=1", challenge.image_url)
        assert_equal("captcha_input", challenge.input_name)
        assert_equal("https://www.goodreads.com/ap/signin/123-456", challenge.action)
    end)
end)

describe("auth.login", function()
    it("rejects empty input", function()
        local result = Login.perform("", "")
        assert_false(result.ok)
        assert_equal(Constants.ERROR.INVALID_REQUEST, result.error)
    end)

    it("logs in with email and password and captures the session", function()
        local transport, calls = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM },
            { status = 302, headers = {
                location = "https://www.goodreads.com/",
                ["set-cookie"] = "_session_id2=abc; at-main=1",
            } },
            { status = 200, body = HOME },
            { status = 200, body = HOME },
        })
        local result = Login.perform("me@example.com", "secret", { transport = transport })

        assert_true(result.ok)
        assert_equal("999", result.account.id)
        assert_true(result.session.cookies:find("_session_id2", 1, true) ~= nil)
        -- The password was submitted to the form but is not persisted in the session.
        assert_true(calls[3].body:find("password=secret", 1, true) ~= nil)
        assert_nil(result.session.password)
    end)

    it("reports invalid credentials", function()
        local transport = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM },
            { status = 200, body = "Your password is incorrect" },
        })
        local result = Login.perform("me@example.com", "wrong", { transport = transport })
        assert_false(result.ok)
        assert_equal(Constants.ERROR.INVALID_CREDENTIALS, result.error)
    end)

    it("stops on an unsolvable challenge page", function()
        local transport = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM },
            { status = 200, body = "Enter the characters you see below" },
        })
        local result = Login.perform("me@example.com", "secret", { transport = transport })
        assert_false(result.ok)
        assert_equal(Constants.ERROR.SIGNIN_BLOCKED, result.error)
        assert_equal("challenge", result.stage)
    end)

    it("asks for an OTP and completes login", function()
        local transport = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM },
            { status = 200, body = OTP_FORM },
            { status = 302, headers = {
                location = "https://www.goodreads.com/",
                ["set-cookie"] = "_session_id2=abc; session-token=st",
            } },
            { status = 200, body = HOME },
            { status = 200, body = HOME },
        })
        local first = Login.perform("me@example.com", "secret", { transport = transport })
        assert_false(first.ok)
        assert_true(first.needs_otp)
        assert_not_nil(first.ctx)

        local second = Login.submit_otp(first.ctx, "123456", { transport = transport })
        assert_true(second.ok)
        assert_equal("999", second.account.id)
    end)

    it("solves a challenge and completes login", function()
        local transport = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM },
            { status = 200, body = CHALLENGE_FORM },
            { status = 302, headers = {
                location = "https://www.goodreads.com/",
                ["set-cookie"] = "_session_id2=abc; at-main=1",
            } },
            { status = 200, body = HOME },
            { status = 200, body = HOME },
        })
        local first = Login.perform("me@example.com", "secret", { transport = transport })
        assert_false(first.ok)
        assert_true(first.needs_challenge)
        assert_not_nil(first.challenge)
        assert_equal("captcha_input", first.challenge.input_name)

        local second = Login.submit_challenge(first.ctx, "abcd", { transport = transport })
        assert_true(second.ok)
        assert_equal("999", second.account.id)
    end)

    it("retries transient network failures before succeeding", function()
        local transport, calls = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM },
            { ok = false }, -- transport failure on the credential POST
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM },
            { status = 302, headers = {
                location = "https://www.goodreads.com/",
                ["set-cookie"] = "_session_id2=abc; at-main=1",
            } },
            { status = 200, body = HOME },
            { status = 200, body = HOME },
        })
        local result = Login.perform("me@example.com", "secret", {
            transport = transport, attempts = 2, sleep = function() end,
        })
        assert_true(result.ok)
        assert_equal("999", result.account.id)
        assert_true(#calls >= 8)
    end)

    it("does not retry invalid credentials", function()
        local transport, calls = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM },
            { status = 200, body = "Your password is incorrect" },
        })
        local result = Login.perform("me@example.com", "wrong", {
            transport = transport, attempts = 3, sleep = function() end,
        })
        assert_false(result.ok)
        assert_equal(Constants.ERROR.INVALID_CREDENTIALS, result.error)
        assert_equal(3, #calls)
    end)

    it("parses a challenge whose image is outside the form", function()
        local html = [[<html><body>
        <img src="https://example.com/errors/validate?x=1">
        <form action="/errors/validate">
        <input type="hidden" name="h" value="1"/>
        <input type="text" name="field-keywords"/>
        </form></body></html>]]
        local challenge = AmazonWeb._parse_challenge(html)
        assert_not_nil(challenge)
        assert_equal("https://example.com/errors/validate?x=1", challenge.image_url)
        assert_equal("field-keywords", challenge.input_name)
        assert_equal("/errors/validate", challenge.action)
    end)

    it("asks for a challenge found on the sign-in form page", function()
        local body = [[<html><body>Please solve this captcha
        <img src="/errors/validate?x=1"/>
        <form action="/errors/validate">
        <input type="text" name="field-keywords"/>
        </form></body></html>]]
        local transport = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = body },
        })
        local result = Login.perform("me@example.com", "secret", {
            transport = transport, attempts = 1,
        })
        assert_false(result.ok)
        assert_true(result.needs_challenge)
        assert_not_nil(result.ctx)
        assert_not_nil(result.ctx.challenge_url)
    end)

    -- An ordinary sign-in page can mention challenge-related words in comments
    -- or asset URLs, but has no challenge image and must not be treated as one.
    local AP_FORM_WITH_NOISE = [[<html><head>
    <link href="https://cdn.example.com/x.css?assets=1"/>
    <!-- generated page -->
    </head><body>
    <form name="signIn" method="post" action="https://www.goodreads.com/ap/signin/123-456">
    <input type="hidden" name="formToken" value="tok"/>
    <input type="email" name="email"/>
    <input type="password" name="password"/>
    </form></body></html>]]

    it("does not mistake the ordinary sign-in page for a challenge", function()
        local transport = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM_WITH_NOISE },
            { status = 200, body = AP_FORM_WITH_NOISE },
        })
        local result = Login.perform("me@example.com", "meh", {
            transport = transport, attempts = 1,
        })
        assert_false(result.ok)
        assert_equal(Constants.ERROR.INVALID_CREDENTIALS, result.error)
    end)

    it("finalizes a successful login even if the page mentions challenge words", function()
        local home = [[<html><head>
        <link href="https://cdn.example.com/x.css?assets=1"/>
        </head><body><a href="/user/show/999">me</a>
        <script>var captcha = false;</script></body></html>]]
        local transport = FakeHttp.scripted({
            { status = 200, body = SIGN_IN },
            { status = 200, body = AP_FORM },
            { status = 302, headers = {
                location = "https://www.goodreads.com/",
                ["set-cookie"] = "_session_id2=abc; at-main=1",
            } },
            { status = 200, body = home },
            { status = 200, body = home },
        })
        local result = Login.perform("me@example.com", "secret", {
            transport = transport, attempts = 1,
        })
        assert_true(result.ok)
        assert_equal("999", result.account.id)
    end)
end)
