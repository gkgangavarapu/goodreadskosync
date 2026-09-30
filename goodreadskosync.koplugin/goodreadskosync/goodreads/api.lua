--[[--
Goodreads client.

Turns the classic Goodreads web/Rails endpoints into normalized operations.
It knows nothing about authentication mechanics: it receives an already
configured `goodreads.http` object (with a session cookie) and returns the
plugin's canonical structures. UI code must never build Goodreads requests
itself.

@module koplugin.goodreads.goodreads.api
--]]

local Constants = require("goodreadskosync.constants")
local Json = require("goodreadskosync.goodreads.json")
local Logging = require("goodreadskosync.logging")
local Reading = require("goodreadskosync.reading")

local Api = {}
Api.__index = Api

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

function Api:new(http)
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

-- A CSRF token is required for every write, and Goodreads rotates it: a token
-- cached from login becomes stale and writes then fail with 404 "Page not
-- found". Reuse a freshly fetched token for a short window (so a sync run does
-- one fetch), but refresh it once it is older than CSRF_TTL.
-- (/review/list is server-rendered and not WAF-challenged, unlike "/".)
function Api:ensure_csrf()
    local now = os.time()
    local ttl = Constants.CSRF_TTL or 120
    if self.http.csrf_token and self.http.csrf_token ~= ""
        and self.http.csrf_at and (now - self.http.csrf_at) < ttl then
        return self.http.csrf_token
    end
    local resp = self.http:get(self.base_url .. "/review/list", { follow = true, detect_auth = true })
    if resp.error then return nil, resp.error end
    local csrf = resp.body and resp.body:match(
        '<meta%s+[^>]-name=["\']csrf%-token["\']%s+[^>]-content=["\']([^"\']+)["\']')
    if not csrf then return nil, Constants.ERROR.INVALID_RESPONSE end
    self.http.csrf_token = csrf
    self.http.csrf_at = now
    local user_id = resp.body:match("/user/show/(%d+)")
    if user_id then self.http.user_id = user_id end
    Logging.diag("csrf: refreshed")
    return csrf
end

function Api:get_account()
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

