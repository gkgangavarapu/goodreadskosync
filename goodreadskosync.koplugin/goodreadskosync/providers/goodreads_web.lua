--[[--
Primary Goodreads provider (web session).

Implements the provider interface by delegating to `goodreads.api` using the
session stored by `auth.session`. It performs no authentication mechanics
itself: interactive login is owned by `auth.manager` / `auth.login`, and this
provider simply reports whether a usable session exists.

@module koplugin.goodreads.providers.goodreads_web
--]]

local Base = require("goodreadskosync.providers.base")
local Api = require("goodreadskosync.goodreads.api")
local Constants = require("goodreadskosync.constants")
local Logging = require("goodreadskosync.logging")
local Session = require("goodreadskosync.auth.session")

local GoodreadsWeb = Base:extend({
    id = "goodreads_web",
    display_name = "Goodreads (web)",
})

function GoodreadsWeb:_init(opts)
    Base._init(self, opts)
    self.transport = opts and opts.transport or nil
end

function GoodreadsWeb:is_available()
    -- Always selectable: availability of the network is discovered at call
    -- time, and login state is reported separately.
    return true, "requires an authenticated session"
end

function GoodreadsWeb:is_implemented()
    return true
end

function GoodreadsWeb:get_capabilities()
    return {
        search = true,
        shelves = true,
        progress = true,
        completion = true,
        rating = true,
        authentication = true,
    }
end

local function result_has_auth_error(...)
    for i = 1, select("#", ...) do
        if (select(i, ...)) == Constants.ERROR.AUTH_REQUIRED then return true end
    end
    return false
end

-- Build a client from the stored session, run `fn`, then persist any rotated
-- cookies and session state. With opts.best_effort, an auth error does not
-- invalidate the session (used for optional reads).
function GoodreadsWeb:_with_client(fn, opts)
    opts = opts or {}
    local session = Session.load()
    if not Session.is_valid(session) then
        return nil, Constants.ERROR.AUTH_REQUIRED
    end
    local http = Session.to_http(session, { transport = self.transport })
    local client = Api:new(http)

    local ok, a, b, c = pcall(fn, client)
    Session.absorb(session, http)
    if not ok then
        Session.save(session)
        Logging.warn("goodreads_web: operation failed")
        return nil, Constants.ERROR.PROVIDER_UNAVAILABLE
    end
    if result_has_auth_error(a, b, c) then
        if not opts.best_effort then
            Session.mark_expired(session, Constants.ERROR.AUTH_REQUIRED)
        end
    else
        Session.mark_valid(session)
    end
    Session.save(session)
    return a, b, c
end

--------------------------------------------------------------------------------
-- Account / auth lifecycle
--------------------------------------------------------------------------------

function GoodreadsWeb:authenticate()
    local session = Session.load()
    if Session.is_valid(session) then
        return true, { username = session.username or session.user_id }
    end
    return false, Constants.ERROR.AUTH_REQUIRED
end

function GoodreadsWeb:is_authenticated()
    return Session.is_valid(Session.load())
end

function GoodreadsWeb:logout()
    Session.clear()
    return true
end

function GoodreadsWeb:get_account()
    local session = Session.load()
    if not Session.is_valid(session) then
        return nil, Constants.ERROR.AUTH_REQUIRED
    end
    return { id = session.user_id, username = session.username or session.user_id }
end

--------------------------------------------------------------------------------
-- Operations
--------------------------------------------------------------------------------

function GoodreadsWeb:search_books(query)
    return self:_with_client(function(client) return client:search_books(query) end)
end

function GoodreadsWeb:get_book(book_id)
    return self:_with_client(function(client) return client:get_book(book_id) end)
end

function GoodreadsWeb:get_shelves()
    return self:_with_client(function(client) return client:get_shelves() end)
end

function GoodreadsWeb:get_book_shelves(book_id)
    return self:_with_client(function(client)
        return client:get_book_shelves(book_id)
    end, { best_effort = true })
end

function GoodreadsWeb:get_library()
    return self:_with_client(function(client)
        return client:get_library()
    end, { best_effort = true })
end

function GoodreadsWeb:get_shelf_books(shelf, page)
    return self:_with_client(function(client)
        return client:get_shelf_books(shelf, page)
    end, { best_effort = true })
end

function GoodreadsWeb:add_to_shelf(book_id, slug)
    return self:_with_client(function(client)
        return client:add_to_shelf(book_id, slug)
    end)
end

function GoodreadsWeb:set_shelf(book_id, shelf)
    return self:_with_client(function(client) return client:set_shelf(book_id, shelf) end)
end

function GoodreadsWeb:remove_shelf(book_id)
    return self:_with_client(function(client) return client:remove_shelf(book_id) end)
end

function GoodreadsWeb:get_shelf(book_id)
    local state, err = self:get_book_shelves(book_id)
    if not state then return nil, err end
    return state.shelf
end

function GoodreadsWeb:update_progress(book_id, value, unit, note)
    return self:_with_client(function(client)
        return client:update_progress(book_id, value, unit, note)
    end)
end

function GoodreadsWeb:mark_read(book_id)
    return self:_with_client(function(client) return client:mark_read(book_id) end)
end

function GoodreadsWeb:mark_currently_reading(book_id)
    return self:_with_client(function(client)
        return client:mark_currently_reading(book_id)
    end)
end

function GoodreadsWeb:mark_want_to_read(book_id)
    return self:_with_client(function(client)
        return client:mark_want_to_read(book_id)
    end)
end

function GoodreadsWeb:get_rating(book_id)
    return self:_with_client(function(client) return client:get_rating(book_id) end)
end

function GoodreadsWeb:set_rating(book_id, rating)
    return self:_with_client(function(client) return client:set_rating(book_id, rating) end)
end

function GoodreadsWeb:clear_rating(_book_id)
    -- Goodreads has no explicit "clear" in the classic endpoints; rating 0 is
    -- not accepted. Report unsupported rather than guess.
    return false, Constants.ERROR.UNSUPPORTED
end

return GoodreadsWeb
