--[[--
Mock provider.

Ships with NO built-in book catalogue: `search_books` returns nothing unless a
catalogue is injected (by the caller or by tests). This keeps fake book data
out of the production plugin while still allowing the full open -> identify ->
map -> sync flow to be exercised end to end.

State (shelf, progress, rating) is persisted per Goodreads ID so that a "Sync
Now" has an observable effect across restarts.

@module koplugin.goodreads.providers.mock
--]]

local Base = require("goodreadskosync.providers.base")
local Constants = require("goodreadskosync.constants")
local Logging = require("goodreadskosync.logging")
local Storage = require("goodreadskosync.storage")
local Util = require("goodreadskosync.util")

local Mock = Base:extend({
    id = "mock",
    display_name = "Mock (offline)",
})

local function account_store()
    return Storage.open("mock_account")
end

local function state_store()
    return Storage.open("mock_state")
end

local function matches(book, query)
    if not query or query == "" then return true end
    local q = query:lower()
    local haystack = table.concat({
        book.title or "",
        book.goodreads_id or "",
        book.isbn13 or "",
        book.isbn10 or "",
        book.asin or "",
        table.concat(book.authors or {}, " "),
    }, " "):lower()
    return haystack:find(q, 1, true) ~= nil
end

function Mock:_init(opts)
    Base._init(self, opts)
    opts = opts or {}
    self.catalog = opts.catalog or {}
    self.available = opts.available ~= false
    self._states = state_store():get("books", {})
end

function Mock:set_catalog(catalog)
    self.catalog = catalog or {}
end

function Mock:is_available()
    if not self.available then return false, "disabled" end
    return true, "mock provider is always available"
end

function Mock:get_capabilities()
    return {
        search = true,
        shelves = true,
        progress = true,
        completion = true,
        rating = true,
        authentication = true,
        reading_challenge = true,
        reading_goal = true,
        reading_stats = true,
    }
end

function Mock:authenticate()
    if not self.available then
        return false, Constants.ERROR.PROVIDER_UNAVAILABLE
    end
    local account = { username = "mock-user", display_name = "Mock User" }
    local store = account_store()
    store:set("account", account)
    store:flush()
    return true, account
end

function Mock:logout()
    local store = account_store()
    store:delete("account")
    store:flush()
    return true
end

function Mock:get_account()
    local account = account_store():get("account")
    if not account then return nil, Constants.ERROR.AUTH_REQUIRED end
    return account
end

