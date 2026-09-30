--[[--
Search query construction and result caching.

Search results are cached separately from permanent mappings: the cache
expires, a mapping does not.

@module koplugin.goodreads.resolver.search
--]]

local Constants = require("goodreadskosync.constants")
local Logging = require("goodreadskosync.logging")
local Storage = require("goodreadskosync.storage")
local Util = require("goodreadskosync.util")

local Search = {}

-- Build the most selective query available for an identity.
function Search.buildQuery(identity)
    identity = identity or {}
    if identity.isbn13 then return identity.isbn13 end
    if identity.isbn10 then return identity.isbn10 end
    if identity.asin then return identity.asin end
    local title = Util.trim(identity.title or "")
    local author = Util.trim(identity.primary_author or "")
    if title ~= "" and author ~= "" then
        return title .. " " .. author
    end
    return title
end

function Search.cacheKey(query)
    return Util.sha256Hex((query or ""):lower())
end

local function loadCache()
    local store = Storage.open(Constants.STORAGE.SEARCH_CACHE)
    return store, store:get("entries", {})
end

function Search.getCached(query, now)
    now = now or os.time()
    local _, entries = loadCache()
    local entry = entries[Search.cacheKey(query)]
    if entry and type(entry.expires_at) == "number" and entry.expires_at > now then
        return entry.candidates
    end
    return nil
end

function Search.putCached(query, candidates, now)
    now = now or os.time()
    local store, entries = loadCache()
    entries[Search.cacheKey(query)] = {
        query = query,
        candidates = candidates,
        cached_at = now,
        expires_at = now + Constants.SEARCH_CACHE_TTL,
    }

    -- Bound the cache: drop expired entries first, then the oldest.
    local keys = {}
    for key, entry in pairs(entries) do
        if entry.expires_at and entry.expires_at <= now then
            entries[key] = nil
        else
            keys[#keys + 1] = key
        end
    end
    if #keys > Constants.SEARCH_CACHE_MAX then
        table.sort(keys, function(a, b)
            return (entries[a].cached_at or 0) < (entries[b].cached_at or 0)
        end)
        for i = 1, #keys - Constants.SEARCH_CACHE_MAX do
            entries[keys[i]] = nil
        end
    end

    store:set("entries", entries)
    store:flush()
    return true
end

function Search.clearCache()
    local store = Storage.open(Constants.STORAGE.SEARCH_CACHE)
    store:set("entries", {})
    store:flush()
end

-- Query a provider, consulting and updating the cache. Returns
-- candidates, query, error.
function Search.findCandidates(provider, identity, opts)
    opts = opts or {}
    local query = opts.query or Search.buildQuery(identity)
    if query == "" then
        return nil, query, Constants.ERROR.INVALID_REQUEST
    end

    if not opts.no_cache then
        local cached = Search.getCached(query, opts.now)
        if cached then
            Logging.diag("search: cache hit query=", tostring(query),
                " candidates=", tostring(#cached))
            return cached, query
        end
    end

    local ok, candidates, err = pcall(provider.search_books, provider, query)
    if not ok then
        return nil, query, Constants.ERROR.PROVIDER_UNAVAILABLE
    end
    if not candidates then
        return nil, query, err or Constants.ERROR.INVALID_RESPONSE
    end
    Logging.diag("search: query=", tostring(query), " candidates=", tostring(#candidates))

    if not opts.no_cache then
        Search.putCached(query, candidates, opts.now)
    end
    return candidates, query
end

return Search
