--[[--
Manual book-search prompt (single entry point).

One dialog is used everywhere the user links a book by hand, so "couldn't find
it", "change linked book" and "find manually" all behave the same way.

@module koplugin.goodreads.ui.search
--]]

local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local SearchUI = {}

-- Prompt for a title, author, ISBN, or Goodreads ID.
-- `on_submit(query)` is called with the non-empty entered value.
function SearchUI.manual(on_submit)
    local dialog
    dialog = InputDialog:new{
        title = _("Find book on Goodreads"),
        description = _("Enter a title, author, ISBN, or Goodreads ID."),
        input = "",
        buttons = { {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                callback = function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    if value and value ~= "" then on_submit(value) end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return SearchUI
