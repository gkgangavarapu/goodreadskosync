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

-- Fetch a page with the stored session. Returns body or nil, error.
function Browser:_browseFetch(url)
    local session = Session.load()
    if not Session.is_valid(session) then return nil, "auth" end
    local http = Session.to_http(session)
    local resp = http:get(url, { follow = true, detect_auth = true })
    Session.absorb(session, http)
    Session.save(session)
    if resp.error then return nil, resp.error end
    return resp.body
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

    self:runWhenOnline(function()
        self:runAsync(function()
            local completed, ok, path = self:runInBackground(_("Loading Goodreads…"), function()
                local body = self:_browseFetch(url)
                if not body then return false, "fetch" end
                local doc = Render.page(body, url, { back = back, reload = url, home = HOME })
                local file = Storage.getBaseDir() .. "/browse-" .. tostring(os.time()) ..
                    "-" .. tostring(math.random(1000, 9999)) .. ".html"
                local f = io.open(file, "w")
                if not f then return false, "write" end
                f:write(doc)
                f:close()
                return true, file
            end)
            if completed == false then return end
            if not ok or not path then
                Widgets.message(_("Couldn't load the page."), 5)
                return
            end
            if self.ui and self.ui.showReader then
                self.ui:showReader(path)
            elseif self.ui and self.ui.openFile then
                self.ui:openFile(path)
            else
                Widgets.message(_("Can't open Goodreads here."), 5)
            end
        end)
    end)
end

return Browser
