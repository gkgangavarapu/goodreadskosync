local Constants = require("goodreadskosync.constants")
local FakeHttp = require("support.fake_http")
local GoodreadsWeb = require("goodreadskosync.providers.goodreads_web")
local Session = require("goodreadskosync.auth.session")
local Storage = require("goodreadskosync.storage")

local AUTO_COMPLETE = [==[[{"imageUrl":"http://img","bookId":"23692271",
"title":"Sapiens","numPages":512,"author":{"id":1,"name":"Yuval Noah Harari"},
"bookUrl":"/book/show/23692271"}]]==]

local function valid_session()
    local session = Session.new()
    session.cookies = "_session_id2=abc; at-main=1"
    Session.mark_valid(session)
    Session.save(session)
end

describe("providers.goodreads_web", function()
    it("reports capabilities and availability", function()
        local provider = GoodreadsWeb:new()
        local available = provider:is_available()
        assert_true(available)
        assert_true(provider:is_implemented())
        local caps = provider:get_capabilities()
        assert_true(caps.search and caps.shelves and caps.progress and caps.rating)
    end)

    it("requires a session for operations", function()
        Storage.reset()
        local provider = GoodreadsWeb:new()
        local results, err = provider:search_books("x")
        assert_nil(results)
        assert_equal(Constants.ERROR.AUTH_REQUIRED, err)
        assert_false(provider:is_authenticated())
    end)

    it("delegates search to the client using the stored session", function()
        Storage.reset()
        valid_session()
        local transport = FakeHttp.scripted({ { status = 200, body = AUTO_COMPLETE } })
        local provider = GoodreadsWeb:new{ transport = transport }
        assert_true(provider:is_authenticated())
        local results, err = provider:search_books("sapiens")
        assert_nil(err)
        assert_equal("23692271", results[1].goodreads_id)
    end)

    it("marks the session expired when Goodreads serves sign-in", function()
        Storage.reset()
        valid_session()
        local transport = FakeHttp.scripted({
            { status = 200, body = '<form action="/ap/signin"><input name="email"/></form>' },
        })
        local provider = GoodreadsWeb:new{ transport = transport }
        local book, err = provider:get_book("23692271")
        assert_nil(book)
        assert_equal(Constants.ERROR.AUTH_REQUIRED, err)
        assert_equal("expired", Session.load().state)
    end)

    it("logs out by clearing the session", function()
        Storage.reset()
        valid_session()
        local provider = GoodreadsWeb:new()
        assert_true(provider:logout())
        assert_false(provider:is_authenticated())
    end)
end)
