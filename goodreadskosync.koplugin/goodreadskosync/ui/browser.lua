--[[--
On-device Goodreads reader ("Browse Goodreads").

Fetches Goodreads pages with the plugin's existing session, rewrites them into
clean self-contained HTML, and opens them in KOReader's HTML engine (CRE) so
they render formatted (headings, paragraphs, lists, tappable links).

Navigation is done by tapping links in the page: the link hook adds an
"Open in Goodreads reader" button so the next page loads in the same reader.
A small top bar offers Back / Reload / Home.

Mixed into the plugin as methods (`self` is the plugin instance).

@module koplugin.goodreads.ui.browser
--]]

local Logging = require("goodreadskosync.logging")
local Render = require("goodreadskosync.browse.render")
local Session = require("goodreadskosync.auth.session")
local Storage = require("goodreadskosync.storage")
local Widgets = require("goodreadskosync.ui.widgets")
local _ = require("gettext")

local Browser = {}

local HOME = "https://www.goodreads.com/"

local function is_goodreads(url)
    return type(url) == "string" and url:match("^https?://[^/]*goodreads%.com") ~= nil
end

-- Remove a file, or a directory (KOReader's .sdr sidecar) if it is one.
local function remove_path(path)
    if type(path) ~= "string" then return end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes(path, "mode") == "directory" then
        local ok_ffi, ffiUtil = pcall(require, "ffi/util")
        if ok_ffi and ffiUtil and ffiUtil.purgeDir then ffiUtil.purgeDir(path) end
    else
        os.remove(path)
    end
end

-- Absolute https URLs of the page's linked stylesheets.
local function stylesheet_urls(html, base)
    local urls, seen = {}, {}
    local host = (base and base:match("^(https?://[^/]+)")) or "https://www.goodreads.com"
    for tag in html:gmatch("<link[^>]*>") do
        local rel = tag:match('rel="([^"]+)"') or tag:match("rel='([^']+)'")
        local href = tag:match('href="([^"]+)"') or tag:match("href='([^']+)'")
        if rel and href and rel:find("stylesheet") then
            local abs = href
            if abs:sub(1, 2) == "//" then
                abs = "https:" .. abs
            elseif abs:sub(1, 1) == "/" then
                abs = host .. abs
            end
            if abs:match("^https://") and not seen[abs] then
                seen[abs] = true
                urls[#urls + 1] = abs
            end
        end
    end
    return urls
end

-- Fetch a page with the stored session. Returns body or nil, error.
-- detect_auth is off: browsing reads arbitrary pages, and the sign-in sniffing
-- used for write operations gives false positives on normal Goodreads pages.
function Browser:_browseFetch(url)
    local session = Session.load()
    if not Session.is_valid(session) then return nil, "AUTH_REQUIRED" end
    local http = Session.to_http(session)
    local resp = http:get(url, { follow = true, detect_auth = false })
    Session.absorb(session, http)
    Session.save(session)
    if resp.error then
        Logging.trace("browse: fetch error=", tostring(resp.error),
            " status=", tostring(resp.status), " url=", tostring(url))
        return nil, tostring(resp.error)
    end
    if not resp.body or resp.body == "" then
        Logging.trace("browse: empty body url=", tostring(url))
        return nil, "empty"
    end
    Logging.trace("browse: loaded url=", tostring(url), " bytes=", tostring(#resp.body))
    return resp.body
end

-- Best-effort: fetch the page's own CSS so CRE styles it like the site.
function Browser:_browseCollectCss(html, base)
    local urls = stylesheet_urls(html, base)
    if #urls == 0 then return "" end
    local session = Session.load()
    local http = Session.to_http(session)
    local parts, total = {}, 0
    for i = 1, math.min(#urls, 2) do
        local resp = http:get(urls[i], { follow = true, detect_auth = false })
        if resp and resp.body and #resp.body > 0 then
            parts[#parts + 1] = resp.body
            total = total + #resp.body
            if total > 300000 then break end
        end
    end
    return table.concat(parts, "\n")
end

-- Register the "Open in Goodreads reader" button shown when a link is tapped,
-- so goodreads.com links load in our reader instead of an external browser.
function Browser:registerBrowseLinkHook()
    if self._browse_link_hook then return end
    local ui = self.ui
    if not (ui and ui.link and ui.link.addToExternalLinkDialog) then return end
    ui.link:removeFromExternalLinkDialog("goodreads_reader")
    ui.link:addToExternalLinkDialog("goodreads_reader", function(_dialog, link_url)
        return {
            text = _("Open in Goodreads reader"),
            show_in_dialog_func = function(url)
                return is_goodreads(url)
            end,
            callback = function() self:_browseLoad(link_url) end,
        }
    end)
    self._browse_link_hook = true
end

-- Open the reader at the Goodreads home page.
function Browser:openGoodreadsBrowser()
    self:registerBrowseLinkHook()
    self:setSetting("browse_history", { HOME })
    self:setSetting("browse_index", 1)
    self:_browseLoad(HOME)
end

-- Fetch, rewrite and open `url`. mode: "push" (default) | "replace" | "none".
function Browser:_browseLoad(url, mode)
    if not is_goodreads(url) then
        Widgets.message(_("Only goodreads.com can be opened here."), 4)
        return
    end

    local history = self:getSetting("browse_history") or { HOME }
    local index = tonumber(self:getSetting("browse_index")) or 1
    if mode == "replace" then
        history, index = { url }, 1
    elseif mode ~= "none" then
        while #history > index do table.remove(history) end
        history[#history + 1] = url
        index = #history
    end
    self:setSetting("browse_history", history)
    self:setSetting("browse_index", index)
    local back = (index > 1) and history[index - 1] or nil

    -- Reuse two fixed files (alternating) instead of one per page, so KOReader
    -- does not accumulate "books" and .sdr sidecars while browsing.
    local slot = (tonumber(self:getSetting("browse_slot")) or 0) + 1
    if slot > 2 then slot = 1 end
    self:setSetting("browse_slot", slot)

    self:runWhenOnline(function()
        self:runAsync(function()
            local completed, ok, extra = self:runInBackground(_("Loading Goodreads…"), function()
                local body, err = self:_browseFetch(url)
                if not body then return false, (err or "fetch") end
                local css = self:_browseCollectCss(body, url)
                local doc = Render.page(body, url,
                    { back = back, reload = url, home = HOME }, css)
                local file = Storage.getBaseDir() .. "/browse-" .. tostring(slot) .. ".html"
                -- Fresh file and sidecar for this slot.
                remove_path(file)
                remove_path(file .. ".sdr")
                local f = io.open(file, "w")
                if not f then return false, "write" end
                f:write(doc)
                f:close()
                return true, file
            end)
            if completed == false then return end
            if not ok then
                Widgets.message(string.format(_("Couldn't load the page (%s)."),
                    tostring(extra or "?")), 6)
                return
            end
            local path = extra
            local prev = self:getSetting("browse_prev")
            Logging.trace("browse: rendering ", tostring(path))
            if self.ui and self.ui.showReader then
                self.ui:showReader(path)
            elseif self.ui and self.ui.openFile then
                self.ui:openFile(path)
            else
                Widgets.message(_("Can't open Goodreads here."), 5)
                return
            end
            -- Drop the previous slot's file and sidecar once the new page is up.
            if prev and prev ~= path then
                remove_path(prev)
                remove_path(prev .. ".sdr")
            end
            self:setSetting("browse_prev", path)
        end)
    end)
end

return Browser
