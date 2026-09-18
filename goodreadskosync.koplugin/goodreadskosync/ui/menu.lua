--[[--
Main-menu construction for the plugin.

Mixed into the plugin as methods (`self` is the plugin instance).

@module koplugin.goodreads.ui.menu
--]]

local Auth = require("goodreadskosync.auth.manager")
local Constants = require("goodreadskosync.constants")
local InfoMessage = require("ui/widget/infomessage")
local Queue = require("goodreadskosync.sync.queue")
local SettingsUI = require("goodreadskosync.ui.settings")
local State = require("goodreadskosync.sync.state")
local SupportUI = require("goodreadskosync.ui.support")
local UIManager = require("ui/uimanager")
local Update = require("goodreadskosync.update")
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
        text = _("Test connection"),
        callback = function() self:testConnection() end,
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
            text = _("Support this project"),
            callback = function() SupportUI.show() end,
        },
        {
            text = _("Account"),
            sub_item_table_func = function() return self:accountMenuItems() end,
        },
        {
            text = _("This book"),
            sub_item_table = {
                {
                    text = _("Find on Goodreads"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function() self:identifyCurrent({ no_cache = true }) end,
                },
                {
                    text = _("Change linked book"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function()
                        self:identifyCurrent({ ignore_mapping = true, no_cache = true, choose = true })
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
            text = _("Settings"),
            sub_item_table_func = function() return SettingsUI.build(self) end,
        },
        {
            text = _("More"),
            sub_item_table = {
                { text = _("Sync status"), callback = function() self:showDiagnostics() end },
                { text = _("Waiting to sync"), callback = function() self:showQueue() end },
                { text = _("Check for updates"), callback = function() self:checkForUpdates(true) end },
                {
                    text_func = function()
                        return string.format(_("Version: %s"), Constants.VERSION)
                    end,
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Goodreads KO Sync v%s\n%s"),
                                Constants.VERSION, Update.PAGE_URL),
                            timeout = 10,
                        })
                    end,
                },
                {
                    text = _("Clear failed syncs"),
                    callback = function()
                        Queue.clearFailed()
                        Widgets.message(_("Failed syncs cleared."))
                    end,
                },
            },
        },
    }
end

return Menu
