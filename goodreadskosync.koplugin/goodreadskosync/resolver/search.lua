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

-- The title/author query. Also the fallback when an identifier query finds
-- nothing: the identifier may not be indexed by Goodreads (or may belong to an
-- edition its autocomplete does not return), and a title search still finds the
-- work so the user can pick the right edition.
function Search.buildTitleQuery(identity)
    identity = identity or {}
    local title = Util.trim(identity.title or "")
    local author = Util.trim(identity.primary_author or "")
    if title ~= "" and author ~= "" then
        return title .. " " .. author
    end
    return title
end

-- Build the most selective query available for an identity.
function Search.buildQuery(identity)
    identity = identity or {}
    if identity.goodreads_id then return tostring(identity.goodreads_id) end
    if identity.isbn13 then return identity.isbn13 end
    if identity.isbn10 then return identity.isbn10 end
    if identity.asin then return identity.asin end
    return Search.buildTitleQuery(identity)
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

-- Run one query, consulting and updating the cache. Returns candidates or
-- nil, error.
local function query_provider(provider, query, opts)
    if not opts.no_cache then
        local cached = Search.getCached(query, opts.now)
        if cached then
            Logging.diag("search: cache hit query=", tostring(query),
                " candidates=", tostring(#cached))
            return cached
        end
    end

    local ok, candidates, err = pcall(provider.search_books, provider, query)
    if not ok then
        return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
    end
    if not candidates then
        return nil, err or Constants.ERROR.INVALID_RESPONSE
    end
    Logging.diag("search: query=", tostring(query), " candidates=", tostring(#candidates))

    if not opts.no_cache then
        Search.putCached(query, candidates, opts.now)
    end
    return candidates
end

-- Query a provider, consulting and updating the cache. Returns
-- candidates, query, error.
function Search.findCandidates(provider, identity, opts)
    opts = opts or {}
    local query = opts.query or Search.buildQuery(identity)
    if query == "" then
        return nil, query, Constants.ERROR.INVALID_REQUEST
    end

    local candidates, err = query_provider(provider, query, opts)
    if not candidates then
        return nil, query, err
    end

    -- An identifier query that returned nothing does not mean the book is
    -- absent: fall back to title/author so the user still gets editions to pick
    -- from, instead of "no matches". Never overrides an explicit query.
    if #candidates == 0 and not opts.query then
        local fallback = Search.buildTitleQuery(identity)
        if fallback ~= "" and fallback ~= query then
            Logging.diag("search: no results for ", tostring(query),
                ", trying ", tostring(fallback))
            local more = query_provider(provider, fallback, opts)
            if more and #more > 0 then
                return more, fallback
            end
        end
    end

    return candidates, query
end

return Search