function Mock:search_books(query)
    local results = {}
    for _, book in ipairs(self.catalog) do
        if matches(book, query) then
            results[#results + 1] = Util.deepcopy(book)
        end
    end
    return results
end

function Mock:get_book(goodreads_id)
    for _, book in ipairs(self.catalog) do
        if tostring(book.goodreads_id) == tostring(goodreads_id) then
            return Util.deepcopy(book)
        end
    end
    return nil, Constants.ERROR.NOT_FOUND
end

local function valid_shelf(shelf)
    return shelf == Constants.SHELF.WANT_TO_READ
        or shelf == Constants.SHELF.CURRENTLY_READING
        or shelf == Constants.SHELF.READ
        or shelf == Constants.SHELF.DID_NOT_FINISH
end

function Mock:_state_for(book_id)
    local key = tostring(book_id)
    self._states[key] = self._states[key] or {}
    return self._states[key]
end

function Mock:_persist()
    local store = state_store()
    store:set("books", self._states)
    store:flush()
end

function Mock:set_shelf(book_id, shelf)
    if not valid_shelf(shelf) then
        return false, Constants.ERROR.INVALID_REQUEST
    end
    local state = self:_state_for(book_id)
    state.shelf = shelf
    state.shelf_updated_at = os.time()
    self:_persist()
    Logging.debug("mock: set shelf", shelf, "for", book_id)
    return true
end

function Mock:get_shelf(book_id)
    local state = self._states[tostring(book_id)]
    if not state then return nil, Constants.ERROR.NOT_FOUND end
    return state.shelf
end

local SLUG_FOR = {
    [Constants.SHELF.WANT_TO_READ] = "to-read",
    [Constants.SHELF.CURRENTLY_READING] = "currently-reading",
    [Constants.SHELF.READ] = "read",
    [Constants.SHELF.DID_NOT_FINISH] = "did-not-finish",
}
local SHELF_FOR_SLUG = {
    ["to-read"] = Constants.SHELF.WANT_TO_READ,
    ["currently-reading"] = Constants.SHELF.CURRENTLY_READING,
    ["read"] = Constants.SHELF.READ,
    ["did-not-finish"] = Constants.SHELF.DID_NOT_FINISH,
}

function Mock:get_library()
    local shelves = {
        { slug = "currently-reading", name = "Currently Reading", books = {} },
        { slug = "read", name = "Read", books = {} },
        { slug = "to-read", name = "Want to Read", books = {} },
        { slug = "did-not-finish", name = "Did Not Finish", books = {} },
    }
    local by_slug = {}
    for i = 1, #shelves do by_slug[shelves[i].slug] = shelves[i] end
    for _, book in ipairs(self.catalog) do
        local id = tostring(book.goodreads_id)
        local state = self._states[id] or {}
        local slug = SLUG_FOR[state.shelf] or "to-read"
        local s = by_slug[slug]
        s.books[#s.books + 1] = { goodreads_id = id, title = book.title }
    end
    return shelves
end

function Mock:get_shelf_books(shelf)
    local name = type(shelf) == "table" and (shelf.slug or shelf.name) or shelf
    local books = {}
    for _, book in ipairs(self.catalog) do
        local id = tostring(book.goodreads_id)
        local state = self._states[id] or {}
        local slug = SLUG_FOR[state.shelf] or "to-read"
        if slug == name then
            books[#books + 1] = { goodreads_id = id, title = book.title }
        end
    end
    return books, false
end

function Mock:add_to_shelf(book_id, slug)
    local shelf = SHELF_FOR_SLUG[slug]
    if not shelf then return false, Constants.ERROR.INVALID_REQUEST end
    return self:set_shelf(book_id, shelf)
end

function Mock:get_progress(book_id)
    local state = self._states[tostring(book_id)]
    if not state then return nil, Constants.ERROR.NOT_FOUND end
    return state.progress
end

function Mock:get_rating(book_id)
    local state = self._states[tostring(book_id)]
    if not state then return nil, Constants.ERROR.NOT_FOUND end
    return state.rating
end

function Mock:update_progress(book_id, percent)
    percent = tonumber(percent)
    if not percent or percent < 0 or percent > 100 then
        return false, Constants.ERROR.INVALID_REQUEST
    end
    local state = self:_state_for(book_id)
    state.progress = math.floor(percent)
    state.progress_updated_at = os.time()
    self:_persist()
    Logging.debug("mock: update progress", percent, "for", book_id)
    return true
end

function Mock:mark_read(book_id)
    return self:set_shelf(book_id, Constants.SHELF.READ)
end

function Mock:mark_currently_reading(book_id)
    return self:set_shelf(book_id, Constants.SHELF.CURRENTLY_READING)
end

function Mock:mark_want_to_read(book_id)
    return self:set_shelf(book_id, Constants.SHELF.WANT_TO_READ)
end

function Mock:set_rating(book_id, rating)
    rating = tonumber(rating)
    if not rating or rating < 1 or rating > 5 or rating ~= math.floor(rating) then
        return false, Constants.ERROR.INVALID_REQUEST
    end
    local state = self:_state_for(book_id)
    state.rating = rating
    state.rating_updated_at = os.time()
    self:_persist()
    Logging.debug("mock: set rating", rating, "for", book_id)
    return true
end

function Mock:clear_rating(book_id)
    local state = self:_state_for(book_id)
    state.rating = nil
    state.rating_updated_at = os.time()
    self:_persist()
    return true
end

-- Reading Challenge / stats (offline approximations for tests and mock runs).

function Mock:get_reading_challenge()
    local goal = tonumber(state_store():get("challenge_goal")) or 0
    local books = {}
    for _, book in ipairs(self.catalog) do
        local state = self._states[tostring(book.goodreads_id)] or {}
        if state.shelf == Constants.SHELF.READ then
            books[#books + 1] = { book_uri = "kca://book/" .. tostring(book.goodreads_id) }
        end
    end
    return {
        goal = goal,
        books_read = #books,
        days_remaining = 100,
        books = books,
    }
end

function Mock:set_reading_goal(goal)
    goal = tonumber(goal)
    if not goal or goal < 1 or goal ~= math.floor(goal) then
        return false, Constants.ERROR.INVALID_REQUEST
    end
    local store = state_store()
    store:set("challenge_goal", goal)
    store:flush()
    return true, goal
end

function Mock:get_reading_stats()
    local counts = {}
    for _, book in ipairs(self.catalog) do
        local state = self._states[tostring(book.goodreads_id)] or {}
        if state.shelf == Constants.SHELF.READ then
            counts[2026] = (counts[2026] or 0) + 1
        end
    end
    local years = {}
    for year, count in pairs(counts) do
        years[#years + 1] = { year = year, books = count }
    end
    table.sort(years, function(a, b) return a.year > b.year end)
    return years
end

return Mock
