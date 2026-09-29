--[[--
Offline operation queue.

Most operations are keyed by (operation, book) so repeated enqueues coalesce
into one idempotent pending operation (progress, shelf, rating). Non-idempotent
operations (notes) are enqueued with `{ unique = true }`, so each keeps its own
slot and they flush in creation order. Items carry a monotonic `seq` so `due()`
returns them oldest-first (FIFO). Failures back off exponentially and stop after
the configured number of attempts; they are kept (not dropped) so the user can
retry or clear them.

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

-- operation = { operation, book_id, payload, uid? }
-- opts.unique = true gives the operation its own slot. Notes are not
-- idempotent, so without this every note for a book would overwrite the last.
function Queue.enqueue(operation, opts)
    if type(operation) ~= "table" or not operation.operation then
        return false, Constants.ERROR.INVALID_REQUEST
    end
    opts = opts or {}
    local s = store()
    local ops = s:get("ops", {})
    local key
    if operation.uid then
        key = string.format("%s:%s:%s", operation.operation,
            tostring(operation.book_id or "?"), tostring(operation.uid))
    elseif opts.unique then
        key = string.format("%s:%s:u%d-%d", operation.operation,
            tostring(operation.book_id or "?"), os.time(),
            math.random(1, 100000000))
    else
        key = Queue.idempotencyKey(operation)
    end

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
        local seq = (s:get("seq", 0) or 0) + 1
        s:set("seq", seq)
        ops[key] = {
            id = key,
            operation = operation.operation,
            book_id = operation.book_id,
            local_key = operation.local_key,
            payload = operation.payload,
            created_at = now,
            updated_at = now,
            seq = seq,
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
    -- Oldest first (FIFO). `seq` is monotonic; fall back to created_at for
    -- entries stored by older versions that predate `seq`.
    table.sort(due, function(a, b)
        local sa = a.seq or a.created_at or 0
        local sb = b.seq or b.created_at or 0
        if sa == sb then return (a.created_at or 0) < (b.created_at or 0) end
        return sa < sb
    end)
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

-- Mark an operation failed immediately, without consuming the retry schedule.
-- Used for errors that will not resolve by retrying (e.g. NOT_FOUND). The
-- payload is kept so the user can retry it manually or clear it.
function Queue.markFailed(op_id, error)
    local s = store()
    local ops = s:get("ops", {})
    local op = ops[op_id]
    if not op then return false end
    op.failed = true
    op.last_error = error
    op.updated_at = os.time()
    s:set("ops", ops)
    s:flush()
    return true
end

function Queue.failed()
    local failed = {}
    for _, op in pairs(Queue.all()) do
        if op.failed then failed[#failed + 1] = op end
    end
    return failed
end

-- Put every failed operation back in line for a manual retry. Returns how many
-- were requeued.
function Queue.retryFailed()
    local s = store()
    local ops = s:get("ops", {})
    local now = os.time()
    local n = 0
    for _, op in pairs(ops) do
        if op.failed then
            op.failed = false
            op.attempts = 0
            op.last_error = nil
            op.next_attempt_at = now
            op.updated_at = now
            n = n + 1
        end
    end
    if n > 0 then
        s:set("ops", ops)
        s:flush()
    end
    return n
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
