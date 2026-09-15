--[[--
Manual search / identifier entry dialogs.

@module koplugin.goodreads.ui.search
--]]

local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local SearchUI = {}

-- Generic text prompt. `on_submit(text)` is called with the entered value.
function SearchUI.prompt(title, initial, on_submit, submit_text)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        buttons = { {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = submit_text or _("Search"),
                callback = function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    on_submit(value)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SearchUI.show(initial, on_submit)
    SearchUI.prompt(_("Search Goodreads"), initial, on_submit)
end

return SearchUI
