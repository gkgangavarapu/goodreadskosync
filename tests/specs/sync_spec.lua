local Constants = require("goodreadskosync.constants")
local Engine = require("goodreadskosync.sync.engine")
local Mock = require("goodreadskosync.providers.mock")
local Progress = require("goodreadskosync.sync.progress")
local Storage = require("goodreadskosync.storage")

local function capabilities()
    return Mock:new():get_capabilities()
end

describe("sync.engine.decide", function()
    it("never sends progress at 0 percent", function()
        local actions = Engine.decide({
            state = {},
            percent = 0,
            status = "reading",
            capabilities = capabilities(),
            settings = {},
        })
        for _, action in ipairs(actions) do
            assert_false(action.type == "progress")
        end
    end)

    it("honors a want_to_read user override", function()
        local actions = Engine.decide({
            state = { shelf = Constants.SHELF.WANT_TO_READ },
            percent = 3,
            status = "reading",
            capabilities = capabilities(),
            settings = {},
            user_override = Constants.SHELF.WANT_TO_READ,
        })
        for _, action in ipairs(actions) do
            assert_false(action.type == "shelf")
        end
    end)

    it("marks Read on explicit completion", function()
        local actions = Engine.decide({
            state = {},
            percent = 100,
            status = "complete",
            capabilities = capabilities(),
            settings = {},
        })
        assert_equal("shelf", actions[1].type)
        assert_equal(Constants.SHELF.READ, actions[1].shelf)
    end)

    it("marks Currently Reading once progress exists", function()
        local actions = Engine.decide({
            state = {},
            percent = 12,
            capabilities = capabilities(),
            settings = {},
        })
        assert_equal(Constants.SHELF.CURRENTLY_READING, actions[1].shelf)
    end)

    it("does not send an unchanged progress", function()
        local actions = Engine.decide({
            state = { shelf = Constants.SHELF.CURRENTLY_READING,
                last_successful_percent = 67 },
            percent = 67,
            capabilities = capabilities(),
            settings = {},
        })
        assert_equal(0, #actions)
    end)

    it("adds a rating action only for an explicit rating", function()
        local actions = Engine.decide({
            state = {},
            capabilities = capabilities(),
            settings = {},
            rating = 5,
        })
        assert_equal(1, #actions)
        assert_equal("rating", actions[1].type)
    end)

    it("never completes at 99 percent unless configured", function()
        local actions = Engine.decide({
            state = {},
            percent = 99,
            status = "reading",
            capabilities = capabilities(),
            settings = {},
        })
        assert_equal(Constants.SHELF.CURRENTLY_READING, actions[1].shelf)
    end)
end)

describe("sync.engine.sync", function()
    it("applies a full sync and updates state", function()
        Storage.reset()
        local provider = Mock:new()
        provider:authenticate()
        local state = {}
        local results = Engine.sync({
            provider = provider,
            identity = { goodreads_id = "42" },
            state = state,
            percent = 67,
            status = "reading",
            settings = {},
            capabilities = provider:get_capabilities(),
            queue = require("goodreadskosync.sync.queue"),
        })
        assert_true(#results >= 2)
        assert_equal(Constants.SHELF.CURRENTLY_READING, provider:get_shelf("42"))
        assert_equal(67, provider:get_progress("42"))
        assert_equal(67, state.last_successful_percent)
        assert_equal(Constants.SHELF.CURRENTLY_READING, state.shelf)
        assert_not_nil(state.last_sync_at)
    end)

    it("queues failed operations for retry", function()
        Storage.reset()
        local Queue = require("goodreadskosync.sync.queue")
        Queue.clear()
        local failing = {
            get_capabilities = function()
                return { shelves = true, progress = true, completion = true,
                    rating = true, search = false }
            end,
            set_shelf = function() return false, Constants.ERROR.SERVER_ERROR end,
            update_progress = function() return false, Constants.ERROR.NETWORK_ERROR end,
        }
        Engine.sync({
            provider = failing,
            identity = { goodreads_id = "7" },
            state = {},
            percent = 50,
            settings = {},
            capabilities = failing.get_capabilities(),
            queue = Queue,
        })
        assert_equal(2, Queue.size())
    end)

    it("refuses to sync without a Goodreads id", function()
        local results = Engine.sync({
            provider = Mock:new(),
            identity = {},
            state = {},
            percent = 10,
            settings = {},
            capabilities = capabilities(),
        })
        assert_equal("identify", results[1].action.type)
        assert_false(results[1].ok)
    end)
end)

describe("sync.progress.shouldSync", function()
    it("does not send zero percent", function()
        assert_false(Progress.shouldSync({}, 0))
        assert_false(Progress.shouldSync({ last_successful_percent = 3 }, 0))
    end)

    it("sends when the whole percent changed", function()
        assert_true(Progress.shouldSync({}, 1))
        assert_true(Progress.shouldSync({ last_successful_percent = 3 }, 4))
        assert_false(Progress.shouldSync({ last_successful_percent = 4 }, 4))
    end)
end)
