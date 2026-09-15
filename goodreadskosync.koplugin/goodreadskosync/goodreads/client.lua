--[[--
Goodreads client.

Turns the classic Goodreads web/Rails endpoints into normalized operations.
It knows nothing about authentication mechanics: it receives an already
configured `goodreads.http` object (with a session cookie) and returns the
plugin's canonical structures. UI code must never build Goodreads requests
itself.

@module koplugin.goodreads.goodreads.client
--]]

local Constants = require("goodreadskosync.constants")
local Json = require("goodreadskosync.goodreads.json")

local Client = {}
Client.__index = Client

local SHELF_SLUG = {
    [Constants.SHELF.WANT_TO_READ] = "to-read",
    [Constants.SHELF.CURRENTLY_READING] = "currently-reading",
    [Constants.SHELF.READ] = "read",
    [Constants.SHELF.DID_NOT_FINISH] = "did-not-finish",
}

local SHELF_FROM_SLUG = {
    ["to-read"] = Constants.SHELF.WANT_TO_READ,
    ["currently-reading"] = Constants.SHELF.CURRENTLY_READING,
    ["read"] = Constants.SHELF.READ,
    ["did-not-finish"] = Constants.SHELF.DID_NOT_FINISH,
}

function Client:new(http)
    return setmetatable({
        http = http,
        base_url = http.base_url or "https://www.goodreads.com",
    }, self)
end

local function normalize_auto_complete(self, item)
    local author = "Unknown Author"
    if type(item.author) == "table" and item.author.name then
        author = item.author.name
    end
    local book_id = item.bookId and tostring(item.bookId)
    return {
        goodreads_id = book_id,
        title = item.title or item.bookTitleBare,
        authors = { author },
        pages = tonumber(item.numPages) or nil,
        cover_url = item.imageUrl,
        url = book_id and (self.base_url .. "/book/show/" .. book_id) or nil,
    }
end

function Client:ensure_csrf()
    if self.http.csrf_token and self.http.csrf_token ~= "" then
        return self.http.csrf_token
    end
    local resp = self.http:get(self.base_url .. "/", { follow = true, detect_auth = true })
    if resp.error then return nil, resp.error end
    local csrf = resp.body and resp.body:match(
        '<meta%s+[^>]-name=["\']csrf%-token["\']%s+[^>]-content=["\']([^"\']+)["\']')
    if not csrf then return nil, Constants.ERROR.INVALID_RESPONSE end
    self.http.csrf_token = csrf
    local user_id = resp.body:match("/user/show/(%d+)")
    if user_id then self.http.user_id = user_id end
    return csrf
end

function Client:get_account()
    if not self.http.user_id then
        local _, err = self:ensure_csrf()
        if err then return nil, err end
    end
    return { id = self.http.user_id, username = self.http.user_id }
end

-- Annotate the first result with the searched identifier so the matcher can
-- treat a direct identifier lookup as a hard match.
local function annotate_query_identifier(results, query)
    if not results[1] or not query then return results end
    local first = results[1]
    local Util = require("goodreadskosync.util")
    local Isbn = require("goodreadskosync.resolver.isbn")
    local kind = Isbn.kind(query)
    if kind == "isbn13" then
        first.isbn13 = Isbn.to13(query)
    elseif kind == "isbn10" then
        first.isbn10 = Isbn.to10(query)
    elseif Util.isAsin(query:upper()) then
        first.asin = query:upper()
    elseif query:match("^%d+$") then
        first.goodreads_id = query
    end
    return results
end

