--[[--
Current-book status screen.

@module koplugin.goodreads.ui.status
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Status = {}

local function formatAgo(timestamp)
    if not timestamp then return _("never") end
    local seconds = os.time() - timestamp
    if seconds < 60 then return _("just now") end
    if seconds < 3600 then
        return string.format(_("%d minutes ago"), math.floor(seconds / 60))
    end
    if seconds < 86400 then
        return string.format(_("%d hours ago"), math.floor(seconds / 3600))
    end
    return os.date("%Y-%m-%d", timestamp)
end

local SHELF_LABEL = {
    want_to_read = "Want to Read",
    currently_reading = "Currently Reading",
    read = "Read",
    did_not_finish = "Did Not Finish",
}

-- data = {
--   title, author, goodreads_title, goodreads_id,
--   percent, cloud_percent, shelf, rating, last_sync, status_text
-- }
-- handlers = { sync_now, rate, change_book }
function Status.show(data, handlers)
    handlers = handlers or {}
    local dialog
    local lines = { _("Goodreads KO Sync"), "" }
    lines[#lines + 1] = string.format("%s: %s", _("Book"), data.title or _("unknown"))
    if data.author then
        lines[#lines + 1] = string.format("%s: %s", _("Author"), data.author)
    end
    if data.goodreads_title then
        lines[#lines + 1] = string.format("%s: %s", _("Goodreads"), data.goodreads_title)
    end
    if data.percent ~= nil then
        lines[#lines + 1] = string.format("%s: %d%%", _("Local progress"), data.percent)
    end
    if data.cloud_percent ~= nil then
        lines[#lines + 1] = string.format("%s: %d%%", _("Goodreads progress"), data.cloud_percent)
    end
    if data.shelf then
        lines[#lines + 1] = string.format("%s: %s", _("Shelf"),
            _(SHELF_LABEL[data.shelf] or data.shelf))
    end
    if data.rating then
        lines[#lines + 1] = string.format("%s: %d/5", _("Rating"), data.rating)
    end
    lines[#lines + 1] = string.format("%s: %s", _("Last sync"), formatAgo(data.last_sync))
    lines[#lines + 1] = string.format("%s: %s", _("Status"), data.status_text or _("unknown"))

    local buttons = {
        { {
            text = _("Sync now"),
            callback = function()
                UIManager:close(dialog)
                if handlers.sync_now then handlers.sync_now() end
            end,
        } },
        { {
            text = _("Rate this book"),
            callback = function()
                UIManager:close(dialog)
                if handlers.rate then handlers.rate() end
            end,
        } },
        { {
            text = _("Find book"),
            callback = function()
                UIManager:close(dialog)
                if handlers.change_book then handlers.change_book() end
            end,
        } },
    }
    buttons[#buttons + 1] = { {
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    } }

    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        buttons = buttons,
        width_factor = 0.9,
    }
    UIManager:show(dialog)
end

Status.formatAgo = formatAgo

return Status
