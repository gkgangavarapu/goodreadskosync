--[[--
Sync engine.

`decide` is pure decision logic (no I/O) and `apply` is the only part that
talks to a provider. The engine knows nothing about how a book was
identified: it receives a canonical identity and a local progress snapshot.

@module koplugin.goodreads.sync.engine
--]]

local Constants = require("goodreadskosync.constants")
local Progress = require("goodreadskosync.sync.progress")
local Queue = require("goodreadskosync.sync.queue")
local Rating = require("goodreadskosync.sync.rating")
local Shelves = require("goodreadskosync.sync.shelves")

local Engine = {}

-- input:
--   state         per-book sync state
--   percent       whole-number local percent (or nil)
--   status        KOReader summary status ("complete" or other)
--   rating        explicit rating 1..5 (or nil)
--   capabilities  provider capabilities
--   settings      { auto_shelf, auto_progress, completion_behavior }
--   shelf_override, user_override
-- Returns a list of actions.
function Engine.decide(input)
    input = input or {}
    local state = input.state or {}
    local caps = input.capabilities or {}
    local settings = input.settings or {}
    local actions = {}

    local desired_shelf = Shelves.forState(input.percent, input.status, {
        shelf_override = input.shelf_override,
        allow_percent_completion = settings.completion_behavior
            == Constants.COMPLETION_BEHAVIOR.PERCENT_99,
    })

    if caps.shelves and settings.auto_shelf ~= false
        and Shelves.shouldApply(state.shelf, desired_shelf,
            { user_override = input.user_override }) then
        actions[#actions + 1] = { type = "shelf", shelf = desired_shelf }
    end

    if caps.progress and settings.auto_progress ~= false
        and type(input.percent) == "number"
        and Progress.shouldSync(state, input.percent) then
        local unit = input.sync_unit or "percent"
        local value = input.percent
        if unit == "pages" and type(input.page_value) == "number" then
            value = input.page_value
        else
            unit = "percent"
        end
        actions[#actions + 1] = {
            type = "progress",
            percent = input.percent,
            value = value,
            unit = unit,
        }
    end

    if caps.rating and input.rating and Rating.isValid(input.rating)
        and state.rating ~= input.rating then
        actions[#actions + 1] = { type = "rating", rating = input.rating }
    end

    return actions
end

-- Perform the actions against a provider. Returns a list of results.
function Engine.apply(provider, book_id, actions)
    local results = {}
    for _, action in ipairs(actions or {}) do
        local ok, err
        if action.type == "shelf" then
            ok, err = provider:set_shelf(book_id, action.shelf)
        elseif action.type == "progress" then
            ok, err = provider:update_progress(book_id,
                action.value or action.percent, action.unit)
        elseif action.type == "rating" then
            ok, err = provider:set_rating(book_id, action.rating)
        else
            ok, err = false, Constants.ERROR.INVALID_REQUEST
        end
        results[#results + 1] = {
            action = action,
            ok = ok and true or false,
            error = err,
        }
    end
    return results
end

-- Fold results into the per-book state. Only confirmed successes advance the
-- "last successful" markers.
function Engine.updateState(state, results, now)
    now = now or os.time()
    local any_success = false
    for _, result in ipairs(results or {}) do
        if result.ok then
            any_success = true
            if result.action.type == "shelf" then
                state.shelf = result.action.shelf
                state.last_pushed_shelf = result.action.shelf
            elseif result.action.type == "progress" then
                local percent = result.action.percent or result.action.value
                Progress.recordSuccess(state, percent)
                state.last_cloud_percent = percent
                if result.action.unit == "pages" then
                    state.last_successful_page = result.action.value
                end
            elseif result.action.type == "rating" then
                state.rating = result.action.rating
            end
        else
            state.last_error = result.error or Constants.ERROR.SERVER_ERROR
        end
    end
    if any_success then
        state.last_sync_at = now
        state.last_error = nil
    end
    return state
end

-- Queue every failed action for later retry.
function Engine.enqueueFailures(queue, book_id, results)
    queue = queue or Queue
    local count = 0
    for _, result in ipairs(results or {}) do
        if not result.ok then
            queue.enqueue({
                operation = result.action.type,
                book_id = book_id,
                payload = result.action,
            })
            count = count + 1
        end
    end
    return count
end

-- High-level orchestration used by the UI and lifecycle hooks.
--
-- opts:
--   provider, identity, state, percent, status, rating,
--   settings, capabilities, queue, now
-- Returns results, updated state.
function Engine.sync(opts)
    opts = opts or {}
    local identity = opts.identity or {}
    local book_id = identity.goodreads_id
    local state = opts.state or {}

    if not book_id then
        return { { action = { type = "identify" }, ok = false,
            error = Constants.ERROR.INVALID_REQUEST } }, state
    end

    local actions = Engine.decide({
        state = state,
        percent = opts.percent,
        status = opts.status,
        rating = opts.rating,
        capabilities = opts.capabilities,
        settings = opts.settings,
        shelf_override = opts.shelf_override,
        user_override = opts.user_override,
    })
    local results = Engine.apply(opts.provider, book_id, actions)
    Engine.updateState(state, results, opts.now)
    Engine.enqueueFailures(opts.queue, book_id, results)
    return results, state
end

return Engine
