--[[--
On-device Goodreads reader ("Browse Goodreads").

Reads server-rendered Goodreads pages with the plugin's existing session and
shows them as clean text, with the page's links listed so you can keep browsing.
It is a reader, not a browser engine: JavaScript-only screens and forms are not
rendered (the plugin's own actions handle writes).

Mixed into the plugin as methods (`self` is the plugin instance).

@module koplugin.goodreads.ui.browser
--]]

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local Parse = require("goodreadskosync.browse.parse")
local Session = require("goodreadskosync.auth.session")
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
    -- Persist any rotated cookies.
    Session.absorb(session, http)
    Session.save(session)
    if resp.error then return nil, resp.error end
    return resp.body
end

-- Open the reader at the Goodreads home page.
function Browser:openGoodreadsBrowser()
    self._browse_history = { HOME }
    self._browse_index = 1
    self:_browseLoad(HOME, false)
end

-- Load `url` (optionally pushing it onto the history stack).
function Browser:_browseLoad(url, push)
    if not is_goodreads(url) then
        Widgets.message(_("Only goodreads.com can be opened here."), 4)
        return
    end

    if push ~= false then
        while #self._browse_history > self._browse_index do
            table.remove(self._browse_history)
        end
        self._browse_history[#self._browse_history + 1] = url
        self._browse_index = #self._browse_history
    end

    self:runWhenOnline(function()
        self:runAsync(function()
            local completed, body = self:runInBackground(_("Loading Goodreads…"),
                function() return self:_browseFetch(url) end)
            if completed == false then return end
            if not body then
                Widgets.message(_("Couldn't load the page."), 5)
                return
            end
            self._browse_page = Parse.page(body, url)
            self._browse_url = url
            self:_browseReader()
        end)
    end)
end

-- Show the page text (scrollable). When dismissed, show the link/nav list.
function Browser:_browseReader()
    local page = self._browse_page or {}
    local url = self._browse_url or HOME
    local title = page.title ~= "" and page.title or _("Goodreads")
    local lines = { title, "", url, "" }
    for _, p in ipairs(page.paragraphs or {}) do
        lines[#lines + 1] = p
    end

    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
        height = math.floor(Screen:getHeight() * 0.85),
        show_icon = false,
        dismiss_callback = function() self:_browseLinks() end,
    })
end

-- Navigation + the page's links, as a list.
function Browser:_browseLinks()
    local page = self._browse_page or { links = {} }
    local url = self._browse_url or HOME
    local items = {
        { text = _("Back"), callback = function() self:_browseBack() end },
        { text = _("Forward"), callback = function() self:_browseForward() end },
        { text = _("Reload"), callback = function() self:_browseLoad(url, false) end },
        { text = _("Home"), callback = function() self:_browseLoad(HOME) end },
        { text = _("Open URL…"), callback = function() self:_browsePromptUrl() end },
        { text = _("Close"), callback = function() self._browse_menu = nil end },
    }
    if #(page.links or {}) > 0 then
        items[#items + 1] = { text = _("— Links —"), callback = function() end }
        for _, l in ipairs(page.links) do
            items[#items + 1] = {
                text = l.text,
                callback = function() self:_browseLoad(l.href) end,
            }
        end
    else
        items[#items + 1] = { text = _("No links on this page."), callback = function() end }
    end

    local menu
    menu = Menu:new{
        title = page.title ~= "" and page.title or _("Goodreads"),
        item_table = items,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    self._browse_menu = menu
    UIManager:show(menu)
end

function Browser:_browseBack()
    if self._browse_index and self._browse_index > 1 then
        self._browse_index = self._browse_index - 1
        self:_browseLoad(self._browse_history[self._browse_index], false)
    else
        Widgets.message(_("No previous page."), 3)
    end
end

function Browser:_browseForward()
    if self._browse_index and self._browse_index < #self._browse_history then
        self._browse_index = self._browse_index + 1
        self:_browseLoad(self._browse_history[self._browse_index], false)
    else
        Widgets.message(_("No next page."), 3)
    end
end

function Browser:_browsePromptUrl()
    local dialog
    dialog = InputDialog:new{
        title = _("Open on Goodreads"),
        description = _("Enter a goodreads.com address."),
        input = self._browse_url or HOME,
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Open"),
                callback = function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    if value and value ~= "" then
                        if value:match("^https?://") then
                            self:_browseLoad(value)
                        else
                            self:_browseLoad("https://www.goodreads.com/" ..
                                value:gsub("^/+", ""))
                        end
                    end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Browser
