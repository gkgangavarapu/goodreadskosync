--[[--
Main-menu construction for the plugin.

Mixed into the plugin as methods (`self` is the plugin instance).

@module koplugin.goodreads.ui.menu
--]]

local Auth = require("goodreadskosync.auth.manager")
local Constants = require("goodreadskosync.constants")
local Queue = require("goodreadskosync.sync.queue")
local SettingsUI = require("goodreadskosync.ui.settings")
local State = require("goodreadskosync.sync.state")
local SupportUI = require("goodreadskosync.ui.support")
local Widgets = require("goodreadskosync.ui.widgets")
local _ = require("gettext")

local Menu = {}

function Menu:accountMenuItems()
    local items = {}
    if Auth.is_authenticated() then
        items[#items + 1] = {
            text = _("Log out"),
            callback = function()
                Widgets.confirm(_("Sign out of Goodreads?"),
                    function() self:logout() end, _("Sign out"))
            end,
        }
    else
        items[#items + 1] = {
            text = _("Log in"),
            callback = function() self:login() end,
        }
    end
    items[#items + 1] = {
        text = _("Account status"),
        callback = function() self:showAccount() end,
    }
    items[#items + 1] = {
        text = _("Forget saved password"),
        callback = function() self:forgetCredentials() end,
    }
    return items
end

-- Shelf chooser for the current book. The checked state is read fresh so the
-- radio updates as soon as the user picks one.
function Menu:setStatusMenuItems()
    local local_key = self:currentIdentity().local_key
    local options = {
        { Constants.SHELF.WANT_TO_READ, _("Want to Read") },
        { Constants.SHELF.CURRENTLY_READING, _("Currently Reading") },
        { Constants.SHELF.READ, _("Read") },
        { Constants.SHELF.DID_NOT_FINISH, _("Did Not Finish") },
    }
    local items = {}
    for i = 1, #options do
        local shelf = options[i][1]
        items[#items + 1] = {
            text = options[i][2],
            radio = true,
            checked_func = function() return State.get(local_key).shelf == shelf end,
            callback = function() self:setShelf(shelf) end,
        }
    end
    return items
end

-- "Find on Goodreads" submenu: manual search first, then automatic. The manual
-- entry opens the single shared prompt so the user can type a
-- title/author/ISBN/Goodreads ID themselves.
function Menu:findOnGoodreadsMenuItems()
    return {
        {
            text = _("Find manually"),
            enabled_func = function() return self:hasDocument() end,
            callback = function() self:promptFindBook() end,
        },
        {
            text = _("Find automatically"),
            enabled_func = function() return self:hasDocument() end,
            callback = function() self:identifyCurrent({ no_cache = true }) end,
        },
    }
end

function Menu:buildMenu()
    return {
        {
            text = _("Sync now"),
            callback = function() self:syncNow() end,
        },
        {
            text = _("Set status on Goodreads"),
            enabled_func = function() return self:hasDocument() end,
            sub_item_table_func = function() return self:setStatusMenuItems() end,
        },
        {
            text = _("This book"),
            sub_item_table = {
                {
                    text = _("Find on Goodreads"),
                    enabled_func = function() return self:hasDocument() end,
                    sub_item_table_func = function()
                        return self:findOnGoodreadsMenuItems()
                    end,
                },
                {
                    text = _("Rate this book"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function() self:rateCurrentBook() end,
                },
                {
                    text = _("Forget link"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function()
                        Widgets.confirm(_("Forget the Goodreads link for this book?"),
                            function() self:forgetMapping() end, _("Forget"))
                    end,
                },
                {
                    text = _("Sync this book automatically"),
                    enabled_func = function() return self:hasDocument() end,
                    checked_func = function()
                        local identity = self:currentIdentity()
                        return self:isBookSyncEnabled(identity.local_key)
                    end,
                    callback = function()
                        local identity = self:currentIdentity()
                        self:setBookSetting(identity.local_key, "sync",
                            not self:isBookSyncEnabled(identity.local_key))
                    end,
                },
                {
                    text = _("Book status"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function() self:showStatus() end,
                },
            },
        },
        {
            text = _("Browse Goodreads…"),
            callback = function() self:openGoodreadsBrowser() end,
        },
        {
            text = _("Reading"),
            sub_item_table = {
                {
                    text = _("Reading challenge"),
                    callback = function() self:showReadingChallenge() end,
                },
                {
                    text = _("Change reading goal…"),
                    callback = function() self:promptReadingGoal() end,
                },
                {
                    text = _("Reading stats"),
                    callback = function() self:showReadingStats() end,
                },
            },
        },
        {
            text = _("Test connection"),
            callback = function() self:testConnection() end,
        },
        {
            -- Tapping the version checks GitHub for a newer release; when one is
            -- known the label tells the user to tap to update.
            text_func = function()
                local available = self:getSetting("update_available_version")
                if available and available ~= "" then
                    return string.format(
                        _("Update available: %s · tap to update"), available)
                end
                local label = Constants.VERSION
                local channel = self.updateChannel and self:updateChannel()
                    or Constants.CHANNEL
                if channel and channel ~= "" and channel ~= "stable" then
                    label = label .. " (" .. channel .. ")"
                end
                return string.format(
                    _("Version: %s · tap to check for updates"), label)
            end,
            callback = function() self:checkForUpdates(true) end,
        },
        {
            text = _("More"),
            sub_item_table = {
                {
                    text = _("Account"),
                    sub_item_table_func = function() return self:accountMenuItems() end,
                },
                {
                    text = _("Settings"),
                    sub_item_table_func = function() return SettingsUI.build(self) end,
                },
                { text = _("Sync status"), callback = function() self:showDiagnostics() end },
                { text = _("Waiting to sync"), callback = function() self:showQueue() end },
                {
                    text = _("Retry failed syncs"),
                    callback = function() self:retryFailedSyncs() end,
                },
                {
                    text = _("Clear failed syncs"),
                    callback = function()
                        Queue.clearFailed()
                        Widgets.message(_("Failed syncs cleared."))
                    end,
                },
                {
                    text = _("Browser engine (dev)"),
                    sub_item_table = {
                        {
                            text = _("CRE (default)"),
                            radio = true,
                            checked_func = function()
                                return self:getSetting("browser_engine") ~= "netsurf"
                            end,
                            callback = function()
                                self:setSetting("browser_engine", "cre")
                            end,
                        },
                        {
                            text = _("NetSurf (needs helper binary)"),
                            radio = true,
                            checked_func = function()
                                return self:getSetting("browser_engine") == "netsurf"
                            end,
                            callback = function()
                                self:setSetting("browser_engine", "netsurf")
                            end,
                        },
                        {
                            text_func = function()
                                local engine, reason = self:resolveBrowserEngine()
                                return string.format(_("Active engine: %s (%s)"),
                                    tostring(engine), tostring(reason))
                            end,
                            callback = function()
                                local engine, reason = self:resolveBrowserEngine()
                                Widgets.message(string.format(
                                    _("Engine: %s — %s"), tostring(engine),
                                    tostring(reason)), 5)
                            end,
                        },
                        {
                            text = _("Open NetSurf browser (dev)"),
                            callback = function()
                                self:openNetSurfBrowser()
                            end,
                        },
                    },
                },
            },
        },
        -- Kept at the bottom, out of the way.
        {
            text = _("Support this project"),
            callback = function() SupportUI.show() end,
        },
    }
end

return Menu
