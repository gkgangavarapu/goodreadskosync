--[[--
Per-book sync state.

@module koplugin.goodreads.sync.state
--]]

local Constants = require("goodreadskosync.constants")
local Storage = require("goodreadskosync.storage")

local State = {}

local function store()
    return Storage.open(Constants.STORAGE.SYNC_STATE)
end

function State.default(local_key)
    return {
        local_key = local_key,
        goodreads_id = nil,
        last_local_percent = nil,
        last_cloud_percent = nil,
        last_successful_percent = nil,
        last_successful_page = nil,
        shelf = nil,
        last_pushed_shelf = nil,
        remote_shelf = nil,
        remote_shelf_at = nil,
        remote_rating = nil,
        override_shelf = nil,
        override_baseline_percent = nil,
        completed = false,
        rating = nil,
        rating_prompted = false,
        last_sync_at = nil,
        last_error = nil,
    }
end

function State.get(local_key)
    if not local_key then return State.default(nil) end
    local books = store():get("books", {})
    local existing = books[local_key]
    if not existing then return State.default(local_key) end
    local state = State.default(local_key)
    for key, value in pairs(existing) do state[key] = value end
    return state
end

function State.set(local_key, state)
    if not local_key then return false end
    local s = store()
    local books = s:get("books", {})
    books[local_key] = state
    s:set("books", books)
    return s:flush()
end

function State.patch(local_key, patch)
    local state = State.get(local_key)
    for key, value in pairs(patch or {}) do state[key] = value end
    State.set(local_key, state)
    return state
end

function State.all()
    return store():get("books", {})
end

return State
