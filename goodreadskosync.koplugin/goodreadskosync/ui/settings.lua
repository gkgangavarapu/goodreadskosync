--[[--
Settings menu construction.

Sync behaviour is defined by a single preset; the remaining options are simple
toggles that are not part of sync cadence. Reads and writes go through the
plugin instance so persistence stays in one place.

@module koplugin.goodreads.ui.settings
--]]

local Presets = require("goodreadskosync.sync.presets")
local Widgets = require("goodreadskosync.ui.widgets")
local _ = require("gettext")

local SettingsUI = {}

local PRESET_LABELS = {
    fastest = _("Fastest"),
    faster = _("Faster"),
    medium = _("Medium"),
    relaxed = _("Relaxed"),
}

local PRESET_HELP = {
    fastest = _("Updates frequently as you read; highest battery use."),
    faster = _("Updates as you read, a little less often."),
    medium = _("Updates on open/close and every 15 minutes."),
    relaxed = _("Updates only on open/close and reconnect; lowest battery use."),
}

function SettingsUI.build(plugin)
    local function checked(key)
        return function() return plugin:getSetting(key) end
    end
    local function toggle(key)
        return function()
            plugin:setSetting(key, not plugin:getSetting(key))
        end
    end

    local preset_items = {}
    -- NOTE: use an index loop, not `for _, id`: the loop variable `_` would
    -- shadow the module-level gettext `_` inside the callbacks below.
    for i = 1, #Presets.ORDER do
        local id = Presets.ORDER[i]
        preset_items[#preset_items + 1] = {
            text = PRESET_LABELS[id],
            help_text = PRESET_HELP[id],
            radio = true,
            checked_func = function()
                return plugin:getSetting("sync_preset") == id
            end,
            callback = function()
                plugin:applyPreset(id)
                Widgets.message(string.format(_("%s preset: %s"),
                    PRESET_LABELS[id], PRESET_HELP[id]), 3)
            end,
        }
    end

    return {
        {
            text = _("Sync preset"),
            help_text = _("One choice sets how often reading progress and shelves sync."),
            sub_item_table = preset_items,
        },
        {
            text = _("Link books automatically"),
            help_text = _("Link an opened book to the best Goodreads match and show a small notification. Change it anytime from This book → Change linked book."),
            checked_func = checked("auto_link"),
            callback = toggle("auto_link"),
        },
        {
            text = _("Mark new books as Currently Reading"),
            help_text = _("When a book is first linked, add it to Currently Reading on Goodreads immediately."),
            checked_func = checked("mark_started_immediately"),
            callback = toggle("mark_started_immediately"),
        },
        {
            text = _("Remember password (testing)"),
            help_text = _([[
Stores your Goodreads password in plain text on this device so you do not have to re-enter it every time the session expires.

This is a testing convenience only: KOReader has no secure keystore. Turn it off (or use "Forget saved password") to remove the saved value.]]),
            checked_func = checked("remember_password"),
            callback = function()
                local enabled = not plugin:getSetting("remember_password")
                plugin:setSetting("remember_password", enabled)
                if not enabled then
                    require("goodreadskosync.auth.credentials").clear()
                end
            end,
        },
        {
            text = _("Check for updates automatically"),
            help_text = _("Check GitHub Releases about once a day and offer to update. You can also check any time from More → Check for updates."),
            checked_func = checked("auto_update_check"),
            callback = toggle("auto_update_check"),
        },
        {
            text = _("Diagnostic logging (support)"),
            help_text = _("Write detailed sync logs to the plugin's login.log for troubleshooting. Off by default."),
            checked_func = checked("logging"),
            callback = function()
                local enabled = not plugin:getSetting("logging")
                plugin:setSetting("logging", enabled)
                require("goodreadskosync.logging").setEnabled(enabled)
                Widgets.notify(enabled and _("Logging on") or _("Logging off"))
            end,
        },
    }
end

return SettingsUI
