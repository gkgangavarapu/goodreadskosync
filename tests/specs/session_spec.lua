local Session = require("goodreadskosync.auth.session")
local Storage = require("goodreadskosync.storage")

describe("auth.session", function()
    it("persists and reloads a valid session", function()
        Storage.reset()
        local session = Session.new()
        session.cookies = "_session_id2=abc; at-main=1"
        session.csrf_token = "CSRF"
        session.user_id = "999"
        Session.mark_valid(session)
        Session.save(session)

        local loaded = Session.load()
        assert_true(Session.is_valid(loaded))
        assert_equal("_session_id2=abc; at-main=1", loaded.cookies)
        assert_equal("CSRF", loaded.csrf_token)
        assert_equal("999", loaded.user_id)
        assert_equal("valid", loaded.state)
    end)

    it("is not valid when empty", function()
        Storage.reset()
        assert_false(Session.is_valid(Session.new()))
    end)

    it("marks a session expired", function()
        local session = Session.new()
        session.cookies = "_session_id2=abc"
        Session.mark_valid(session)
        Session.mark_expired(session, "AUTH_REQUIRED")
        assert_false(Session.is_valid(session))
        assert_equal("expired", session.state)
        assert_equal("AUTH_REQUIRED", session.last_error)
    end)

    it("absorbs rotated cookies and identity from an http object", function()
        local Http = require("goodreadskosync.goodreads.http")
        local http = Http:new{ cookies = "_session_id2=new", csrf_token = "C2", user_id = "5" }
        local session = Session.new()
        Session.absorb(session, http)
        assert_equal("_session_id2=new", session.cookies)
        assert_equal("C2", session.csrf_token)
        assert_equal("5", session.user_id)
    end)

    it("builds an http object from a session", function()
        local session = Session.new()
        session.cookies = "_session_id2=abc"
        session.csrf_token = "C"
        local http = Session.to_http(session)
        assert_equal("_session_id2=abc", http:get_cookie_header())
        assert_equal("C", http.csrf_token)
    end)
end)