function Client:search_books(query)
    if type(query) ~= "string" or query == "" then
        return {}, nil
    end
    local Http = require("goodreadskosync.goodreads.http")
    local url = self.base_url .. "/book/auto_complete?format=json&q=" .. Http.urlencode(query)
    local resp = self.http:get(url, { follow = true, detect_auth = false })
    if resp.error then return nil, resp.error end

    local decoded = Json.decode_any(resp.body)
    if type(decoded) ~= "table" then
        return nil, Constants.ERROR.INVALID_RESPONSE
    end

    local results = {}
    for _, item in ipairs(decoded) do
        results[#results + 1] = normalize_auto_complete(self, item)
    end
    return annotate_query_identifier(results, query), nil
end

local function parse_ldjson_book(html)
    if type(html) ~= "string" then return nil end
    local block = html:match('<script type="application/ld%+json">(.-)</script>')
    if not block then return nil end
    local decoded = Json.decode_any(block)
    if type(decoded) ~= "table" then return nil end
    local author
    if type(decoded.author) == "table" then
        if decoded.author[1] and decoded.author[1].name then
            author = decoded.author[1].name
        elseif decoded.author.name then
            author = decoded.author.name
        end
    end
    return {
        title = decoded.name,
        author = author,
        image = decoded.image,
        pages = tonumber(decoded.numberOfPages) or nil,
    }
end

function Client:get_book(book_id)
    if not book_id then return nil, Constants.ERROR.INVALID_REQUEST end
    book_id = tostring(book_id)
    local resp = self.http:get(self.base_url .. "/book/show/" .. book_id,
        { follow = true, detect_auth = true })
    if resp.error then return nil, resp.error end

    local ld = parse_ldjson_book(resp.body) or {}
    local pages = ld.pages
    if not pages and resp.body then
        pages = tonumber(resp.body:match('"numPages":(%d+)'))
    end
    return {
        goodreads_id = book_id,
        title = ld.title or ("Goodreads #" .. book_id),
        authors = { ld.author or "Unknown Author" },
        pages = pages,
        cover_url = ld.image,
        url = self.base_url .. "/book/show/" .. book_id,
    }, nil
end

function Client:get_shelves()
    -- Goodreads' canonical exclusive shelves are fixed.
    return {
        { slug = "to-read", shelf = Constants.SHELF.WANT_TO_READ, name = "Want to Read" },
        { slug = "currently-reading", shelf = Constants.SHELF.CURRENTLY_READING, name = "Currently Reading" },
        { slug = "read", shelf = Constants.SHELF.READ, name = "Read" },
        { slug = "did-not-finish", shelf = Constants.SHELF.DID_NOT_FINISH, name = "Did Not Finish" },
    }
end

-- The four reserved shelves; everything else is a custom shelf.
local DEFAULT_SHELVES = {
    ["to-read"] = true,
    ["currently-reading"] = true,
    ["read"] = true,
    ["did-not-finish"] = true,
}

-- The user's shelves (default + custom), parsed from the "My Books" page.
-- Returns a list of { slug, name, custom, count }, or nil when nothing could be
-- parsed. Custom shelves are addressed later with `tag=<name>`; default shelves
-- with `shelf=<slug>`.
function Client:get_user_shelves()
    local resp = self.http:get(self.base_url .. "/review/list", { follow = true, detect_auth = true })
    if resp.error then return nil, resp.error end
    local body = resp.body or ""

    -- The page instantiates the shelf chooser with every shelf name, custom
    -- ones included: new ShelfChooser("shelfChooserInput", 0, ["to-read", ...], {})
    local names = {}
    local arr = body:match("new%s+ShelfChooser%s*%(.-(%b[])")
    if arr then
        for name in arr:gmatch('"([^"]+)"') do names[#names + 1] = name end
    end

    -- Counts from the sidebar: <a ...shelf=to-read">Want to Read (30)</a>
    local counts = {}
    for name, n in body:gmatch("[%?&]shelf=([%w%-_%.]+)['\"]?[^>]*>[^<]-%((%d+)%)") do
        counts[name] = tonumber(n)
    end
    for name, n in body:gmatch("[%?&]tag=([%w%-_%.]+)['\"]?[^>]*>[^<]-%((%d+)%)") do
        counts[name] = tonumber(n)
    end

    local shelves, seen = {}, {}
    local function add(name)
        name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" or seen[name] then return end
        seen[name] = true
        shelves[#shelves + 1] = {
            slug = name,
            name = name,
            custom = not DEFAULT_SHELVES[name],
            count = counts[name],
        }
    end
    for i = 1, #names do add(names[i]) end
    if #shelves == 0 then
        for name in body:gmatch("[%?&]shelf=([%w%-_%.]+)") do add(name) end
        for name in body:gmatch("[%?&]tag=([%w%-_%.]+)") do add(name) end
    end
    if #shelves == 0 then return nil end
    return shelves
end

-- Books on one shelf (one page of up to 100). `shelf` is a { slug, custom }
-- table or a plain shelf name. Returns books, has_more.
function Client:get_shelf_books(shelf, page)
    if not shelf then return nil, false end
    local name, custom
    if type(shelf) == "table" then
        name, custom = shelf.slug or shelf.name, shelf.custom
    else
        name = shelf
    end
    if not name or name == "" then return nil, false end
    if custom == nil then custom = not DEFAULT_SHELVES[name] end
    page = page or 1
    local param = custom and ("tag=" .. name) or ("shelf=" .. name)
    local url = string.format("%s/review/list?%s&per_page=100&page=%d",
        self.base_url, param, page)
    local resp = self.http:get(url, { follow = true, detect_auth = true })
    if resp.error then return nil, false end
    local body = resp.body or ""
    local books, seen = {}, {}
    local function add(id, title)
        if not id or seen[id] then return end
        seen[id] = true
        title = (title or ""):gsub("^%s+", ""):gsub("%s+$", "")
        books[#books + 1] = { goodreads_id = id, title = title ~= "" and title or nil }
    end
    -- Scope to real book rows so we don't pick up recommendations/ads.
    for row in body:gmatch('<tr[^>]*class="[^"]*bookalike[^"]*review[^"]*"(.-)</tr>') do
        -- The title cell renders title before href; the cover anchor has no title.
        local title, id = row:match('<a[^>]-title="([^"]+)"[^>]-href="/book/show/(%d+)[^"]*"')
        if not id then
            id, title = row:match('href="/book/show/(%d+)[^"]*"[^>]-title="([^"]+)"')
        end
        if not id then
            id, title = row:match('href="/book/show/(%d+)[^"]*"[^>]*>%s*([^<]-)%s*<')
        end
        add(id, title)
    end
    if #books == 0 then
        for id, title in body:gmatch('href="/book/show/(%d+)[^"]*"[^>]-title="([^"]+)"') do
            add(id, title)
        end
    end
    local has_more = body:find('rel="next"', 1, true) ~= nil or #books >= 100
    return books, has_more
end

-- Add/move a book to an arbitrary shelf slug.
function Client:add_to_shelf(book_id, slug)
    if not book_id or not slug then return false, Constants.ERROR.INVALID_REQUEST end
    local csrf, err = self:ensure_csrf()
    if not csrf then return false, err end
    local resp = self.http:post_form(self.base_url .. "/shelf/add_to_shelf", {
        book_id = tostring(book_id),
        name = slug,
        a = "",
        authenticity_token = csrf,
    }, { csrf = true, follow = true, detect_auth = true })
    if resp.error then return false, resp.error end
    return true
end

-- Whole library as a shelf list (metadata only; books are loaded per shelf on
-- demand to keep each request small): { { slug, name, custom, count }, ... }.
-- Returns nil when nothing could be parsed (caller falls back to local data).
function Client:get_library()
    return self:get_user_shelves()
end

function Client:get_book_shelves(book_id)
    if not book_id then return nil, Constants.ERROR.INVALID_REQUEST end
    book_id = tostring(book_id)
    local resp = self.http:get(self.base_url .. "/review/edit/" .. book_id,
        { follow = true, detect_auth = true })
    if resp.error then return nil, resp.error end

    local body = resp.body or ""
    local slug = body:match('"shelf":{"__typename":"Shelf","name":"([%w%-]+)"')
        or body:match('name="review%[shelf%]"[^>]-value="([%w%-]+)"')
    local rating = tonumber(body:match('name="review%[rating%]"[^>]-value="(%d)"'))
        or tonumber(body:match('data%-rating="(%d)"'))
    return {
        shelf = slug and SHELF_FROM_SLUG[slug] or nil,
        slug = slug,
        rating = rating,
    }, nil
end

function Client:set_shelf(book_id, shelf)
    local slug = SHELF_SLUG[shelf]
    if not slug then return false, Constants.ERROR.INVALID_REQUEST end
    if not book_id then return false, Constants.ERROR.INVALID_REQUEST end

    local csrf, err = self:ensure_csrf()
    if not csrf then return false, err end

    local resp = self.http:post_form(self.base_url .. "/shelf/add_to_shelf", {
        book_id = tostring(book_id),
        name = slug,
        a = "",
        authenticity_token = csrf,
    }, { csrf = true, follow = true, detect_auth = true })
    if resp.error then return false, resp.error end
    return true, nil
end

function Client:remove_shelf(book_id)
    if not book_id then return false, Constants.ERROR.INVALID_REQUEST end
    local csrf, err = self:ensure_csrf()
    if not csrf then return false, err end

    local resp = self.http:post_form(
        self.base_url .. "/review/destroy/" .. tostring(book_id),
        { authenticity_token = csrf },
        { csrf = true, follow = true, detect_auth = true })
    if resp.error == Constants.ERROR.NOT_FOUND then
        return true, nil -- already absent
    end
    if resp.error then return false, resp.error end
    return true, nil
end

function Client:update_progress(book_id, value, unit, note)
    if not book_id then return false, Constants.ERROR.INVALID_REQUEST end
    value = tonumber(value)
    if not value then return false, Constants.ERROR.INVALID_REQUEST end
    value = math.floor(value + 0.5)
    unit = unit or "percent"
    if value < 1 then value = 1 end
    if unit ~= "pages" and value > 100 then value = 100 end

    local csrf, err = self:ensure_csrf()
    if not csrf then return false, err end

    local body = {
        ["user_status[book_id]"] = tostring(book_id),
    }
    if unit == "pages" then
        body["user_status[page]"] = tostring(value)
    else
        body["user_status[percent]"] = tostring(value)
    end
    if note and note ~= "" then
        body["user_status[body]"] = note
    end

    local resp = self.http:post_form(self.base_url .. "/user_status.json", body,
        { csrf = true, follow = true, detect_auth = true })
    if resp.error then return false, resp.error end
    return true, value
end

function Client:mark_read(book_id)
    return self:set_shelf(book_id, Constants.SHELF.READ)
end

function Client:mark_currently_reading(book_id)
    return self:set_shelf(book_id, Constants.SHELF.CURRENTLY_READING)
end

function Client:mark_want_to_read(book_id)
    return self:set_shelf(book_id, Constants.SHELF.WANT_TO_READ)
end

function Client:get_rating(book_id)
    local state, err = self:get_book_shelves(book_id)
    if not state then return nil, err end
    return state.rating
end

function Client:set_rating(book_id, rating)
    if not book_id then return false, Constants.ERROR.INVALID_REQUEST end
    local value = tonumber(rating)
    if not value or value < 1 or value > 5 then
        return false, Constants.ERROR.INVALID_REQUEST
    end
    value = math.floor(value + 0.5)

    local csrf, err = self:ensure_csrf()
    if not csrf then return false, err end

    local url = string.format(
        "%s/review/rate/%s?no_lightbox=true&queue=false&stars_click=true&rating=%d&ref=undefined",
        self.base_url, tostring(book_id), value)
    local resp = self.http:post_form(url, "", {
        csrf = true,
        follow = true,
        detect_auth = true,
    })
    if resp.error then return false, resp.error end
    return true, value
end

Client._parse_ldjson_book = parse_ldjson_book
Client.SHELF_SLUG = SHELF_SLUG

return Client
