--[[--
Offline operation queue.

Operations are keyed by (operation, book) so repeated enqueues coalesce into
one idempotent pending operation. Failures back off exponentially and stop
after the configured number of attempts.

@module koplugin.goodreads.sync.queue
--]]

local Constants = require("goodreadskosync.constants")
local Storage = require("goodreadskosync.storage")

local Queue = {}

local function store()
    return Storage.open(Constants.STORAGE.QUEUE)
end

function Queue.idempotencyKey(operation)
    return string.format("%s:%s", operation.operation or "?",
        tostring(operation.book_id or "?"))
end

-- operation = { operation, book_id, payload }
function Queue.enqueue(operation)
    if type(operation) ~= "table" or not operation.operation then
        return false, Constants.ERROR.INVALID_REQUEST
    end
    local s = store()
    local ops = s:get("ops", {})
    local key = Queue.idempotencyKey(operation)
    local now = os.time()
    local existing = ops[key]
    if existing then
        existing.payload = operation.payload
        existing.local_key = operation.local_key
        existing.attempts = 0
        existing.failed = false
        existing.last_error = nil
        existing.next_attempt_at = now
        existing.updated_at = now
    else
        ops[key] = {
            id = key,
            operation = operation.operation,
            book_id = operation.book_id,
            local_key = operation.local_key,
            payload = operation.payload,
            created_at = now,
            updated_at = now,
            attempts = 0,
            failed = false,
            next_attempt_at = now,
            last_error = nil,
        }
    end
    s:set("ops", ops)
    s:flush()
    return true
end

function Queue.all()
    return store():get("ops", {})
end

function Queue.size()
    local n = 0
    for _ in pairs(Queue.all()) do n = n + 1 end
    return n
end

-- Operations whose retry time has arrived and that have not permanently failed.
function Queue.due(now)
    now = now or os.time()
    local due = {}
    for _, op in pairs(Queue.all()) do
        if not op.failed and (op.next_attempt_at or 0) <= now then
            due[#due + 1] = op
        end
    end
    table.sort(due, function(a, b) return a.created_at < b.created_at end)
    return due
end

function Queue.remove(op_id)
    local s = store()
    local ops = s:get("ops", {})
    if ops[op_id] == nil then return false end
    ops[op_id] = nil
    s:set("ops", ops)
    s:flush()
    return true
end

function Queue.markFailure(op_id, error)
    local s = store()
    local ops = s:get("ops", {})
    local op = ops[op_id]
    if not op then return false end
    op.attempts = (op.attempts or 0) + 1
    op.last_error = error
    op.updated_at = os.time()
    local became_failed = false
    if op.attempts >= #Constants.BACKOFF then
        op.failed = true
        became_failed = true
    else
        op.next_attempt_at = os.time() + Constants.BACKOFF[op.attempts + 1]
    end
    s:set("ops", ops)
    s:flush()
    return true, became_failed
end

function Queue.failed()
    local failed = {}
    for _, op in pairs(Queue.all()) do
        if op.failed then failed[#failed + 1] = op end
    end
    return failed
end

function Queue.clearFailed()
    local s = store()
    local ops = s:get("ops", {})
    for id, op in pairs(ops) do
        if op.failed then ops[id] = nil end
    end
    s:set("ops", ops)
    s:flush()
    return true
end

function Queue.clear()
    local s = store()
    s:set("ops", {})
    s:flush()
end

return Queue
