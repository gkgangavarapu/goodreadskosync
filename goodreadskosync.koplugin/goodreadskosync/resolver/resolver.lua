--[[--
Resolution pipeline: local document -> canonical Goodreads identity.

The resolver knows nothing about authentication. It receives a provider purely
as a metadata search source, and returns a decision for the caller (and UI) to
act on. It never silently accepts a low-confidence title/author match.

@module koplugin.goodreads.resolver.resolver
--]]

local Identifiers = require("goodreadskosync.resolver.identifiers")
local Logging = require("goodreadskosync.logging")
local Matcher = require("goodreadskosync.resolver.matcher")
local Search = require("goodreadskosync.resolver.search")

local Resolver = {}

-- Build the canonical identity for a document's metadata.
function Resolver.identify(metadata, filename)
    return Identifiers.build(metadata, filename)
end

-- Resolve a book.
--
-- opts:
--   metadata        parsed OPF metadata (resolver.epub output)
--   filename        basename, used for identifiers embedded in the name
--   provider        provider instance used only for search_books (optional)
--   mappings        object exposing get(local_key) (optional)
--   ignore_mapping  bypass a stored mapping (used by "Change book")
--   now, no_cache   passed through to the search cache
--
-- Returns a result table with a `status` field:
--   "mapped"        an existing confirmed mapping was used
--   "auto"          a hard-identifier match was selected automatically
--   "confirm"       a likely match needs user confirmation
--   "manual"        the user must choose
--   "unidentified"  nothing was found
--   "error"         the search failed
function Resolver.resolve(opts)
    opts = opts or {}
    local identity = Identifiers.build(opts.metadata, opts.filename)
    local local_key = identity.local_key

    if not opts.ignore_mapping and opts.mappings and opts.mappings.get then
        local mapping = opts.mappings.get(local_key)
        if mapping and mapping.confirmed then
            Logging.diag("resolver: mapped local_key=", tostring(local_key),
                " gid=", tostring(mapping.goodreads_id))
            return {
                status = "mapped",
                identity = identity,
                local_key = local_key,
                selected = mapping,
                mapping = mapping,
                candidates = {},
            }
        end
    end

    if not opts.provider then
        return {
            status = "unidentified",
            identity = identity,
            local_key = local_key,
            candidates = {},
            reason = "no_provider",
        }
    end

    local candidates, query, err = Search.findCandidates(opts.provider, identity, {
        now = opts.now,
        no_cache = opts.no_cache,
        query = opts.query,
    })
    if not candidates then
        return {
            status = "error",
            identity = identity,
            local_key = local_key,
            candidates = {},
            query = query,
            error = err,
        }
    end

    local ranked = Matcher.rank(identity, candidates)
    local best = Matcher.bestAutomatic(ranked)
    Logging.diag("resolver: query=", tostring(query), " candidates=", tostring(#ranked),
        " best=", tostring(best and best.goodreads_id),
        " best_decision=", tostring(best and best.decision or (ranked[1] and ranked[1].decision)))
    if best then
        return {
            status = "auto",
            identity = identity,
            local_key = local_key,
            candidates = ranked,
            selected = best,
            query = query,
        }
    end

    if #ranked > 0 then
        return {
            status = ranked[1].decision == "confirm" and "confirm" or "manual",
            identity = identity,
            local_key = local_key,
            candidates = ranked,
            query = query,
        }
    end

    return {
        status = "unidentified",
        identity = identity,
        local_key = local_key,
        candidates = {},
        query = query,
    }
end

-- Build a permanent mapping record from a selected candidate.
function Resolver.buildMapping(local_key, identity, candidate)
    return {
        local_key = local_key,
        goodreads_id = candidate.goodreads_id,
        isbn13 = candidate.isbn13 or identity.isbn13,
        isbn10 = candidate.isbn10 or identity.isbn10,
        asin = candidate.asin or identity.asin,
        title = candidate.title or identity.title,
        author = candidate.author
            or (candidate.authors and candidate.authors[1])
            or identity.primary_author,
        authors = candidate.authors or identity.authors,
        confirmed = true,
    }
end

return Resolver
