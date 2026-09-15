--[[--
Remote shelf cache policy.

The remote shelf read (`GET /review/edit/<id>`) is a full HTML page, so it is
only refreshed when it matters: forced (document open / manual sync), missing,
or older than a TTL. In between, the cached value is reused so periodic
progress syncs stay cheap.

@module koplugin.goodreads.sync.shelf_cache
--]]

local ShelfCache = {}

-- Whether the remote shelf must be fetched again.
function ShelfCache.needsRefresh(state, now, force, ttl)
    if force then return true end
    if type(state) ~= "table" then return true end
    local at = state.remote_shelf_at
    if type(at) ~= "number" then return true end
    if ttl and (now - at) > ttl then return true end
    return false
end

-- Store a successful remote read (including "no shelf", so a removed book is
-- not refetched until the TTL/refresh is due).
function ShelfCache.apply(state, remote, now)
    if type(state) ~= "table" or type(remote) ~= "table" then return state end
    state.remote_shelf = remote.shelf
    state.remote_rating = remote.rating
    state.remote_shelf_at = now or os.time()
    return state
end

-- Record the result of a local write so the cache stays consistent.
function ShelfCache.invalidate(state, shelf, now)
    if type(state) ~= "table" then return state end
    state.remote_shelf = shelf
    state.remote_shelf_at = now or os.time()
    return state
end

return ShelfCache
