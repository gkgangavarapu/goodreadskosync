--[[--
Native (browser-free) Goodreads UI.

A cover-first, Kindle-app-style Goodreads experience built purely from KOReader
widgets — no HTML engine, no NetSurf, no CRE. It reads shelves through the same
provider used by sync (`get_library` / `get_shelf_books` / `get_book` /
`get_book_shelves`) and writes through the existing local-first queue.

Design notes (all KOReader e-readers, not just Kindle):
  * Every dimension is DPI-scaled or derived from the current screen size, so it
    adapts to phones, 6"/7"/10" readers, and landscape.
  * Covers keep their aspect ratio (pre-scaled BlitBuffers, bounded cache).
  * Named UI fonts are used, so the user's font settings are honored.
  * Colors are the standard palette; KOReader's night mode inverts them.
  * Touch (tap/hold) plus a hardware/`Back` key are handled.

@module koplugin.goodreads.ui.native
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local RenderImage = require("ui/renderimage")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")

local Constants = require("goodreadskosync.constants")
local Covers = require("goodreadskosync.covers")
local Logging = require("goodreadskosync.logging")
local Queue = require("goodreadskosync.sync.queue")
local Widgets = require("goodreadskosync.ui.widgets")
local _ = require("gettext")

local Native = {}

local function sp(n) return Screen:scaleBySize(n) end
local COLOR_MUTED = Blitbuffer.COLOR_DARK_GRAY
local COLOR_LINE = Blitbuffer.COLOR_LIGHT_GRAY

local SHELF_LABEL = {
    ["to-read"] = _("Want to Read"),
    ["currently-reading"] = _("Currently Reading"),
    ["read"] = _("Read"),
    ["did-not-finish"] = _("Did Not Finish"),
}

local CANONICAL = {
    { slug = "to-read", shelf = Constants.SHELF.WANT_TO_READ },
    { slug = "currently-reading", shelf = Constants.SHELF.CURRENTLY_READING },
    { slug = "read", shelf = Constants.SHELF.READ },
}

local FALLBACK_SHELVES = {
    { slug = "currently-reading", name = _("Currently Reading"), custom = false },
    { slug = "to-read", name = _("Want to Read"), custom = false },
    { slug = "read", name = _("Read"), custom = false },
    { slug = "did-not-finish", name = _("Did Not Finish"), custom = false },
}

local function shelfLabel(shelf)
    if not shelf then return "" end
    return SHELF_LABEL[shelf.slug] or shelf.name or shelf.slug or ""
end

local function stars(n)
    n = math.max(0, math.min(5, math.floor(tonumber(n) or 0)))
    return string.rep("\226\152\133", n) .. string.rep("\226\152\134", 5 - n)
end

-- Strip HTML tags/entities from a description so it renders as plain text.
local function plain_text(s)
    if type(s) ~= "string" or s == "" then return nil end
    s = s:gsub("<[^>]->", " ")
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&#39;", "'"):gsub("&quot;", '"'):gsub("&nbsp;", " ")
        :gsub("&#(%d+);", function(d) return string.char(tonumber(d) or 32) end)
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

local function truncate(s, n)
    if type(s) ~= "string" then return s end
    if #s <= n then return s end
    return s:sub(1, n - 1):gsub("%s+%S*$", "") .. "\226\128\166"
end

local function hline()
    return LineWidget:new{
        background = COLOR_LINE,
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:scaleBySize(1) },
    }
end

--------------------------------------------------------------------------------
-- Cover thumbnails (aspect preserved, bounded BlitBuffer cache)
--------------------------------------------------------------------------------

local cover_cache, cover_order = {}, {}

local function coverWidget(file, box_w, box_h)
    if not file or not Covers.exists(file) then return nil end
    local entry = cover_cache[file]
    if not entry then
        local ok, bb = pcall(function() return RenderImage:renderImageFile(file, false) end)
        if not ok or not bb then return nil end
        local w, h = bb:getWidth(), bb:getHeight()
        if not w or not h or w <= 0 or h <= 0 then return nil end
        local scale = math.min(box_w / w, box_h / h)
        local tw = math.max(1, math.floor(w * scale))
        local th = math.max(1, math.floor(h * scale))
        if tw ~= w or th ~= h then
            -- Free the full-size buffer once we have the thumbnail.
            local scaled = RenderImage:scaleBlitBuffer(bb, tw, th, true)
            if scaled then bb = scaled end
        end
        entry = { bb = bb, w = tw, h = th }
        cover_cache[file] = entry
        cover_order[#cover_order + 1] = file
        -- Drop the oldest reference beyond a bounded window (the BlitBuffer is
        -- reclaimed by its own GC once no widget references it).
        if #cover_order > 80 then
            local old = table.remove(cover_order, 1)
            cover_cache[old] = nil
        end
    end
    return ImageWidget:new{
        image = entry.bb,
        width = entry.w,
        height = entry.h,
        image_disposable = false,
        alpha = false,
    }
end

--------------------------------------------------------------------------------
-- Data loading (runs inside a background task; must not touch widgets)
--------------------------------------------------------------------------------

function Native._loadShelf(plugin, shelf)
    local provider = plugin:getProvider()
    if not provider or not provider.get_shelf_books then return nil end
    local books = provider:get_shelf_books(shelf, 1)
    if type(books) ~= "table" then return nil end
    -- Covers are downloaded lazily, per visible page, by the UI (see
    -- _loadCoverPage), so a long shelf never stalls here.
    Logging.diag("native: load shelf=", shelfLabel(shelf), " books=", #books)
    return books
end

-- Download the given missing covers in the background; returns id -> path.
function Native._fetchCovers(items)
    local out = {}
    for _i, it in ipairs(items or {}) do
        if it and it.url then
            local f = Covers.fetch(it.url)
            if f then out[it.id] = f end
        end
    end
    pcall(Covers.prune, 250)
    return out
end

function Native._loadBook(plugin, book)
    local provider = plugin:getProvider()
    if not provider then return nil end
    local info = select(1, provider:get_book(book.goodreads_id)) or {}
    info.goodreads_id = info.goodreads_id or book.goodreads_id
    info.title = info.title or book.title
    info.author = book.author
        or (type(info.authors) == "table" and info.authors[1])
        or info.author
    info.rating = info.rating or book.avg_rating
    if provider.get_book_shelves then
        local meta = select(1, provider:get_book_shelves(book.goodreads_id))
        if type(meta) == "table" then
            info.slug = meta.slug
            info.my_shelf = meta.shelf
            info.my_rating = meta.rating
        end
    end
    if provider.get_reviews then
        local rev = select(1, provider:get_reviews(book.goodreads_id, 1))
        if type(rev) == "table" then info.reviews = rev end
    end
    info.description = plain_text(info.description)
    if info.cover_url then
        info.cover_file = Covers.fetch(info.cover_url)
    end
    return info
end

function Native._loadRecommendations(plugin, page)
    local provider = plugin:getProvider()
    if not provider or not provider.get_recommendations then return nil end
    local books, has_more = provider:get_recommendations(page or 1)
    if type(books) ~= "table" then return nil end
    for i = 1, math.min(#books, 30) do
        local b = books[i]
        if b.cover_url then b.cover_file = Covers.cached(b.cover_url) end
    end
    return books, has_more
end

-- Recommendations are saved locally so opening the tab never hits the network;
-- a fetch happens only on the first run or an explicit Refresh.
function Native._recsCache()
    local ok, Storage = pcall(require, "goodreadskosync.storage")
    if not ok or not Storage then return nil end
    return Storage.open("recs_cache"):get("current", nil)
end

function Native._saveRecs(data)
    local ok, Storage = pcall(require, "goodreadskosync.storage")
    if not ok or not Storage then return end
    local s = Storage.open("recs_cache")
    s:set("current", data)
    s:flush()
end

function Native._search(plugin, query)
    local provider = plugin:getProvider()
    if not provider or not provider.search_books then return nil end
    local results = select(1, provider:search_books(query))
    if type(results) ~= "table" then return nil end
    for i = 1, math.min(#results, 10) do
        local b = results[i]
        if (not b.author) and type(b.authors) == "table" then b.author = b.authors[1] end
        if b.cover_url then b.cover_file = Covers.fetch(b.cover_url) end
    end
    Logging.diag("native: search q=", tostring(query), " results=", #results)
    return results
end

function Native._searchAuthors(plugin, query)
    local provider = plugin:getProvider()
    if not provider or not provider.search_authors then return nil end
    local authors = select(1, provider:search_authors(query))
    return type(authors) == "table" and authors or nil
end

function Native._loadAuthorBooks(plugin, author_id)
    local provider = plugin:getProvider()
    if not provider or not provider.get_author_books then return nil end
    local books = select(1, provider:get_author_books(author_id))
    if type(books) ~= "table" then return nil end
    for i = 1, math.min(#books, 30) do
        local b = books[i]
        if b.cover_url then b.cover_file = Covers.cached(b.cover_url) end
    end
    return books
end

function Native._loadReviews(plugin, book_id, page)
    local provider = plugin:getProvider()
    if not provider or not provider.get_reviews then return nil end
    local reviews, has_more = provider:get_reviews(book_id, page)
    if type(reviews) ~= "table" then
        Logging.diag("native: reviews provider nil book=", tostring(book_id))
        return nil
    end
    return { reviews = reviews, has_more = has_more and true or false }
end

--------------------------------------------------------------------------------
-- Tappable cover row
--------------------------------------------------------------------------------

local Row = InputContainer:extend{
    book = nil,
    on_tap = nil,
    on_hold = nil,
    row_width = nil,
    cover_w = nil,
    cover_h = nil,
    status = nil, -- optional muted [SHELF / STATUS] line (spec §17)
}

function Row:init()
    local book = self.book or {}
    local pad = sp(12)
    local cover = coverWidget(book.cover_file, self.cover_w, self.cover_h)
    if not cover then
        local placeholder = CenterContainer:new{
            dimen = Geom:new{ w = self.cover_w, h = self.cover_h },
        }
        placeholder[1] = TextWidget:new{
            text = _("No cover"),
            face = Font:getFace("x_smallinfofont"),
            fgcolor = COLOR_MUTED,
        }
        cover = placeholder
    end
    local cover_frame = FrameContainer:new{
        bordersize = sp(1),
        color = COLOR_LINE,
        padding = 0,
        margin = 0,
    }
    cover_frame[1] = cover

    local text_w = self.row_width - self.cover_w - 4 * pad - 2 * sp(1)
    local lines = VerticalGroup:new{ align = "left" }
    -- No fixed height: the title sizes to its content, so there's no large gap
    -- before the author. Truncated so an extreme title can't grow too tall.
    lines[#lines + 1] = TextBoxWidget:new{
        text = truncate(book.title or _("Untitled"), 90),
        face = Font:getFace("cfont"),
        bold = true,
        width = text_w,
    }
    lines[#lines + 1] = VerticalSpan:new{ width = sp(4) }
    if book.author and book.author ~= "" then
        lines[#lines + 1] = TextWidget:new{
            text = book.author,
            face = Font:getFace("infofont"),
            fgcolor = COLOR_MUTED,
            max_width = text_w,
        }
    end
    -- Show the GOODREADS rating (average) on rows. Our own rating only appears
    -- where it is the subject (the book page's rating control).
    local gr = book.avg_rating
    if gr and gr > 0 then
        lines[#lines + 1] = VerticalSpan:new{ width = sp(6) }
        lines[#lines + 1] = TextWidget:new{
            text = string.format("%s  %.2f", stars(math.floor(gr + 0.5)), gr),
            face = Font:getFace("infofont"),
            max_width = text_w,
        }
    elseif book.rating and book.rating > 0 then
        lines[#lines + 1] = VerticalSpan:new{ width = sp(6) }
        lines[#lines + 1] = TextWidget:new{
            text = stars(book.rating),
            face = Font:getFace("infofont"),
            max_width = text_w,
        }
    end
    if self.status and self.status ~= "" then
        lines[#lines + 1] = VerticalSpan:new{ width = sp(5) }
        lines[#lines + 1] = TextWidget:new{
            text = self.status,
            face = Font:getFace("x_smallinfofont"),
            fgcolor = COLOR_MUTED,
            max_width = text_w,
        }
    end
    -- Cover on the left; text (title/author/rating/shelf) top-aligned to the
    -- cover top and sized to its content.
    local hgroup = HorizontalGroup:new{ align = "top" }
    hgroup[1] = cover_frame
    hgroup[2] = HorizontalSpan:new{ width = pad }
    hgroup[3] = lines
    self[1] = FrameContainer:new{
        padding = pad,
        margin = 0,
        bordersize = sp(1),
        color = COLOR_LINE,
        background = Blitbuffer.COLOR_WHITE,
    }
    self[1][1] = hgroup
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        Hold = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
    self.dimen = self[1]:getSize()
end

function Row:onTap()
    if self.on_tap then self.on_tap() end
    return true
end

function Row:onHold()
    if self.on_hold then self.on_hold() end
    return true
end

--------------------------------------------------------------------------------
-- Generic tappable row (for lists/menus, consistent with BookRow styling)
--------------------------------------------------------------------------------

local TapRow = InputContainer:extend{
    child = nil,
    on_tap = nil,
}

function TapRow:init()
    self[1] = self.child
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    self.dimen = self[1]:getSize()
end

function TapRow:onTap()
    if self.on_tap then self.on_tap() end
    return true
end

--------------------------------------------------------------------------------
-- Main screen (single widget, internal navigation stack)
--------------------------------------------------------------------------------

local MainScreen = InputContainer:extend{
    plugin = nil,
    shelves = nil,
    active = nil,
}

function MainScreen:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ w = screen_w, h = screen_h }
    self.stack = {}
    self.shelves = self.shelves or {}
    self._token = 0
    self._alive = true
    self.ges_events = {}
    self.key_events = {
        Back = { { "Back" } },
    }
end

function MainScreen:onClose()
    self._alive = false
    if self.plugin then self.plugin._native_screen = nil end
    UIManager:close(self)
end

function MainScreen:onBack()
    self:back()
end

-- Recompute on rotation so the layout stays correct on every device.
function MainScreen:onSetRotationMode()
    if not self._alive then return end
    self:_render()
end

function MainScreen:_margins()
    return sp(12)
end

function MainScreen:_topShelves(n)
    local list = {}
    for _, s in ipairs(self.shelves or {}) do list[#list + 1] = s end
    local rank = { ["currently-reading"] = 1, ["to-read"] = 2, ["read"] = 3, ["did-not-finish"] = 4 }
    table.sort(list, function(a, b)
        return (rank[a.slug] or 50) < (rank[b.slug] or 50)
    end)
    local out = {}
    for i = 1, math.min(n, #list) do out[#out + 1] = list[i] end
    return out
end

-- In-app, styled shelf picker (no default dialog), consistent with the list UI.
function MainScreen:_shelfChooser()
    local items = {
        {
            text = _("Refresh shelves"),
            callback = function() self:_refreshShelves() end,
        },
    }
    for _, s in ipairs(self.shelves or {}) do
        local label = shelfLabel(s)
        if s.count then label = string.format("%s (%d)", label, s.count) end
        items[#items + 1] = {
            text = label,
            checked_func = function()
                return self.active and self.active.slug == s.slug
            end,
            callback = function() self:openShelf(s) end,
        }
    end
    self:pushList(_("Shelves"), items)
end

-- Refresh ONLY the shelf currently on screen.
function MainScreen:_refreshCurrentShelf()
    local v = self.stack[1]
    if not v or not v.shelf then return end
    if v.kind ~= "shelf" and v.kind ~= "reading" then return end
    v.loading = true
    v.error = nil
    v.from_cache = false
    self:_render()
    self:_fetchShelf(v.shelf)
end

function MainScreen:_shelfBySlug(slug)
    for _i, s in ipairs(self.shelves or {}) do
        if s.slug == slug then return s end
    end
    return nil
end

-- Single "Actions…" affordance per book (cleaner on e-ink than 3 buttons).
function MainScreen:_rowActions(book)
    local margin = self:_margins()
    local btn = Button:new{
        text = _("Actions…"),
        width = Screen:getWidth() - 2 * margin,
        bordersize = sp(1),
        text_font_face = "smallinfofont",
        callback = function() self:_bookActions(book) end,
    }
    local frame = FrameContainer:new{
        width = Screen:getWidth(),
        padding = sp(4),
        margin = 0,
        bordersize = 0,
    }
    frame[1] = btn
    return frame
end

-- Global shelf actions (Want to Read / Currently Reading / Read).
function MainScreen:_shelfButtons(book, current_slug)
    local margin = self:_margins()
    local total = Screen:getWidth() - 2 * margin
    local gap = sp(6)
    local bw = math.floor((total - 2 * gap) / 3)
    local row = HorizontalGroup:new{ align = "center" }
    for _i, c in ipairs(CANONICAL) do
        local on = (current_slug == c.slug)
        row[#row + 1] = Button:new{
            text = SHELF_LABEL[c.slug] or c.slug,
            width = bw,
            margin = gap / 2,
            bordersize = on and sp(2) or sp(1),
            background = on and COLOR_LINE or nil,
            text_font_face = "smallinfofont",
            text_font_bold = on,
            callback = function()
                self:_enqueueShelf(book, c.slug)
                book.slug = c.slug
                self:_render()
            end,
        }
    end
    return row
end

function MainScreen:_bookActions(book)
    if not book or not book.goodreads_id then return end
    local items = {
        { text = _("Update progress…"), callback = function()
            self:back()
            self:_setProgress(book)
        end },
        { text = _("Shelf"), callback = function()
            self:_showShelfDialog(book, book.slug)
        end },
        { text = _("Rate…"), callback = function()
            self:_rateBook(book)
        end },
        { text = _("Details"), callback = function()
            self:back()
            self:openBook(book)
        end },
    }
    self:pushList(book.title or _("Book"), items)
end

function MainScreen:_openReading(shelf)
    shelf = shelf or self:_shelfBySlug("currently-reading")
    if not shelf then
        return self:_switchSection("shelf")
    end
    self.active = shelf
    local cached = shelf.books
    if type(cached) ~= "table" or #cached == 0 then cached = nil end
    self.stack = { {
        kind = "reading",
        shelf = shelf,
        books = cached,
        loading = not cached,
        page = 1,
        show_actions = true,
        from_cache = cached ~= nil,
    } }
    self:_render()
    if not cached then self:_fetchShelf(shelf) end
end

-- "Showing cached data" line (spec §21 / offline-first).
function MainScreen:_cachedLine(view)
    local ts = view.shelf and view.shelf.books_at
    local text = _("Showing saved data")
    if ts then
        text = text .. "  \194\183  " .. string.format(_("last updated %s"), os.date("%Y-%m-%d %H:%M", ts))
    end
    local frame = FrameContainer:new{
        width = Screen:getWidth(),
        padding = sp(4),
        margin = 0,
        bordersize = 0,
    }
    frame[1] = TextWidget:new{
        text = text,
        face = Font:getFace("x_smallinfofont"),
        fgcolor = COLOR_MUTED,
    }
    return frame
end

function MainScreen:_titlebar(title, subtitle)
    local opts = {
        width = Screen:getWidth(),
        title = title,
        subtitle = subtitle,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
    }
    if #self.stack > 1 then
        opts.left_icon = "chevron.left"
        opts.left_icon_tap_callback = function() self:back() end
    end
    return TitleBar:new(opts)
end

-- Spec §6: persistent horizontal section tabs.
function MainScreen:_sectionTabs()
    local active = self.stack[1] and self.stack[1].kind or "shelf"
    -- PARKED: Recommendations tab is hidden until its parsing is robust; the
    -- code path (_openRecs/_fetchRecommendations/get_recommendations) is kept
    -- in place for a later pass.
    local sections = {
        { id = "shelf", label = _("Home") },
        { id = "search", label = _("Search") },
        { id = "menu", label = _("Menu") },
    }
    local total = Screen:getWidth() - 2 * self:_margins()
    local gap = sp(6)
    local bw = math.floor(total / #sections) - gap
    local row = HorizontalGroup:new{ align = "center" }
    for _, sec in ipairs(sections) do
        local on = (active == sec.id)
        row[#row + 1] = Button:new{
            text = sec.label,
            width = bw,
            margin = gap / 2,
            bordersize = on and sp(2) or 0,
            background = on and COLOR_LINE or nil,
            text_font_face = "smallinfofont",
            text_font_bold = on,
            callback = function() self:_switchSection(sec.id) end,
        }
    end
    local frame = FrameContainer:new{
        width = Screen:getWidth(),
        padding = sp(4),
        margin = 0,
        bordersize = 0,
    }
    frame[1] = row
    return frame
end

local SHELF_SHORT = {
    ["to-read"] = _("To Read"),
    ["currently-reading"] = _("Reading"),
    ["read"] = _("Read"),
    ["did-not-finish"] = _("DNF"),
}

-- Main-screen action row: Refresh shelves + Support (both always visible).
function MainScreen:_actionBar()
    local margin = self:_margins()
    local total = Screen:getWidth() - 2 * margin
    local gap = sp(8)
    local bw = math.floor((total - gap) / 2)
    local row = HorizontalGroup:new{ align = "center" }
    row[#row + 1] = Button:new{
        text = _("\226\134\187  Refresh shelf"),
        width = bw,
        bordersize = sp(1),
        text_font_face = "smallinfofont",
        callback = function() self:_refreshCurrentShelf() end,
    }
    row[#row + 1] = HorizontalSpan:new{ width = gap }
    row[#row + 1] = Button:new{
        text = _("\226\153\165  Support"),
        width = bw,
        bordersize = sp(1),
        text_font_face = "smallinfofont",
        callback = function()
            -- Defer so the tap that pressed this button isn't also delivered to
            -- the dialog (which would close it immediately).
            UIManager:scheduleIn(0.15, function()
                local ok, Support = pcall(require, "goodreadskosync.ui.support")
                if ok and Support and Support.show then
                    Support.show()
                else
                    Logging.error("native: support dialog unavailable")
                end
            end)
        end,
    }
    local frame = FrameContainer:new{
        width = Screen:getWidth(),
        padding = sp(4),
        margin = 0,
        bordersize = 0,
    }
    frame[1] = row
    return frame
end

-- Spec §8: quick segmented shelf switcher (canonical shelves) + ▾ for all.
function MainScreen:_shelfBar()
    -- Quick tabs: only the primary shelves; every other shelf (custom, DNF)
    -- lives under "All".
    local tabs = { "to-read", "currently-reading", "read" }
    local canonical = {}
    for _i, slug in ipairs(tabs) do
        for _j, s in ipairs(self.shelves or {}) do
            if s.slug == slug then canonical[#canonical + 1] = s end
        end
    end
    if #canonical == 0 then
        canonical = {
            { slug = "to-read" },
            { slug = "currently-reading" },
            { slug = "read" },
        }
    end
    local total = Screen:getWidth() - 2 * self:_margins()
    local n = #canonical + 1
    local gap = sp(4)
    local bw = math.floor(total / n) - gap
    local row = HorizontalGroup:new{ align = "center" }
    for _i, s in ipairs(canonical) do
        local on = self.active and self.active.slug == s.slug
        row[#row + 1] = Button:new{
            text = SHELF_SHORT[s.slug] or shelfLabel(s) or s.slug,
            width = bw,
            margin = gap / 2,
            bordersize = on and sp(2) or sp(1),
            background = on and COLOR_LINE or nil,
            text_font_face = "smallinfofont",
            text_font_bold = on,
            callback = function()
                if s.slug == "currently-reading" then
                    self:_openReading(s)
                else
                    self:openShelf(s)
                end
            end,
        }
    end
    row[#row + 1] = Button:new{
        text = _("All \226\150\190"),
        width = bw,
        margin = gap / 2,
        bordersize = sp(1),
        text_font_face = "smallinfofont",
        callback = function() self:_shelfChooser() end,
    }
    local frame = FrameContainer:new{
        width = Screen:getWidth(),
        padding = sp(4),
        margin = 0,
        bordersize = 0,
    }
    frame[1] = row
    return frame
end

function MainScreen:_switchSection(id)
    local top = self.stack[1]
    if top and top.kind == id then return end
    Logging.diag("native: switch section=", tostring(id))
    if id == "search" then
        self.stack = { { kind = "search" } }
        self:_render()
    elseif id == "recs" then
        self:_openRecs()
    elseif id == "menu" then
        self.stack = { { kind = "menu" } }
        self:_render()
    elseif id == "shelf" then
        local s = self.active or self:_topShelves(1)[1] or FALLBACK_SHELVES[1]
        self.stack = {}
        self:openShelf(s)
    end
end

function MainScreen:_centered(text, body_h)
    local center = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = body_h },
    }
    center[1] = TextWidget:new{ text = text, face = Font:getFace("infofont"), fgcolor = COLOR_MUTED }
    return center
end

function MainScreen:_recsBody(view, body_h)
    if view.loading then return self:_centered(_("Loading…"), body_h) end
    if view.error then return self:_centered(view.error, body_h) end
    if #(view.books or {}) == 0 then
        return self:_centered(_("No recommendations."), body_h)
    end
    local margin = self:_margins()
    local btn = Button:new{
        text = _("\226\134\187  Refresh"),
        width = Screen:getWidth() - 2 * margin,
        bordersize = sp(1),
        text_font_face = "smallinfofont",
        callback = function() self:_fetchRecommendations(view.page or 1) end,
    }
    local frame = FrameContainer:new{
        width = Screen:getWidth(), padding = sp(4), margin = 0, bordersize = 0,
    }
    frame[1] = btn
    local col = VerticalGroup:new{ align = "center" }
    col[1] = frame
    col[2] = self:_bookList(view, body_h - frame:getSize().h)
    return col
end

-- Paginate so a long shelf never renders (and decodes covers for) everything
-- at once; keeps e-ink devices responsive.
local BOOKS_PER_PAGE = 25

function MainScreen:_bookList(view, body_h)
    local books = view.books or {}
    local screen_w = Screen:getWidth()
    -- Previous (larger) cover size.
    local cover_w = math.min(sp(84), math.floor(screen_w * 0.16))
    local cover_h = math.floor(cover_w * 1.5)
    local row_w = screen_w - 2 * self:_margins()
    local total = #books
    local pages = math.max(1, math.ceil(total / BOOKS_PER_PAGE))
    local page = math.min(math.max(view.page or 1, 1), pages)
    view.page = page
    local first = (page - 1) * BOOKS_PER_PAGE + 1
    local last = math.min(page * BOOKS_PER_PAGE, total)

    local content = VerticalGroup:new{ align = "center" }
    local missing = {}
    content[#content + 1] = VerticalSpan:new{ width = sp(6) }
    for i = first, last do
        local b = books[i]
        -- Drop stale cache paths (file removed) and re-resolve from disk.
        if b.cover_file and not Covers.exists(b.cover_file) then b.cover_file = nil end
        if (not b.cover_file) and b.cover_url then
            b.cover_file = Covers.cached(b.cover_url)
        end
        if (not b.cover_file) and b.cover_url then
            missing[#missing + 1] = { id = b.goodreads_id, url = b.cover_url }
        end
        local status_text
        if view.kind == "reading" then
            status_text = (b.progress and string.format(_("%d%% read"), b.progress))
                or _("In progress")
        else
            status_text = shelfLabel(view.shelf)
        end
        content[#content + 1] = Row:new{
            book = b,
            row_width = row_w,
            cover_w = cover_w,
            cover_h = cover_h,
            status = status_text,
            on_tap = function() self:openBook(b) end,
            on_hold = function() self:_showShelfDialog(b) end,
        }
        if view.show_actions then
            content[#content + 1] = self:_rowActions(b)
        end
        if i < last then
            content[#content + 1] = VerticalSpan:new{ width = sp(6) }
        end
    end

    -- Lazily fetch this page's missing covers in the background, once per page.
    if #missing > 0 then
        view._covers_requested = view._covers_requested or {}
        if not view._covers_requested[page] then
            view._covers_requested[page] = true
            self:_loadCoverPage(view, missing)
        end
    end

    if pages > 1 then
        content[#content + 1] = LineWidget:new{
            background = COLOR_LINE,
            dimen = Geom:new{ w = screen_w, h = sp(1) },
        }
        local pager = HorizontalGroup:new{ align = "center" }
        local bw = math.floor((screen_w - 2 * self:_margins()) / 3)
        pager[#pager + 1] = Button:new{
            text = _("◀ Prev"),
            width = bw,
            bordersize = sp(1),
            enabled = page > 1,
            callback = function() view.page = page - 1; self:_render() end,
        }
        pager[#pager + 1] = TextWidget:new{
            text = string.format("  %d / %d  ", page, pages),
            face = Font:getFace("smallinfofont"),
            fgcolor = COLOR_MUTED,
        }
        pager[#pager + 1] = Button:new{
            text = _("Next ▶"),
            width = bw,
            bordersize = sp(1),
            enabled = page < pages,
            callback = function() view.page = page + 1; self:_render() end,
        }
        local pager_frame = FrameContainer:new{
            width = screen_w, padding = sp(8), margin = 0, bordersize = 0,
        }
        pager_frame[1] = pager
        content[#content + 1] = pager_frame
    end

    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = screen_w, h = body_h },
        show_parent = self,
    }
    scroll[1] = content
    return scroll
end

-- Background-download the covers missing from the current page, then repaint.
function MainScreen:_loadCoverPage(view, missing)
    local plugin = self.plugin
    Logging.diag("native: covers requested=", #missing)
    self._cover_token = (self._cover_token or 0) + 1
    local token = self._cover_token
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, map = plugin:runInBackground(_("Loading covers…"), function()
                return Native._fetchCovers(missing)
            end)
            if not self._alive or token ~= self._cover_token then return end
            if completed == false then return end
            local v = self.stack[1]
            if not v or v.kind ~= "shelf" then return end
            local got = 0
            if type(map) == "table" then
                for _i, b in ipairs(view.books or {}) do
                    if (not b.cover_file) and map[b.goodreads_id] then
                        b.cover_file = map[b.goodreads_id]
                        got = got + 1
                    end
                end
            end
            Logging.diag("native: covers resolved=", got)
            self:_render()
        end)
    end)
end

function MainScreen:_bodyFor(view, body_h)
    if view.kind == "shelf" then
        if view.loading then return self:_centered(_("Loading…"), body_h) end
        if view.error then return self:_centered(view.error, body_h) end
        local books = view.books or {}
        if #books == 0 then return self:_centered(_("No books on this shelf."), body_h) end
        return self:_bookList(view, body_h)
    end
    if view.kind == "search" then
        return self:_searchBody(view, body_h)
    end
    if view.kind == "reviews" then
        return self:_reviewsBody(view, body_h)
    end
    if view.kind == "recs" then
        return self:_recsBody(view, body_h)
    end
    if view.kind == "reading" then
        if view.loading then return self:_centered(_("Loading…"), body_h) end
        if view.error then return self:_centered(view.error, body_h) end
        if #(view.books or {}) == 0 then
            return self:_centered(_("Nothing currently reading."), body_h)
        end
        return self:_bookList(view, body_h)
    end
    if view.kind == "author" then
        if view.loading then return self:_centered(_("Loading…"), body_h) end
        if view.error then return self:_centered(view.error, body_h) end
        if #(view.books or {}) == 0 then
            return self:_centered(_("No books found."), body_h)
        end
        return self:_bookList(view, body_h)
    end
    if view.kind == "list" then
        return self:_listItemsBody(view, body_h)
    end
    if view.kind == "menu" then
        return self:_listItemsBody({ items = self:_buildPluginMenu() }, body_h)
    end
    -- book detail
    if view.loading then return self:_centered(_("Loading…"), body_h) end
    return self:_bookDetail(view, body_h)
end

-- Consistent, in-app list used for shelf pickers and the plugin menu.
function MainScreen:_listItemsBody(view, body_h)
    local screen_w = Screen:getWidth()
    local margin = self:_margins()
    local items = view.items or {}
    if #items == 0 then return self:_centered(_("Nothing here."), body_h) end
    local content = VerticalGroup:new{ align = "center" }
    for i, it in ipairs(items) do
        local checked = it.checked_func and it.checked_func()
        local disabled = it.disabled
        local lines = VerticalGroup:new{ align = "left" }
        local label = it.text or ""
        if checked then label = label .. "   \226\156\147" end
        lines[#lines + 1] = TextWidget:new{
            text = label,
            face = Font:getFace("infofont"),
            bold = checked or it.bold,
            fgcolor = disabled and COLOR_LINE or nil,
            max_width = screen_w - 2 * margin,
        }
        if it.mandatory then
            lines[#lines + 1] = TextWidget:new{
                text = it.mandatory,
                face = Font:getFace("smallinfofont"),
                fgcolor = COLOR_MUTED,
                max_width = screen_w - 2 * margin,
            }
        end
        local frame = FrameContainer:new{
            width = screen_w,
            padding = sp(14),
            margin = 0,
            bordersize = 0,
        }
        frame[1] = lines
        local entry = it
        content[#content + 1] = TapRow:new{
            child = frame,
            on_tap = function()
                if disabled then return end
                if entry.submenu then
                    self:pushList(entry.text, entry.submenu)
                elseif entry.callback then
                    entry.callback()
                end
            end,
        }
        if i < #items then
            content[#content + 1] = LineWidget:new{
                background = COLOR_LINE,
                dimen = Geom:new{ w = screen_w, h = sp(1) },
            }
        end
    end
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = screen_w, h = body_h },
        show_parent = self,
    }
    scroll[1] = content
    return scroll
end

function MainScreen:pushList(title, items)
    self.stack[#self.stack + 1] = { kind = "list", title = title, items = items }
    self:_render()
end

function MainScreen:_cacheStats()
    local size, count = 0, 0
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then
        local dir = Covers.dir()
        pcall(function()
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    local attr = lfs.attributes(dir .. "/" .. entry)
                    if attr and attr.mode == "file" then
                        size = size + (attr.size or 0)
                        count = count + 1
                    end
                end
            end
        end)
    end
    local last_text = "\226\128\148"
    local ok2, res = pcall(function() return self.plugin:cachedLibraryData() end)
    if ok2 and res and res.saved_at then
        last_text = os.date("%Y-%m-%d %H:%M", res.saved_at)
    end
    return { size = size, count = count, size_mb = size / 1048576, last_text = last_text }
end

function MainScreen:_clearCovers()
    local n = 0
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then
        local dir = Covers.dir()
        pcall(function()
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    os.remove(dir .. "/" .. entry)
                    n = n + 1
                end
            end
        end)
    end
    cover_cache, cover_order = {}, {}
    Widgets.notify(string.format(_("%d cached covers cleared"), n))
    self:back()
    self:_render()
end

function MainScreen:_clearLibrary()
    local ok, Storage = pcall(require, "goodreadskosync.storage")
    if ok and Storage then
        pcall(function()
            local s = Storage.open("library_cache")
            s:set("data", nil)
            s:flush()
        end)
    end
    if self.plugin then self.plugin._library_cache = nil end
    Widgets.notify(_("Cached library cleared"))
    self:back()
    self:_render()
end

function MainScreen:_cacheMenu()
    local stats = self:_cacheStats()
    local items = {
        { text = _("Refresh shelf list"), callback = function()
            self:back()
            self:_refreshShelves()
        end },
        { text = _("Clear cached covers"), callback = function() self:_clearCovers() end },
        { text = _("Clear cached library"), callback = function() self:_clearLibrary() end },
        { text = string.format(_("Covers: %d files, %.1f MB"), stats.count, stats.size_mb), disabled = true },
        { text = string.format(_("Last refresh: %s"), stats.last_text), disabled = true },
    }
    self:pushList(_("Goodreads Cache"), items)
end

-- Fold the plugin's existing menu tree into the full-screen UI, recursively.
-- (Loop vars are `_i` so the gettext `_` is never shadowed.)
local function normalize_menu(items)
    local out = {}
    for _i, it in ipairs(items or {}) do
        local sub = it.sub_item_table
        if not sub and it.sub_item_table_func then
            local ok, s = pcall(it.sub_item_table_func)
            if ok then sub = s end
        end
        local label = it.text
        if not label and it.text_func then
            local ok, t = pcall(it.text_func)
            if ok then label = t end
        end
        local entry = {
            text = label,
            callback = it.callback,
            checked_func = it.checked_func,
        }
        if it.enabled_func then
            local ok, en = pcall(it.enabled_func)
            entry.disabled = not (ok and en)
        end
        if type(sub) == "table" and #sub > 0 then
            entry.submenu = normalize_menu(sub)
        end
        out[#out + 1] = entry
    end
    return out
end

function MainScreen:_buildPluginMenu()
    local ok, menu = pcall(function() return self.plugin:buildMenu() end)
    if not ok or type(menu) ~= "table" then return {} end
    local items = normalize_menu(menu)
    -- Drop the entry that opens this very screen.
    local out = {
        { text = _("Refresh shelf list"), callback = function() self:_refreshShelves() end },
        { text = _("Cache settings"), callback = function() self:_cacheMenu() end },
    }
    for _i, it in ipairs(items) do
        if it.text ~= _("My Goodreads (experimental)…") then
            out[#out + 1] = it
        end
    end
    return out
end

function MainScreen:_searchBody(view, body_h)
    local screen_w = Screen:getWidth()
    local inner_w = screen_w - 2 * self:_margins()
    local tab = view.tab or "books"
    local content = VerticalGroup:new{ align = "center" }

    -- Tabs: Books | Authors (Reader search is not exposed by Goodreads here).
    local tabs = HorizontalGroup:new{ align = "center" }
    local gap = sp(6)
    local bw = math.floor((inner_w - gap) / 2)
    local tabdefs = {
        { id = "books", label = _("Books") },
        { id = "authors", label = _("Authors") },
    }
    for _i, t in ipairs(tabdefs) do
        local on = (tab == t.id)
        tabs[#tabs + 1] = Button:new{
            text = t.label,
            width = bw,
            margin = gap / 2,
            bordersize = on and sp(2) or sp(1),
            background = on and COLOR_LINE or nil,
            text_font_face = "smallinfofont",
            text_font_bold = on,
            callback = function()
                view.tab = t.id
                view.results = nil
                view.query = nil
                self:_render()
            end,
        }
    end
    local tabs_frame = FrameContainer:new{
        width = screen_w, padding = sp(4), margin = 0, bordersize = 0,
    }
    tabs_frame[1] = tabs
    content[#content + 1] = tabs_frame

    content[#content + 1] = Button:new{
        text = (tab == "authors") and _("Search authors…") or _("Search books…"),
        width = inner_w,
        bordersize = sp(1),
        text_font_bold = true,
        callback = function() self:_searchDialog(view) end,
    }
    content[#content + 1] = VerticalSpan:new{ width = sp(12) }

    local results = view.results
    if view.searching then
        content[#content + 1] = TextWidget:new{
            text = _("Searching…"), face = Font:getFace("infofont"), fgcolor = COLOR_MUTED,
        }
    elseif results == nil then
        content[#content + 1] = TextWidget:new{
            text = (tab == "authors") and _("Find an author.") or _("Find a book to add to a shelf."),
            face = Font:getFace("infofont"), fgcolor = COLOR_MUTED,
        }
    elseif #results == 0 then
        content[#content + 1] = TextWidget:new{
            text = _("No matches."), face = Font:getFace("infofont"), fgcolor = COLOR_MUTED,
        }
    elseif tab == "authors" then
        content[#content + 1] = hline()
        for _i, a in ipairs(results) do
            local frame = FrameContainer:new{
                width = screen_w, padding = sp(14), margin = 0, bordersize = 0,
            }
            frame[1] = TextWidget:new{
                text = a.name or _("Author"),
                face = Font:getFace("infofont"),
                bold = true,
                max_width = inner_w,
            }
            content[#content + 1] = TapRow:new{
                child = frame,
                on_tap = function() self:openAuthor(a.goodreads_id, a.name) end,
            }
            content[#content + 1] = hline()
        end
    else
        local cover_w = math.min(sp(84), math.floor(screen_w * 0.16))
        local cover_h = math.floor(cover_w * 1.5)
        local row_w = screen_w - 2 * self:_margins()
        for i, r in ipairs(results) do
            content[#content + 1] = Row:new{
                book = r,
                row_width = row_w,
                cover_w = cover_w,
                cover_h = cover_h,
                on_tap = function() self:openBook(r) end,
                on_hold = function() self:_showShelfDialog(r) end,
            }
            if i < #results then
                content[#content + 1] = VerticalSpan:new{ width = sp(6) }
            end
        end
    end
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = screen_w, h = body_h },
        show_parent = self,
    }
    scroll[1] = content
    return scroll
end

function MainScreen:_searchDialog(view)
    local dialog
    dialog = InputDialog:new{
        title = _("Search Goodreads"),
        input = view.query or "",
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                if q and q ~= "" then self:_runSearch(view, q) end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MainScreen:_openRecs()
    local saved = Native._recsCache()
    local books = saved and saved.books
    if type(books) ~= "table" or #books == 0 then books = nil end
    self.stack = { {
        kind = "recs",
        page = (saved and saved.page) or 1,
        books = books,
        has_more = saved and saved.has_more or false,
        loading = not books,
    } }
    self:_render()
    if not books then self:_fetchRecommendations(1) end
end

function MainScreen:_fetchRecommendations(page)
    local v = self.stack[1]
    if v and v.kind == "recs" then
        v.page = page
        v.loading = true
        v.error = nil
    end
    self:_render()
    self._token = self._token + 1
    local token = self._token
    local plugin = self.plugin
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, books, has_more = plugin:runInBackground(_("Loading recommendations…"), function()
                return Native._loadRecommendations(plugin, page)
            end)
            if not self._alive or token ~= self._token then return end
            local cur = self.stack[1]
            if not cur or cur.kind ~= "recs" then return end
            cur.loading = false
            if completed ~= false and type(books) == "table" and #books > 0 then
                cur.books = books
                cur.page = page
                cur.has_more = has_more and true or false
                cur.error = nil
                Native._saveRecs({
                    books = books,
                    page = page,
                    has_more = cur.has_more,
                    saved_at = os.time(),
                })
            elseif not cur.books then
                cur.error = _("Couldn't load recommendations.")
            end
            self:_render()
        end)
    end)
end

function MainScreen:openAuthor(author_id, name)
    if not author_id then return end
    self.stack[#self.stack + 1] = {
        kind = "author",
        author_id = author_id,
        author_name = name,
        loading = true,
        page = 1,
    }
    self:_render()
    self:_fetchAuthor(author_id)
end

function MainScreen:_fetchAuthor(author_id)
    self._token = self._token + 1
    local token = self._token
    local plugin = self.plugin
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, books = plugin:runInBackground(_("Loading author…"), function()
                return Native._loadAuthorBooks(plugin, author_id)
            end)
            if not self._alive or token ~= self._token then return end
            local v = self.stack[#self.stack]
            if not v or v.kind ~= "author" or v.author_id ~= author_id then return end
            v.loading = false
            if completed ~= false and type(books) == "table" then
                v.books = books
            else
                v.error = _("Couldn't load this author.")
            end
            self:_render()
        end)
    end)
end

function MainScreen:_runSearch(view, query)
    view.query = query
    view.searching = true
    view.results = nil
    self:_render()
    self._token = self._token + 1
    local token = self._token
    local plugin = self.plugin
    local tab = view.tab or "books"
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, results = plugin:runInBackground(_("Searching Goodreads…"), function()
                if tab == "authors" then
                    return Native._searchAuthors(plugin, query)
                end
                return Native._search(plugin, query)
            end)
            if not self._alive or token ~= self._token then return end
            if completed == false then return end
            local v = self.stack[#self.stack]
            if not v or v.kind ~= "search" or v.query ~= query then return end
            v.results = type(results) == "table" and results or {}
            v.searching = false
            self:_render()
        end)
    end)
end

-- Never let a render error take the whole app down: it becomes an error screen
-- with a working Close button instead.
function MainScreen:_render()
    if self._alive == false then return end
    local ok, err = pcall(function() self:_renderNow() end)
    if not ok then
        Logging.error("native ui: render failed:", tostring(err))
        pcall(function() self:_renderError(err) end)
    end
end

function MainScreen:_renderError(err)
    local top = VerticalGroup:new{ align = "center" }
    top[1] = self:_titlebar(_("Goodreads"), _("Error"))
    top[2] = VerticalSpan:new{ width = sp(20) }
    top[3] = TextBoxWidget:new{
        text = tostring(err or _("Something went wrong.")),
        face = Font:getFace("infofont"),
        alignment = "center",
        width = Screen:getWidth() - 2 * self:_margins(),
    }
    local bg = FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
    }
    bg[1] = top
    self[1] = bg
    UIManager:setDirty(self, "ui")
end

function MainScreen:_renderNow()
    local view = self.stack[#self.stack]
    if not view then return self:onClose() end

    local title, subtitle
    if view.kind == "book" then
        title = view.book and view.book.title or _("Book")
        subtitle = view.book and view.book.author
    elseif view.kind == "list" then
        title = view.title or _("Goodreads")
    elseif view.kind == "search" then
        title = _("Goodreads")
        subtitle = _("Search")
    elseif view.kind == "menu" then
        title = _("Goodreads")
        subtitle = _("Menu")
    elseif view.kind == "reviews" then
        title = view.book and view.book.title or _("Book")
        subtitle = _("Reviews")
    elseif view.kind == "recs" then
        title = _("Goodreads")
        subtitle = _("Recommendations")
    elseif view.kind == "reading" then
        title = _("Goodreads")
        subtitle = _("Currently Reading")
    elseif view.kind == "author" then
        title = view.author_name or _("Author")
        subtitle = _("Books")
    else
        title = _("Goodreads")
        subtitle = shelfLabel(view.shelf)
    end
    local titlebar = self:_titlebar(title, subtitle)

    local header = VerticalGroup:new{ align = "center" }
    header[1] = titlebar
    if #self.stack == 1 then
        header[#header + 1] = self:_sectionTabs()
        header[#header + 1] = hline()
    end
    if view.kind == "shelf" or view.kind == "reading" then
        if view.kind == "shelf" then
            header[#header + 1] = self:_shelfBar()
        end
        header[#header + 1] = self:_actionBar()
    end
    if (view.kind == "shelf" or view.kind == "reading") and view.from_cache then
        header[#header + 1] = self:_cachedLine(view)
    end
    -- Opaque header + a separator + a gap so the first list row can never
    -- visually collide with the shelf tabs.
    local header_frame = FrameContainer:new{
        width = Screen:getWidth(),
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
    }
    header_frame[1] = header
    local chrome = VerticalGroup:new{ align = "center" }
    chrome[1] = header_frame
    chrome[2] = LineWidget:new{
        background = COLOR_LINE,
        dimen = Geom:new{ w = Screen:getWidth(), h = sp(1) },
    }
    chrome[3] = VerticalSpan:new{ width = sp(6) }
    local body_h = Screen:getHeight() - chrome:getSize().h
    local body = self:_bodyFor(view, body_h)

    local root = VerticalGroup:new{ align = "center" }
    root[1] = chrome
    root[2] = body
    -- Opaque full-screen backdrop so the previous KOReader UI can't show
    -- through (and night mode still inverts it correctly).
    local bg = FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
    }
    bg[1] = root
    self[1] = bg
    UIManager:setDirty(self, "ui")
end

--------------------------------------------------------------------------------
-- Shelf navigation + loading
--------------------------------------------------------------------------------

function MainScreen:openShelf(shelf, opts)
    opts = opts or {}
    if not shelf then return end
    Logging.diag("native: open shelf=", shelfLabel(shelf), " refresh=", tostring(opts.refresh == true))
    self.active = shelf
    local cached_books = shelf.books
    -- An empty table means "not loaded", not "cached empty shelf" -- otherwise
    -- a shelf whose cached books were empty would never fetch.
    if type(cached_books) ~= "table" or #cached_books == 0 then cached_books = nil end
    -- Always operate on a single root shelf view, so selecting a shelf from the
    -- picker returns here rather than stacking views.
    self.stack = { {
        kind = "shelf",
        shelf = shelf,
        books = cached_books,
        loading = not cached_books,
        page = 1,
        from_cache = cached_books ~= nil,
    } }
    self:_render()
    -- Cached books render instantly (covers come from the on-disk cache); only
    -- hit the network on first load or explicit refresh.
    if cached_books and not opts.refresh then
        -- If the cached books predate cover parsing (no cover URLs), refresh
        -- this shelf once so covers and other fields get populated.
        local need_meta = false
        for _i, b in ipairs(cached_books) do
            if not b.cover_url then need_meta = true break end
        end
        if need_meta and not shelf._meta_refreshed then
            shelf._meta_refreshed = true
            self:_fetchShelf(shelf)
        end
        return
    end
    self:_fetchShelf(shelf)
end

function MainScreen:_fetchShelf(shelf)
    self._token = self._token + 1
    local token = self._token
    local plugin = self.plugin
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, books = plugin:runInBackground(
                string.format(_("Loading %s…"), shelfLabel(shelf)), function()
                    return Native._loadShelf(plugin, shelf)
                end)
            if not self._alive or token ~= self._token then return end
            if completed == false then return end
            local v = self.stack[1]
            if type(books) ~= "table" then
                if v and (v.kind == "shelf" or v.kind == "reading") then
                    v.loading = false
                    if not plugin:isOnline() then
                        v.error = _("Offline — tap Refresh when online.")
                    else
                        v.error = _("Couldn't load this shelf.")
                    end
                end
                self:_render()
                return
            end
            shelf.books = books
            shelf.books_at = os.time()
            if plugin.persistLibrary then
                pcall(function()
                    plugin:persistLibrary({ shelves = self.shelves, full = true, saved_at = os.time() })
                end)
            end
            if v and (v.kind == "shelf" or v.kind == "reading") and v.shelf == shelf then
                v.books = books
                v.loading = false
                v.error = nil
                v.from_cache = false
                v._covers_requested = nil -- allow covers to be (re)fetched
            end
            self:_render()
        end)
    end)
end

function MainScreen:openBook(book)
    if not book or not book.goodreads_id then return end
    self.stack[#self.stack + 1] = { kind = "book", book = book, loading = true }
    self:_render()

    self._token = self._token + 1
    local token = self._token
    local plugin = self.plugin
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, info = plugin:runInBackground(_("Loading book…"), function()
                return Native._loadBook(plugin, book)
            end)
            if not self._alive or token ~= self._token then return end
            local v = self.stack[#self.stack]
            if not v or v.kind ~= "book" or v.book ~= book then return end
            if completed ~= false and type(info) == "table" then
                v.info = info
            end
            v.loading = false
            self:_render()
        end)
    end)
end

function MainScreen:back()
    table.remove(self.stack)
    if #self.stack == 0 then
        self:onClose()
    else
        self:_render()
    end
end

--------------------------------------------------------------------------------
-- Book detail + actions
--------------------------------------------------------------------------------

function MainScreen:openReviews(book)
    if not book or not book.goodreads_id then return end
    self.stack[#self.stack + 1] = { kind = "reviews", book = book, page = 1, loading = true }
    self:_fetchReviews(book, 1)
end

function MainScreen:_fetchReviews(book, page)
    local v = self.stack[#self.stack]
    if v and v.kind == "reviews" and v.book == book then
        v.page = page
        v.loading = true
        v.error = nil
    end
    self:_render()
    self._token = self._token + 1
    local token = self._token
    local plugin = self.plugin
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, res = plugin:runInBackground(_("Loading reviews…"), function()
                return Native._loadReviews(plugin, book.goodreads_id, page)
            end)
            if not self._alive or token ~= self._token then return end
            local cur = self.stack[#self.stack]
            if not cur or cur.kind ~= "reviews" or cur.book ~= book then return end
            cur.loading = false
            if completed ~= false and type(res) == "table" then
                cur.reviews = res.reviews
                cur.has_more = res.has_more
            else
                Logging.diag("native: reviews load failed book=", tostring(book.goodreads_id))
                cur.error = _("Couldn't load reviews.")
            end
            self:_render()
        end)
    end)
end

function MainScreen:_reviewsBody(view, body_h)
    if view.loading then return self:_centered(_("Loading…"), body_h) end
    if view.error then return self:_centered(view.error, body_h) end
    local reviews = view.reviews or {}
    if #reviews == 0 then return self:_centered(_("No reviews."), body_h) end
    local screen_w = Screen:getWidth()
    local margin = self:_margins()
    local inner_w = screen_w - 2 * margin
    local content = VerticalGroup:new{ align = "center" }
    for _i, r in ipairs(reviews) do
        local lines = VerticalGroup:new{ align = "left" }
        lines[#lines + 1] = TextWidget:new{
            text = r.name or _("Reader"),
            face = Font:getFace("infofont"),
            bold = true,
            max_width = inner_w,
        }
        if r.rating and r.rating > 0 then
            lines[#lines + 1] = TextWidget:new{
                text = stars(r.rating),
                face = Font:getFace("infofont"),
                max_width = inner_w,
            }
        end
        if r.text then
            lines[#lines + 1] = VerticalSpan:new{ width = sp(6) }
            lines[#lines + 1] = TextBoxWidget:new{
                text = r.text,
                face = Font:getFace("infofont"),
                alignment = "left",
                width = inner_w,
            }
        end
        local frame = FrameContainer:new{
            width = screen_w, padding = sp(14), margin = 0, bordersize = 0,
        }
        frame[1] = lines
        content[#content + 1] = frame
        content[#content + 1] = LineWidget:new{
            background = COLOR_LINE,
            dimen = Geom:new{ w = screen_w, h = sp(1) },
        }
    end

    local pager = HorizontalGroup:new{ align = "center" }
    local bw = math.floor(inner_w / 3)
    pager[#pager + 1] = Button:new{
        text = _("◀ Prev"),
        width = bw,
        bordersize = sp(1),
        enabled = (view.page or 1) > 1,
        callback = function() self:_fetchReviews(view.book, (view.page or 1) - 1) end,
    }
    pager[#pager + 1] = TextWidget:new{
        text = string.format("  %d  ", view.page or 1),
        face = Font:getFace("smallinfofont"),
        fgcolor = COLOR_MUTED,
    }
    pager[#pager + 1] = Button:new{
        text = _("Next ▶"),
        width = bw,
        bordersize = sp(1),
        enabled = view.has_more and true or false,
        callback = function() self:_fetchReviews(view.book, (view.page or 1) + 1) end,
    }
    local pager_frame = FrameContainer:new{
        width = screen_w, padding = sp(8), margin = 0, bordersize = 0,
    }
    pager_frame[1] = pager
    content[#content + 1] = pager_frame

    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = screen_w, h = body_h },
        show_parent = self,
    }
    scroll[1] = content
    return scroll
end

function MainScreen:_bookDetail(view, body_h)
    local info = view.info or view.book or {}
    local book = view.book or {}
    local screen_w = Screen:getWidth()
    local margin = self:_margins()
    local inner_w = screen_w - 2 * margin
    local content = VerticalGroup:new{ align = "center" }

    local cover_box = math.min(sp(240), math.floor(body_h * 0.5))
    local cover_w = math.floor(cover_box * 2 / 3)
    local cover = coverWidget(info.cover_file, cover_w, cover_box)
    if cover then
        local cover_frame = FrameContainer:new{
            bordersize = sp(1),
            color = COLOR_LINE,
            padding = 0,
            margin = 0,
        }
        cover_frame[1] = cover
        content[#content + 1] = cover_frame
    end
    content[#content + 1] = VerticalSpan:new{ width = sp(14) }
    content[#content + 1] = TextBoxWidget:new{
        text = info.title or _("Untitled"),
        face = Font:getFace("tfont"),
        bold = true,
        alignment = "center",
        width = inner_w,
    }
    local author = info.author or (type(info.authors) == "table" and info.authors[1])
    if author and author ~= "" then
        content[#content + 1] = VerticalSpan:new{ width = sp(6) }
        content[#content + 1] = TextBoxWidget:new{
            text = author,
            face = Font:getFace("infofont"),
            fgcolor = COLOR_MUTED,
            alignment = "center",
            width = inner_w,
        }
    end

    content[#content + 1] = VerticalSpan:new{ width = sp(14) }

    -- Average rating + ratings count
    local avg_bits = HorizontalGroup:new{ align = "center" }
    if info.rating and info.rating > 0 then
        avg_bits[#avg_bits + 1] = TextWidget:new{ text = stars(info.rating), face = Font:getFace("cfont") }
        if info.ratings_count and info.ratings_count > 0 then
            local counts = string.format(_("%d ratings"), info.ratings_count)
            if info.reviews_count and info.reviews_count > 0 then
                counts = counts .. " · " .. string.format(_("%d reviews"), info.reviews_count)
            end
            avg_bits[#avg_bits + 1] = HorizontalSpan:new{ width = sp(6) }
            avg_bits[#avg_bits + 1] = TextWidget:new{
                text = counts,
                face = Font:getFace("smallinfofont"),
                fgcolor = COLOR_MUTED,
            }
        end
    else
        avg_bits[#avg_bits + 1] = TextWidget:new{
            text = _("No rating yet"),
            face = Font:getFace("smallinfofont"),
            fgcolor = COLOR_MUTED,
        }
    end
    local avg_frame = FrameContainer:new{ width = screen_w, bordersize = 0, padding = 0, margin = 0 }
    avg_frame[1] = avg_bits
    content[#content + 1] = avg_frame

    -- Progress (when known, e.g. opened from Currently Reading)
    if book.progress then
        content[#content + 1] = VerticalSpan:new{ width = sp(10) }
        content[#content + 1] = TextWidget:new{
            text = string.format(_("Goodreads: %d%%"), book.progress),
            face = Font:getFace("infofont"),
            bold = true,
        }
    end

    -- Global shelf actions: Want to Read / Currently Reading / Read
    content[#content + 1] = VerticalSpan:new{ width = sp(16) }
    local current_slug = book.slug or info.slug
    local shelf_frame = FrameContainer:new{ width = screen_w, bordersize = 0, padding = 0, margin = 0 }
    shelf_frame[1] = self:_shelfButtons(book, current_slug)
    content[#content + 1] = shelf_frame

    -- Inline star rating (spec §11: 1-5 whole stars, clear supported)
    content[#content + 1] = VerticalSpan:new{ width = sp(16) }
    content[#content + 1] = TextWidget:new{
        text = _("Your rating"),
        face = Font:getFace("smallinfofont"),
        fgcolor = COLOR_MUTED,
    }
    content[#content + 1] = self:_ratingRow(view)

    -- Metadata
    local meta = {}
    if info.publisher and info.publisher ~= "" then meta[#meta + 1] = info.publisher end
    if info.published and info.published ~= "" then meta[#meta + 1] = info.published end
    if info.pages then meta[#meta + 1] = string.format(_("%d pages"), info.pages) end
    if info.isbn and info.isbn ~= "" then meta[#meta + 1] = "ISBN " .. info.isbn end
    if #meta > 0 then
        content[#content + 1] = VerticalSpan:new{ width = sp(12) }
        content[#content + 1] = TextWidget:new{
            text = table.concat(meta, "  ·  "),
            face = Font:getFace("smallinfofont"),
            fgcolor = COLOR_MUTED,
            max_width = inner_w,
        }
    end
    if info.awards and info.awards ~= "" then
        content[#content + 1] = VerticalSpan:new{ width = sp(8) }
        content[#content + 1] = TextBoxWidget:new{
            text = string.format(_("Awards: %s"), info.awards),
            face = Font:getFace("smallinfofont"),
            fgcolor = COLOR_MUTED,
            alignment = "left",
            width = inner_w,
        }
    end

    -- Description
    if info.description and info.description ~= "" then
        content[#content + 1] = VerticalSpan:new{ width = sp(14) }
        content[#content + 1] = TextBoxWidget:new{
            text = info.description,
            face = Font:getFace("infofont"),
            alignment = "left",
            width = inner_w,
        }
    end

    -- Reviews preview (spec §10)
    local preview = info.reviews
    if type(preview) == "table" and #preview > 0 then
        content[#content + 1] = VerticalSpan:new{ width = sp(16) }
        content[#content + 1] = TextWidget:new{
            text = _("Reviews"),
            face = Font:getFace("infofont"),
            bold = true,
        }
        for i = 1, math.min(3, #preview) do
            local r = preview[i]
            content[#content + 1] = VerticalSpan:new{ width = sp(8) }
            content[#content + 1] = TextWidget:new{
                text = r.name or _("Reader"),
                face = Font:getFace("smallinfofont"),
                bold = true,
                max_width = inner_w,
            }
            if r.rating and r.rating > 0 then
                content[#content + 1] = TextWidget:new{
                    text = stars(r.rating),
                    face = Font:getFace("smallinfofont"),
                    max_width = inner_w,
                }
            end
            if r.text then
                content[#content + 1] = TextBoxWidget:new{
                    text = truncate(r.text, 280),
                    face = Font:getFace("smallinfofont"),
                    alignment = "left",
                    width = inner_w,
                }
            end
            content[#content + 1] = LineWidget:new{
                background = COLOR_LINE,
                dimen = Geom:new{ w = screen_w, h = sp(1) },
            }
        end
    end

    -- More by Author
    if info.author_id then
        content[#content + 1] = VerticalSpan:new{ width = sp(14) }
        content[#content + 1] = Button:new{
            text = string.format(_("More by %s"), info.author or author or ""),
            width = inner_w,
            bordersize = sp(1),
            callback = function() self:openAuthor(info.author_id, info.author or author) end,
        }
    end

    -- Actions
    content[#content + 1] = VerticalSpan:new{ width = sp(16) }
    content[#content + 1] = Button:new{
        text = _("Update progress…"),
        width = inner_w,
        bordersize = sp(1),
        callback = function() self:_setProgress(book) end,
    }
    content[#content + 1] = VerticalSpan:new{ width = sp(10) }
    content[#content + 1] = Button:new{
        text = _("Rate…"),
        width = inner_w,
        bordersize = sp(1),
        callback = function() self:_rateBook(book) end,
    }
    content[#content + 1] = VerticalSpan:new{ width = sp(10) }
    content[#content + 1] = Button:new{
        text = _("Reviews"),
        width = inner_w,
        bordersize = sp(1),
        callback = function() self:openReviews(book) end,
    }
    content[#content + 1] = VerticalSpan:new{ width = sp(20) }

    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = screen_w, h = body_h },
        show_parent = self,
    }
    scroll[1] = content
    return scroll
end

-- Spec §11: an inline 1-5 whole-star control with a Clear action.
function MainScreen:_ratingRow(view)
    local book = view.book or {}
    local info = view.info or {}
    local my = info.my_rating
    if my == nil then my = book.rating end
    my = tonumber(my) or 0
    local row = HorizontalGroup:new{ align = "center" }
    local total = Screen:getWidth() - 2 * self:_margins()
    local bw = math.floor(total / 6)
    for s = 1, 5 do
        local filled = (my >= s)
        row[#row + 1] = Button:new{
            text = filled and "\226\152\133" or "\226\152\134",
            width = bw,
            margin = 0,
            bordersize = 0,
            text_font_face = "tfont",
            callback = function() self:_rateBook(book, s) end,
        }
    end
    row[#row + 1] = Button:new{
        text = _("Clear"),
        width = bw,
        margin = 0,
        bordersize = sp(1),
        text_font_face = "smallinfofont",
        callback = function()
            self:_runAction(function()
                local provider = self.plugin:getProvider()
                return provider:clear_rating(book.goodreads_id)
            end, _("Rating cleared"))
            if view.info then view.info.my_rating = nil end
            self:_render()
        end,
    }
    return row
end

function MainScreen:_runAction(fn, ok_msg)
    local plugin = self.plugin
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, ok = plugin:runInBackground(_("Saving…"), fn)
            if completed == false then return end
            if ok then
                Widgets.notify(ok_msg)
            else
                Widgets.notify(_("Couldn't save the change."))
            end
        end)
    end)
end

-- Local-first shelf change: queue it and let the background drain post it.
function MainScreen:_enqueueShelf(book, slug)
    if not book or not book.goodreads_id or not slug then return end
    Queue.enqueue({
        operation = "add_to_shelf",
        book_id = book.goodreads_id,
        uid = slug,
        payload = { type = "add_to_shelf", slug = slug },
    })
    self.plugin:processQueue()
    Widgets.notify(string.format("%s · %s · %s", book.title or book.goodreads_id,
        SHELF_LABEL[slug] or slug, _("queued")), 3, "book")
    book.slug = slug
end

function MainScreen:_setShelf(view, canonical)
    local book = view.book or {}
    if not book.goodreads_id then return end
    self:_enqueueShelf(book, canonical.slug)
    if view.info then view.info.slug = canonical.slug end
    self:_render()
end

-- Spec §9: in-app shelf chooser with a checkmark on the current shelf.
function MainScreen:_showShelfDialog(book, current_slug)
    if not book or not book.goodreads_id then return end
    local items = {}
    for _, c in ipairs(CANONICAL) do
        items[#items + 1] = {
            text = SHELF_LABEL[c.slug] or c.slug,
            checked_func = function() return current_slug == c.slug end,
            callback = function()
                self:_enqueueShelf(book, c.slug)
                self:back()
            end,
        }
    end
    self:pushList(string.format(_("Shelf for “%s”"), book.title or ""), items)
end

function MainScreen:_rateBook(book, value)
    book = book or {}
    if not book.goodreads_id then return end
    if value == nil then
        Widgets.starDialog(string.format(_("Rate “%s”"), book.title or ""), function(v)
            self:_rateBook(book, v)
        end, function() end)
        return
    end
    self:_runAction(function()
        local provider = self.plugin:getProvider()
        return provider:set_rating(book.goodreads_id, value)
    end, _("Rating saved"))
    book.rating = value
    self:_render()
end

function MainScreen:_setProgress(book)
    book = book or {}
    if not book.goodreads_id then return end
    local dialog
    dialog = InputDialog:new{
        title = string.format(_("Progress for “%s”"), book.title or ""),
        input = "",
        input_type = "number",
        description = _("Percent read (0–100)"),
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local value = tonumber(dialog:getInputText())
                UIManager:close(dialog)
                if value and value >= 0 and value <= 100 then
                    self:_runAction(function()
                        local provider = self.plugin:getProvider()
                        return provider:update_progress(book.goodreads_id, value, "percent")
                    end, _("Progress updated"))
                else
                    Widgets.notify(_("Enter a number from 0 to 100"))
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MainScreen:_bootstrap()
    local plugin = self.plugin
    if not plugin then return end
    local ok_cache, cached = pcall(function() return plugin:cachedLibraryData() end)
    local cached_shelves = ok_cache and cached and cached.shelves
    local have_cache = type(cached_shelves) == "table" and #cached_shelves > 0
    self.shelves = have_cache and cached_shelves or FALLBACK_SHELVES

    -- Open immediately from cache (instant, covers come from disk).
    local default = self:_topShelves(1)[1] or FALLBACK_SHELVES[1]
    self:openShelf(default)

    -- Reach the network automatically ONLY on the very first run (no cache).
    -- Afterwards everything comes from cache until the user taps Refresh, so
    -- opening the app is offline-instant.
    if not have_cache then
        self:_refreshShelves()
    end
end

-- Manual refresh of the shelf list (from the shelf picker).
function MainScreen:_refreshShelves()
    local plugin = self.plugin
    self._shelf_token = (self._shelf_token or 0) + 1
    local token = self._shelf_token
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, shelves = plugin:runInBackground(_("Loading shelves…"), function()
                local provider = plugin:getProvider()
                if not provider or not provider.get_library then return nil end
                return provider:get_library()
            end)
            if not self._alive or token ~= self._shelf_token or completed == false then return end
            if type(shelves) ~= "table" or #shelves == 0 then return end
            -- Preserve books already loaded for shelves with the same slug.
            local by_slug = {}
            for _, s in ipairs(self.shelves or {}) do by_slug[s.slug] = s end
            for _, s in ipairs(shelves) do
                local old = by_slug[s.slug]
                if old and old.books and #old.books > 0 then
                    s.books = old.books
                    s.books_at = old.books_at
                end
            end
            self.shelves = shelves
            if plugin.persistLibrary then
                pcall(function()
                    plugin:persistLibrary({ shelves = shelves, full = true, saved_at = os.time() })
                end)
            end
            local cur = self.stack[1]
            if cur and cur.kind == "shelf" and cur.shelf then
                local found
                for _, s in ipairs(shelves) do
                    if s.slug == cur.shelf.slug then found = s break end
                end
                if not found then
                    self:openShelf(self:_topShelves(1)[1] or shelves[1], { refresh = true })
                    return
                end
                self.active = found
            end
            self:_render()
        end)
    end)
end

function Native.show(plugin)
    if not plugin or plugin._native_screen then
        return
    end
    local ok, screen = pcall(function()
        return MainScreen:new{ plugin = plugin }
    end)
    if not ok or not screen then
        Logging.error("native ui: failed to open")
        Widgets.message(_("Couldn't open Goodreads."), 4)
        return
    end

    -- Establish a visible, closable screen *before* any risky work, so a
    -- failure can never leave a blank, apparently-unresponsive overlay.
    screen.shelves = FALLBACK_SHELVES
    screen._alive = true
    screen._token = screen._token or 0
    screen.ges_events = screen.ges_events or {}
    screen.stack = { { kind = "shelf", shelf = FALLBACK_SHELVES[1], loading = true } }
    plugin._native_screen = screen
    UIManager:show(screen)
    local ok_render = pcall(function() screen:_render() end)
    if not ok_render then
        Logging.error("native ui: initial render failed")
    end

    local ok_boot, err = pcall(function() screen:_bootstrap() end)
    if not ok_boot then
        Logging.error("native ui: bootstrap failed:", tostring(err))
    end
end

return Native
