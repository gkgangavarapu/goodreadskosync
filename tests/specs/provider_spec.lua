local Constants = require("goodreadskosync.constants")
local Mock = require("goodreadskosync.providers.mock")
local Storage = require("goodreadskosync.storage")
local Auth = require("goodreadskosync.auth.manager")

describe("providers.mock", function()
    it("ships no built-in catalogue", function()
        Storage.reset()
        local provider = Mock:new()
        local results = provider:search_books("anything")
        assert_equal(0, #results)
    end)

    it("searches an injected catalogue", function()
        Storage.reset()
        local provider = Mock:new({ catalog = {
            { goodreads_id = "1", title = "Dune",
                authors = { "Frank Herbert" }, isbn13 = "9780441013593" },
        } })
        local results = provider:search_books("Dune")
        assert_equal(1, #results)
        assert_equal("1", results[1].goodreads_id)
        assert_equal(0, #provider:search_books("Sapiens"))
    end)

    it("persists shelf, progress and rating across instances", function()
        Storage.reset()
        local provider = Mock:new()
        assert_true(provider:set_shelf("1", Constants.SHELF.CURRENTLY_READING))
        assert_true(provider:update_progress("1", 67))
        assert_true(provider:set_rating("1", 4))

        local reopened = Mock:new()
        assert_equal(Constants.SHELF.CURRENTLY_READING, reopened:get_shelf("1"))
        assert_equal(67, reopened:get_progress("1"))
        assert_equal(4, reopened:get_rating("1"))
    end)

    it("rejects invalid shelves and ratings", function()
        Storage.reset()
        local provider = Mock:new()
        assert_false(provider:set_shelf("1", "bogus"))
        assert_false(provider:set_rating("1", 6))
        assert_false(provider:set_rating("1", 0))
        assert_false(provider:update_progress("1", 200))
    end)

    it("authenticates and logs out", function()
        Storage.reset()
        local provider = Mock:new()
        local ok, account = provider:authenticate()
        assert_true(ok)
        assert_equal("mock-user", account.username)
        assert_not_nil(provider:get_account())
        provider:logout()
        assert_nil(provider:get_account())
    end)

    it("does not mutate its catalogue through returned copies", function()
        Storage.reset()
        local provider = Mock:new({ catalog = {
            { goodreads_id = "1", title = "Dune", authors = { "Frank Herbert" } },
        } })
        local results = provider:search_books("Dune")
        results[1].title = "Mutated"
        assert_equal("Dune", provider:search_books("Dune")[1].title)
    end)
end)

describe("providers availability", function()
    it("reports native Kindle as unavailable off-device", function()
        local discovered = Auth.discover()
        local entry
        for _, item in ipairs(discovered) do
            if item.id == "native_kindle" then entry = item end
        end
        assert_not_nil(entry)
        assert_false(entry.available)
        assert_false(entry.implemented)
    end)

    it("auto-selects the Goodreads web provider as the primary backend", function()
        local discovered = Auth.discover()
        local selected = Auth.auto_select(discovered)
        assert_not_nil(selected)
        assert_equal("goodreads_web", selected.id)
    end)

    it("reports the Goodreads web provider available and official API unavailable", function()
        local discovered = Auth.discover()
        for _, item in ipairs(discovered) do
            if item.id == "goodreads_web" then
                assert_true(item.available)
                assert_true(item.implemented)
            elseif item.id == "official_api" then
                assert_false(item.available)
            end
        end
    end)
end)