local function decode_entities(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("&amp;", "&"):gsub("&#39;", "'"):gsub("&apos;", "'")
        :gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&nbsp;", " "))
end

function Api:search_books(query)
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

-- Author search (public /search?search_type=authors). Derived from contributor
-- links, deduped by author id.
function Api:search_authors(query)
    if type(query) ~= "string" or query == "" then return {}, nil end
    local Http = require("goodreadskosync.goodreads.http")
    local url = self.base_url .. "/search?q=" .. Http.urlencode(query) .. "&search_type=authors"
    local resp = self.http:get(url, { follow = true, detect_auth = true })
    if resp.error then return nil, resp.error end
    local body = resp.body or ""
    local authors, seen = {}, {}
    for id, name in body:gmatch(
        'href="https://www.goodreads.com/author/show/(%d+)[^"]*".-ContributorLink__name[^>]*>([^<]+)<') do
        if not seen[id] then
            seen[id] = true
            authors[#authors + 1] = { goodreads_id = id, name = decode_entities(name) }
        end
    end
    Logging.diag("search_authors: q=", tostring(query), " n=", #authors)
    return authors, nil
end

-- Books by an author (public author page).
function Api:get_author_books(author_id)
    if not author_id then return nil, Constants.ERROR.INVALID_REQUEST end
    local url = self.base_url .. "/author/show/" .. tostring(author_id)
    local resp = self.http:get(url, { follow = true, detect_auth = true })
    if resp.error then return nil, resp.error end
    local body = resp.body or ""
    local covers = {}
    for id, src in body:gmatch('<a[^>]-href="[^"]*/book/show/(%d+)[^"]*"[^>]*>%s*<img[^>]-src="([^"]+)"') do
        if not covers[id] then covers[id] = src end
    end
    local books, seen = {}, {}
    local function add(id, title)
        if not id or seen[id] then return end
        title = decode_entities(title or "")
        if title == "" then return end
        seen[id] = true
        books[#books + 1] = { goodreads_id = id, title = title, cover_url = covers[id] }
    end
    for id, title in body:gmatch(
        'href="[^"]*/book/show/(%d+)[^"]*"[^>]-class="bookTitle"[^>]*>([^<]+)</a>') do
        add(id, title)
    end
    if #books == 0 then
        for id, title in body:gmatch(
            'class="bookTitle"[^>]-href="[^"]*/book/show/(%d+)[^"]*"[^>]*>([^<]+)</a>') do
            add(id, title)
        end
    end
    Logging.diag("author_books: id=", tostring(author_id), " n=", #books)
    return books, nil
end

local function parse_ldjson_book(html)
    if type(html) ~= "string" then return nil end
    local block = html:match('<script type="application/ld%+json">(.-)</script>')
    if not block then return nil end
    local decoded = Json.decode_any(block)
    if type(decoded) ~= "table" then return nil end
    local author, author_id
    if type(decoded.author) == "table" then
        local a = decoded.author[1] or decoded.author
        if type(a) == "table" then
            author = a.name
            if a.url then author_id = a.url:match("/author/show/(%d+)") end
        end
    end
    local rating, ratings_count, reviews_count
    if type(decoded.aggregateRating) == "table" then
        rating = tonumber(decoded.aggregateRating.ratingValue)
        ratings_count = tonumber(decoded.aggregateRating.ratingCount)
        reviews_count = tonumber(decoded.aggregateRating.reviewCount)
    end
    return {
        title = decoded.name,
        author = author,
        author_id = author_id,
        image = decoded.image,
        pages = tonumber(decoded.numberOfPages) or nil,
        rating = rating,
        ratings_count = ratings_count,
        reviews_count = reviews_count,
        description = decoded.description,
        publisher = decoded.publisher,
        published = decoded.datePublished,
        isbn = decoded.isbn,
        awards = decoded.awards,
    }
end

function Api:get_book(book_id)
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
    local reviews_count = ld.reviews_count
    if not reviews_count and resp.body then
        local n = resp.body:match("([%d,]+)%s+reviews")
        if n then reviews_count = tonumber((n:gsub(",", ""))) end
    end
    return {
        goodreads_id = book_id,
        title = ld.title or ("Goodreads #" .. book_id),
        authors = { ld.author or "Unknown Author" },
        author_id = ld.author_id,
        author = ld.author,
        pages = pages,
        cover_url = ld.image,
        rating = ld.rating,
        ratings_count = ld.ratings_count,
        reviews_count = reviews_count,
        description = ld.description,
        publisher = ld.publisher,
        published = ld.published,
        isbn = ld.isbn,
        awards = ld.awards,
        url = self.base_url .. "/book/show/" .. book_id,
    }, nil
end

-- Strip tags/entities from a review snippet into readable plain text.
local function strip_html(s)
    if type(s) ~= "string" or s == "" then return nil end
    s = s:gsub("<br%s*/?>", "\n"):gsub("<[^>]->", "")
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&#39;", "'"):gsub("&quot;", '"'):gsub("&nbsp;", " ")
        :gsub("&#(%d+);", function(d) return string.char(tonumber(d) or 32) end)
    s = s:gsub("[ \t]+", " "):gsub("\n+", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

-- Reviews live in the page's __NEXT_DATA__ Apollo state as normalized "Review:*"
-- objects: rating, text, createdAt, likeCount and a creator ref to a "User:*"
-- object holding the name. This is far more reliable than the HTML (whose
-- per-review stars are JS-filled).
local function reviews_from_next_data(body)
    if type(body) ~= "string" then return nil end
    local raw = body:match('<script id="__NEXT_DATA__" type="application/json">(.-)</script>')
    if not raw then return nil end
    local ok, data = pcall(Json.decode_any, raw)
    if not ok or type(data) ~= "table" then return nil end
    local state = data.props and data.props.pageProps and data.props.pageProps.apolloState
    if type(state) ~= "table" then return nil end
    local reviews = {}
    for _k, v in pairs(state) do
        if type(v) == "table" and v.__typename == "Review" then
            local name
            local ref = type(v.creator) == "table" and v.creator.__ref
            local user = ref and state[ref]
            if type(user) == "table" and type(user.name) == "string" then
                name = user.name
            end
            reviews[#reviews + 1] = {
                name = name,
                rating = tonumber(v.rating),
                text = strip_html(v.text),
                created_at = tonumber(v.createdAt),
                likes = tonumber(v.likeCount),
            }
        end
    end
    if #reviews == 0 then return nil end
    table.sort(reviews, function(a, b) return (a.created_at or 0) > (b.created_at or 0) end)
    return reviews
end

local function reviews_from_html(body)
    local reviews = {}
    for block in body:gmatch('<article class="ReviewCard"(.-)</article>') do
        local name = block:match('class="ReviewerProfile__name"[^>]*>.-<a[^>]*>([^<]+)</a>')
            or block:match('data%-testid="name"[^>]*>.-<a[^>]*>([^<]+)</a>')
            or block:match('data%-testid="name"[^>]*>([^<]+)<')
        local text = block:match('class="Formatted"[^>]*>(.-)</span>')
            or block:match('class="ReviewText"[^>]*>(.-)</div>')
        local rating = tonumber(block:match('aria%-label="Rating (%d) out of 5"'))
        name = strip_html(name)
        if name then
            reviews[#reviews + 1] = {
                name = name,
                rating = rating,
                text = strip_html(text),
            }
        end
    end
    return reviews
end

-- Community reviews for a book (one page).
function Api:get_reviews(book_id, page)
    if not book_id then return nil, Constants.ERROR.INVALID_REQUEST end
    page = page or 1
    -- Page 1 lives on the plain book page (the same URL get_book uses, which is
    -- not WAF-challenged); only later pages use the ?page=N form.
    local base = self.base_url .. "/book/show/" .. tostring(book_id)
    local url = (page and page > 1) and (base .. "?page=" .. page) or base
    local resp = self.http:get(url, { follow = true, detect_auth = true })
    if resp.error then
        Logging.diag("reviews: error=", tostring(resp.error), " book=", tostring(book_id))
        return nil, resp.error
    end
    local body = resp.body or ""
    local reviews = reviews_from_next_data(body) or reviews_from_html(body)
    local has_more = #reviews >= 25 or body:find("More reviews", 1, true) ~= nil
    Logging.diag("reviews: book=", tostring(book_id), " page=", page, " n=", #reviews)
    return reviews, has_more
end

-- Personalized recommendations (authenticated page). Best-effort: returns a
-- list of { goodreads_id, title, author, cover_url, avg_rating }.
function Api:get_recommendations(page)
    page = page or 1
    local url = string.format("%s/recommendations?page=%d&recs_current_view=list",
        self.base_url, page)
    local resp = self.http:get(url, { follow = true, detect_auth = true })
    if resp.error then
        Logging.diag("recs: error=", tostring(resp.error))
        return nil, resp.error
    end
    local body = resp.body or ""
    -- Cover images in document order: <a href="/book/show/ID..."><img ... src=...>
    local order, covers = {}, {}
    for id, src in body:gmatch('<a href="/book/show/(%d+)[^"]*">%s*<img[^>]-src="([^"]+)"') do
        if not covers[id] then
            covers[id] = src
            order[#order + 1] = id
        end
    end
    -- Title/author/rating live inside JS tooltip strings (escaped quotes):
    --   new Tip($('bookCover123_406235'), "\n <a class=\"bookTitle\" ...>Title<\/a> ... by <a class=\"authorName\" ...>Author<\/a> ... <span class=\"minirating\">3.95 avg ...")
    local info = {}
    local tip_pat = [[new%s*Tip%(%$%('bookCover%d+_(%d+)'%),%s*"(.-)"%)]]
    for id, raw in body:gmatch(tip_pat) do
        if not info[id] then
            local u = raw:gsub('\\"', '"'):gsub("\\/", "/"):gsub("\\n", "\n")
            info[id] = {
                title = u:match('bookTitle[^>]*>([^<]+)<'),
                author = u:match('authorName[^>]*>([^<]+)<'),
                rating = tonumber(u:match('minirating[^>]*>%s*([%d%.]+)')),
            }
        end
    end
    local books, seen = {}, {}
    local function push(id)
        if seen[id] then return end
        seen[id] = true
        local t = info[id] or {}
        books[#books + 1] = {
            goodreads_id = id,
            title = t.title and decode_entities(t.title) or nil,
            author = t.author and decode_entities(t.author) or nil,
            cover_url = covers[id],
            avg_rating = t.rating,
        }
    end
    for _i, id in ipairs(order) do push(id) end
    for id in pairs(info) do push(id) end
    local has_more = body:find(string.format("page=%d", page + 1), 1, true) ~= nil
    Logging.diag("recs: page=", page, " n=", #books, " more=", tostring(has_more))
    return books, has_more
end

function Api:get_shelves()
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
function Api:get_user_shelves()
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
function Api:get_shelf_books(shelf, page)
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
    local url = string.format("%s/review/list?%s&per_page=100&page=%d&view=table",
        self.base_url, param, page)
    local resp = self.http:get(url, { follow = true, detect_auth = true })
    if resp.error then return nil, false end
    local body = resp.body or ""
    local books, seen, with_cover = {}, {}, 0
    local function clean(s)
        return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
    end
    local function add(id, title, author, cover, rating, avg_rating, progress)
        if not id or seen[id] then return end
        seen[id] = true
        title = clean(title)
        author = clean(author)
        if cover then with_cover = with_cover + 1 end
        books[#books + 1] = {
            goodreads_id = id,
            title = title ~= "" and title or nil,
            author = author ~= "" and author or nil,
            cover_url = cover,
            rating = rating,
            avg_rating = avg_rating,
            progress = progress,
        }
    end
    -- Prefer the explicit cover element (id="cover_..."); otherwise the first
    -- real image in the row, skipping layout/asset icons.
    local function row_cover(row)
        local cover = row:match('<img[^>]-id="cover_[^"]*"[^>]-src="([^"]+)"')
            or row:match('id="cover_[^"]*"[^>]-src="([^"]+)"')
        if not cover then
            for tag in row:gmatch("<img[^>]*>") do
                local src = tag:match('src="([^"]+)"')
                if src and not src:find("/assets/", 1, true) then
                    cover = src
                    break
                end
            end
        end
        if cover then cover = cover:gsub("&amp;", "&") end
        return cover
    end
    -- New markup: <div class="stars" data-rating="4.0">. Older markup:
    -- staticStar p10..p50. 0 means unrated.
    local function row_rating(row)
        local r = tonumber(row:match('class="stars"[^>]-data%-rating="([%d%.]+)"'))
            or tonumber(row:match('data%-rating="([%d%.]+)"'))
        if not r or r <= 0 then
            local p = row:match('class="staticStar p(%d)0"')
            r = p and tonumber(p) or nil
        end
        if not r or r <= 0 then return nil end
        return math.floor(r + 0.5)
    end
    local function row_avg(row)
        return tonumber(row:match('class="field avg_rating"[^>]*>.-<div class="value">%s*([%d%.]+)'))
    end
    -- Scope to real book rows so we don't pick up recommendations/ads.
    for row in body:gmatch('<tr[^>]*class="[^"]*bookalike[^"]*review[^"]*"(.-)</tr>') do
        -- Title anchor: title before href, or href before title, relative or
        -- absolute book URL.
        local title, id = row:match('<a[^>]-title="([^"]+)"[^>]-href="[^"]*/book/show/(%d+)[^"]*"')
        if not id then
            id, title = row:match('<a[^>]-href="[^"]*/book/show/(%d+)[^"]*"[^>]-title="([^"]+)"')
        end
        if not id then
            id, title = row:match('href="[^"]*/book/show/(%d+)[^"]*"[^>]*>%s*([^<]-)%s*<')
        end
        local author = row:match('class="field author"[^>]*>.-<div class="value">%s*<a[^>]*>([^<]-)</a>')
        if not author then
            author = row:match('class="field author"[^>]*>.-<div class="value">%s*([^<]-)%s*<')
        end
        local prog = tonumber(row:match("(%d%d?%d?)%%"))
        if prog and prog > 100 then prog = nil end
        add(id, title, author, row_cover(row), row_rating(row), row_avg(row), prog)
    end
    if #books == 0 then
        for id, title in body:gmatch('href="[^"]*/book/show/(%d+)[^"]*"[^>]-title="([^"]+)"') do
            add(id, title)
        end
    end
    Logging.diag("shelf: parsed books=", #books, " with_cover=", with_cover)
    local has_more = body:find('rel="next"', 1, true) ~= nil or #books >= 100
    return books, has_more
end

-- Add/move a book to an arbitrary shelf slug.
function Api:add_to_shelf(book_id, slug)
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
function Api:get_library()
    return self:get_user_shelves()
end

function Api:get_book_shelves(book_id)
    if not book_id then return nil, Constants.ERROR.INVALID_REQUEST end
    book_id = tostring(book_id)
    local resp = self.http:get(self.base_url .. "/review/edit/" .. book_id,
        { follow = true, detect_auth = true })
    Logging.diag("shelves: get book=", book_id, " status=", tostring(resp.status),
        " url=", tostring(resp.url), " error=", tostring(resp.error))
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

function Api:set_shelf(book_id, shelf)
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
    Logging.diag("shelf: post book=", tostring(book_id), " shelf=", tostring(shelf),
        " status=", tostring(resp.status), " url=", tostring(resp.url),
        " error=", tostring(resp.error))
    if resp.error then return false, resp.error end
    return true, nil
end

function Api:remove_shelf(book_id)
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

function Api:update_progress(book_id, value, unit, note)
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
        ["user_status[body]"] = note or "",
        authenticity_token = csrf,
    }
    if unit == "pages" then
        body["user_status[page]"] = tostring(value)
    else
        body["user_status[percent]"] = tostring(value)
    end

    local function post(path)
        return self.http:post_form(self.base_url .. path, body, {
            csrf = true,
            follow = true,
            detect_auth = true,
            headers = { ["Accept"] = "application/json, text/javascript, */*; q=0.01" },
        })
    end

    local resp = post("/user_status.json")
    Logging.diag("progress: post book=", tostring(book_id), " unit=", tostring(unit),
        " value=", tostring(value), " status=", tostring(resp.status),
        " url=", tostring(resp.url), " error=", tostring(resp.error))
    if resp.error == Constants.ERROR.NOT_FOUND then
        resp = post("/user_status")
        Logging.diag("progress: fallback status=", tostring(resp.status),
            " url=", tostring(resp.url), " error=", tostring(resp.error))
    end
    if resp.error then return false, resp.error end
    return true, value
end

function Api:mark_read(book_id)
    return self:set_shelf(book_id, Constants.SHELF.READ)
end

function Api:mark_currently_reading(book_id)
    return self:set_shelf(book_id, Constants.SHELF.CURRENTLY_READING)
end

function Api:mark_want_to_read(book_id)
    return self:set_shelf(book_id, Constants.SHELF.WANT_TO_READ)
end

function Api:get_rating(book_id)
    local state, err = self:get_book_shelves(book_id)
    if not state then return nil, err end
    return state.rating
end

function Api:set_rating(book_id, rating)
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

--------------------------------------------------------------------------------
-- Reading Challenge / stats (read-mostly extras)
--------------------------------------------------------------------------------

-- Annual Reading Challenge progress. Returns
--   { goal, books_read, days_remaining, books = { {book_uri, asin, date_read} } }
function Api:get_reading_challenge()
    local resp = self.http:get(self.base_url .. "/readingchallenges/goals/data", {
        follow = true,
        detect_auth = true,
        headers = { ["Accept"] = "application/json, text/plain, */*" },
    })
    if resp.error then return nil, resp.error end
    return Reading.parseChallenge(resp.body)
end

-- The goal write is protected by an AWS WAF token that the annual page embeds
-- as a hidden input. Fetch that token, then post the new goal with it.
function Api:_reading_waf_token()
    local resp = self.http:get(self.base_url .. "/readingchallenges/annual", {
        follow = true,
        detect_auth = true,
    })
    if resp.error then return nil, resp.error end
    local token = Reading.hiddenInput(resp.body, "anti-csrftoken-a2z")
    if not token then return nil, Constants.ERROR.INVALID_RESPONSE end
    return token
end

function Api:set_reading_goal(goal)
    goal = tonumber(goal)
    if not goal or goal < 1 or goal > 100000 or goal ~= math.floor(goal) then
        return false, Constants.ERROR.INVALID_REQUEST
    end
    local token, err = self:_reading_waf_token()
    if not token then return false, err end

    local resp = self.http:request("POST",
        self.base_url .. "/readingchallenges/updateGoal?newGoal=" .. tostring(goal),
        {
            follow = true,
            detect_auth = true,
            headers = {
                ["anti-csrftoken-a2z"] = token,
                ["X-Requested-With"] = "XMLHttpRequest",
                ["Referer"] = self.base_url .. "/readingchallenges/annual",
            },
        })
    if resp.error then return false, resp.error end
    return true, goal
end

-- Per-year book counts from the reading-stats page.
-- Returns { { year = 2026, books = 10 }, ... }.
function Api:get_reading_stats(user_id)
    user_id = user_id or self.http.user_id
    if not user_id then
        local _, err = self:ensure_csrf()
        if err then return nil, err end
        user_id = self.http.user_id
    end
    if not user_id then return nil, Constants.ERROR.AUTH_REQUIRED end

    local resp = self.http:get(
        self.base_url .. "/review/stats/" .. tostring(user_id), {
            follow = true,
            detect_auth = true,
        })
    if resp.error then return nil, resp.error end
    return Reading.parseStats(resp.body)
end

Api._parse_ldjson_book = parse_ldjson_book
Api.SHELF_SLUG = SHELF_SLUG

return Api
