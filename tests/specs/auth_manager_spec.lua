local Constants = require("goodreadskosync.constants")
local FakeHttp = require("support.fake_http")
local Manager = require("goodreadskosync.auth.manager")
local Session = require("goodreadskosync.auth.session")
local Storage = require("goodreadskosync.storage")

local HOME = [[<html><head><meta name="csrf-token" content="CSRF"></head>
<body><a href="/user/show/999">me</a></body></html>]]

local SIGN_IN_BODY = [[<html><body>
<form action="/ap/signin"><input name="email"/><input type="password" name="password"/></form>
</body></html>]]

local AP_FORM = [[<html><body>
<form name="signIn" method="post" action="https://www.goodreads.com/ap/signin/1">
<input type="hidden" name="formToken" value="tok"/>
<input type="email" name="email"/><input type="password" name="password"/>
</form></body></html>]]

local SIGN_IN_LINK = [[<html><a href="https://www.goodreads.com/ap/signin?language=en_US&amp;openid.assoc_handle=web_na">Sign in with email</a></html>]]

local function valid_session()
    local session = Session.new()
    session.cookies = "_session_id2=abc; at-main=1"
    Session.mark_valid(session)
    Session.save(session)
end

describe("auth.manager session", function()
    it("reports not authenticated without a session", function()
        Storage.reset()
        assert_false(Manager.is_authenticated())
        local account, err = Manager.get_account()
        assert_nil(account)
        assert_equal(Constants.ERROR.AUTH_REQUIRED, err)
    end)

    it("validates a stored session and extracts CSRF and user id", function()
        Storage.reset()
        valid_session()
        local transport = FakeHttp.scripted({ { status = 200, body = HOME } })
        local ok = Manager.validate_session({ transport = transport })
        assert_true(ok)
        local session = Session.load()
        assert_equal("999", session.user_id)
        assert_equal("CSRF", session.csrf_token)
        assert_equal("valid", session.state)
    end)

    it("marks the session expired when Goodreads serves sign-in", function()
        Storage.reset()
        valid_session()
        local transport = FakeHttp.scripted({ { status = 200, body = SIGN_IN_BODY } })
        local ok, err = Manager.validate_session({ transport = transport })
        assert_false(ok)
        assert_equal(Constants.ERROR.AUTH_REQUIRED, err)
        assert_equal("expired", Session.load().state)
    end)

    it("keeps the session on a network error", function()
        Storage.reset()
        valid_session()
        local transport = FakeHttp.scripted({ { ok = false } })
        local ok, err = Manager.validate_session({ transport = transport })
        assert_false(ok)
        assert_equal(Constants.ERROR.NETWORK_ERROR, err)
        assert_equal("valid", Session.load().state)
    end)

    it("logs out and clears the session", function()
        Storage.reset()
        valid_session()
        assert_true(Manager.logout())
        assert_false(Manager.is_authenticated())
    end)

    it("logs in and persists the session", function()
        Storage.reset()
        local transport = FakeHttp.scripted({
            { status = 200, body = SIGN_IN_LINK },
            { status = 200, body = AP_FORM },
            { status = 302, headers = {
                location = "https://www.goodreads.com/",
                ["set-cookie"] = "_session_id2=abc; at-main=1",
            } },
            { status = 200, body = HOME },
            { status = 200, body = HOME },
        })
        local ok, account = Manager.login("me@example.com", "secret", { transport = transport })
        assert_true(ok)
        assert_equal("999", account.id)
        assert_true(Manager.is_authenticated())
    end)
end)
