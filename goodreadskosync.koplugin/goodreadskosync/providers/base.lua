--[[--
Provider interface.

Every provider normalizes its own transport into the canonical shelf states,
error codes, and result shapes defined in constants.lua. The rest of the
plugin never sees provider-specific response formats.

@module koplugin.goodreads.providers.base
--]]

local Constants = require("goodreadskosync.constants")

local Base = {}
Base.__index = Base
Base.id = "base"
Base.display_name = "Base"

-- Minimal single-inheritance helper. `extra` may add methods or override
-- class fields; instances are created with `Provider:new(opts)`.
function Base:extend(extra)
    local class = {}
    for key, value in pairs(self) do class[key] = value end
    class.__index = class
    class.super = self
    for key, value in pairs(extra or {}) do class[key] = value end
    return class
end

function Base:new(opts)
    local instance = setmetatable({}, self)
    if instance._init then instance:_init(opts) end
    return instance
end

function Base:_init(opts)
    self.opts = opts or {}
end

function Base:get_id()
    return self.id
end

function Base:get_display_name()
    return self.display_name
end

-- Availability probe. Returns boolean, reason.
function Base:is_available()
    return false, "not implemented"
end

-- Whether the provider's operations are actually implemented. A provider may
-- be detected/available but not yet implemented; automatic selection skips it.
function Base:is_implemented()
    return true
end

-- Authentication. Returns true, account or false, error.
function Base:authenticate()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:logout()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

-- Returns an account table { username, display_name } or nil, error.
function Base:get_account()
    return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

-- Search. Returns a list of candidate tables or nil, error.
-- Candidate shape:
--   { goodreads_id, title, authors, isbn10, isbn13, asin,
--     publisher, publication_year, language }
function Base:search_books()
    return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:get_book()
    return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

-- Shelf operations. `shelf` is one of Constants.SHELF.
function Base:set_shelf()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:get_shelf()
    return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:get_shelves()
    return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:get_book_shelves()
    return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

-- Best-effort whole library: list of { slug, name, custom, count } or nil.
function Base:get_library()
    return nil, Constants.ERROR.UNSUPPORTED
end

-- One page of books on a shelf: books, has_more.
function Base:get_shelf_books()
    return nil, false
end

function Base:add_to_shelf()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:remove_shelf()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:get_rating()
    return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:is_authenticated()
    return false, Constants.ERROR.AUTH_REQUIRED
end

function Base:validate_session()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:refresh_session()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:update_progress()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:mark_read()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:mark_currently_reading()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:mark_want_to_read()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

-- Rating is an integer 1..5.
function Base:set_rating()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:clear_rating()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

-- Reading Challenge / stats (optional extras).
function Base:get_reading_challenge()
    return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:set_reading_goal()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

function Base:get_reading_stats()
    return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
end

-- Capabilities let the sync engine adapt without provider-specific checks.
function Base:get_capabilities()
    return {
        search = true,
        shelves = true,
        progress = true,
        completion = true,
        rating = true,
        authentication = false,
        reading_challenge = false,
        reading_goal = false,
        reading_stats = false,
    }
end

return Base
