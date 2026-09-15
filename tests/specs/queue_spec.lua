local Constants = require("goodreadskosync.constants")
local Queue = require("goodreadskosync.sync.queue")
local Storage = require("goodreadskosync.storage")

describe("sync.queue", function()
    it("enqueues an operation", function()
        Storage.reset()
        Queue.clear()
        assert_true(Queue.enqueue({
            operation = "progress", book_id = "1", payload = { percent = 50 },
        }))
        assert_equal(1, Queue.size())
    end)

    it("coalesces repeated operations for the same book", function()
        Storage.reset()
        Queue.clear()
        Queue.enqueue({ operation = "progress", book_id = "1", payload = { percent = 10 } })
        Queue.enqueue({ operation = "progress", book_id = "1", payload = { percent = 55 } })
        assert_equal(1, Queue.size())
        local due = Queue.due()
        assert_equal(55, due[1].payload.percent)
    end)

    it("keeps distinct operations and books separate", function()
        Storage.reset()
        Queue.clear()
        Queue.enqueue({ operation = "progress", book_id = "1", payload = { percent = 10 } })
        Queue.enqueue({ operation = "shelf", book_id = "1", payload = { shelf = "read" } })
        Queue.enqueue({ operation = "progress", book_id = "2", payload = { percent = 10 } })
        assert_equal(3, Queue.size())
    end)

    it("backs off after a failure", function()
        Storage.reset()
        Queue.clear()
        Queue.enqueue({ operation = "progress", book_id = "1", payload = { percent = 10 } })
        local op = Queue.due()[1]
        Queue.markFailure(op.id, Constants.ERROR.NETWORK_ERROR)
        local reloaded = Queue.all()[op.id]
        assert_equal(1, reloaded.attempts)
        assert_true(reloaded.next_attempt_at > os.time())
        assert_equal(0, #Queue.due())
    end)

    it("permanently fails after the maximum attempts", function()
        Storage.reset()
        Queue.clear()
        Queue.enqueue({ operation = "progress", book_id = "1", payload = { percent = 10 } })
        local op_id = Queue.due()[1].id
        for _ = 1, #Constants.BACKOFF do
            Queue.markFailure(op_id, Constants.ERROR.NETWORK_ERROR)
        end
        assert_true(Queue.all()[op_id].failed)
        assert_equal(1, #Queue.failed())
        Queue.clearFailed()
        assert_equal(0, #Queue.failed())
    end)

    it("removes an operation on success", function()
        Storage.reset()
        Queue.clear()
        Queue.enqueue({ operation = "progress", book_id = "1", payload = { percent = 10 } })
        local op_id = Queue.due()[1].id
        Queue.remove(op_id)
        assert_equal(0, Queue.size())
    end)
end)
