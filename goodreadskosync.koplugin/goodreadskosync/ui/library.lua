--[[--
"Goodreads KO Sync" shelves browser.

Opened from the plugin menu ("Browse shelves"). Opens instantly from the
plugin's own linked books (no network); "Load from Goodreads" fetches the shelf
list (default + custom) in one request, and each shelf's books are fetched on
demand. The whole browser lives in a single persistent Menu until the user
taps Close, so actions (load, move, search) update it in place.

@module koplugin.goodreads.ui.library
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Resolver = require("goodreadskosync.resolver.resolver")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local Widgets = require("goodreadskosync.ui.widgets")
local _ = require("gettext")

local Library = {}

local FALLBACK_SHELVES = {
    { slug = "currently-reading", name = _("Currently Reading") },
    { slug = "read", name = _("Read") },
    { slug = "to-read", name = _("Want to Read") },
    { slug = "did-not-finish", name = _("Did Not Finish") },
}

local function close_item(menu)
    return {
        text = _("Close"),
        callback = function() UIManager:close(menu) end,
    }
end

-- Open the persistent browser box.
function Library.show(plugin)
    local menu = Menu:new{
        title = _("Goodreads shelves"),
        item_table = {},
        width = Screen:getWidth(),
        close_callback = function() end,
    }
    plugin._library_menu = menu
    UIManager:show(menu)
    Library.renderShelves(plugin, plugin:localLibraryData())
end

function Library.renderShelves(plugin, data)
    local menu = plugin._library_menu
    if not menu then return end
    local items = {}
    local shelves = data.shelves or {}
    for i = 1, #shelves do
        local shelf = shelves[i]
        local n = shelf.count or #(shelf.books or {})
        items[#items + 1] = {
            text = string.format("%s  (%d)", shelf.name, n),
            callback = function() Library.openShelf(plugin, data, shelf) end,
        }
    end
    items[#items + 1] = {
        text = data.full and _("Refresh from Goodreads") or _("Load from Goodreads"),
        callback = function() Library.load(plugin) end,
    }
    items[#items + 1] = {
        text = _("Search & add a book"),
        callback = function() Library.searchAndAdd(plugin, data) end,
    }
    items[#items + 1] = {
        text = _("Support this project"),
        callback = function() require("goodreadskosync.ui.support").show() end,
    }
    items[#items + 1] = close_item(menu)
    menu:switchItemTable(data.full and _("Goodreads shelves") or _("Shelves (linked books)"), items)
end

function Library.renderBooks(plugin, data, shelf)
    local menu = plugin._library_menu
    if not menu then return end
    local books = shelf.books or {}
    local items = {
        { text = _("Back"), callback = function() Library.renderShelves(plugin, data) end },
    }
    if #books == 0 then
        items[#items + 1] = { text = _("No books"), select_enabled = false }
    end
    for i = 1, #books do
        local book = books[i]
        items[#items + 1] = {
            text = book.title or book.goodreads_id,
            callback = function() Library.renderBook(plugin, data, shelf, book) end,
        }
    end
    items[#items + 1] = close_item(menu)
    menu:switchItemTable(string.format("%s  (%d)", shelf.name, #books), items)
end

function Library.renderBook(plugin, data, shelf, book)
    local menu = plugin._library_menu
    if not menu then return end
    local items = {
        { text = _("Back"), callback = function() Library.renderBooks(plugin, data, shelf) end },
    }
    local shelves = data.shelves or {}
    for i = 1, #shelves do
        local to = shelves[i]
        if to.slug ~= shelf.slug then
            items[#items + 1] = {
                text = string.format(_("Move to %s"), to.name),
                callback = function() Library.move(plugin, data, book, shelf, to) end,
            }
        end
    end
    items[#items + 1] = close_item(menu)
    menu:switchItemTable(book.title or book.goodreads_id, items)
end

function Library.openShelf(plugin, data, shelf)
    if shelf.books == nil then
        Library.loadShelf(plugin, data, shelf)
    else
        Library.renderBooks(plugin, data, shelf)
    end
end

-- Fetch one shelf's books on demand (a single request), then show them.
function Library.loadShelf(plugin, data, shelf)
    if not plugin.runAsync or not plugin.runInBackground then
        shelf.books = {}
        Library.renderBooks(plugin, data, shelf)
        return
    end
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, books = plugin:runInBackground(
                string.format(_("Loading %s…"), shelf.name), function()
                    return plugin:loadShelf(shelf)
                end)
            if completed == false then return end
            shelf.books = type(books) == "table" and books or {}
            Library.renderBooks(plugin, data, shelf)
        end)
    end)
end

-- Fetch the shelf list (default + custom) and redraw the root view.
function Library.load(plugin)
    if not plugin.runAsync or not plugin.runInBackground then return end
    plugin:runWhenOnline(function()
        plugin:runAsync(function()
            local completed, fetched = plugin:runInBackground(
                _("Loading shelves from Goodreads…"), function()
                    return plugin:libraryData()
                end)
            if completed == false then return end
            if type(fetched) ~= "table" or not fetched.full then
                Widgets.notify(_("Couldn't load shelves from Goodreads"))
                return
            end
            Library.renderShelves(plugin, fetched)
        end)
    end)
end

function Library.move(plugin, data, book, from_shelf, to_shelf)
    plugin:runWhenOnline(function()
        local provider = plugin:getProvider()
        plugin:runAsync(function()
            local completed, ok = plugin:runInBackground(_("Updating Goodreads…"), function()
                if provider.add_to_shelf then
                    return provider:add_to_shelf(book.goodreads_id, to_shelf.slug)
                end
                return false
            end)
            if completed == false then return end
            if not ok then
                Widgets.notify(_("Update failed"))
                return
            end
            -- Update the in-memory model, then redraw in place.
            local books = from_shelf.books or {}
            for i = #books, 1, -1 do
                if tostring(books[i].goodreads_id) == tostring(book.goodreads_id) then
                    table.remove(books, i)
                end
            end
            if to_shelf.books ~= nil then
                table.insert(to_shelf.books, book)
            end
            if from_shelf.count then
                from_shelf.count = math.max(0, from_shelf.count - 1)
            end
            if to_shelf.count then
                to_shelf.count = to_shelf.count + 1
            end
            Widgets.notify(string.format("%s · %s", book.title or book.goodreads_id, to_shelf.name))
            Library.renderBooks(plugin, data, from_shelf)
        end)
    end)
end

function Library.searchAndAdd(plugin, data)
    local dialog
    dialog = InputDialog:new{
        title = _("Search Goodreads"),
        input = "",
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    Library.runSearch(plugin, data, query)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Library.runSearch(plugin, data, query)
    if not query or query == "" then return end
    plugin:runWhenOnline(function()
        local provider = plugin:getProvider()
        plugin:runAsync(function()
            local completed, result = plugin:runInBackground(_("Searching Goodreads…"), function()
                return Resolver.resolve({
                    provider = provider,
                    ignore_mapping = true,
                    no_cache = true,
                    query = query,
                })
            end)
            if completed == false or not result then return end
            local candidates = result.candidates or {}
            if #candidates == 0 then
                Widgets.notify(_("No matches"))
                return
            end
            Widgets.candidateDialog(candidates, function(candidate)
                Library.chooseShelfFor(plugin, data, candidate)
            end, { title = _("Search results") })
        end)
    end)
end

function Library.chooseShelfFor(plugin, data, candidate)
    local dialog
    local buttons = {}
    local shelves = (data and data.shelves) or FALLBACK_SHELVES
    for i = 1, #shelves do
        local shelf = shelves[i]
        buttons[#buttons + 1] = { {
            text = shelf.name,
            callback = function()
                UIManager:close(dialog)
                Library.addToShelf(plugin, data, candidate, shelf)
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    } }
    dialog = ButtonDialog:new{
        title = candidate.title or _("Add to shelf"),
        buttons = buttons,
        width_factor = 0.9,
    }
    UIManager:show(dialog)
end

function Library.addToShelf(plugin, data, candidate, shelf)
    plugin:runWhenOnline(function()
        local provider = plugin:getProvider()
        plugin:runAsync(function()
            local completed, ok = plugin:runInBackground(_("Adding to Goodreads…"), function()
                if provider.add_to_shelf then
                    return provider:add_to_shelf(candidate.goodreads_id, shelf.slug)
                end
                return false
            end)
            if completed == false then return end
            if not ok then
                Widgets.notify(_("Update failed"))
                return
            end
            if shelf.books ~= nil then
                table.insert(shelf.books, {
                    goodreads_id = tostring(candidate.goodreads_id),
                    title = candidate.title,
                })
            end
            if shelf.count then shelf.count = shelf.count + 1 end
            Widgets.notify(string.format("%s · %s", candidate.title or candidate.goodreads_id,
                shelf.name))
            if plugin._library_menu then Library.renderShelves(plugin, data) end
        end)
    end)
end

return Library
