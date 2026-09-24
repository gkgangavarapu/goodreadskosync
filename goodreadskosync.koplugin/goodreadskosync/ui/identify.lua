--[[--
Candidate selection and unidentified-book UI.

@module koplugin.goodreads.ui.identify
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Widgets = require("goodreadskosync.ui.widgets")

local Identify = {}

-- Show the candidate list for a resolution result.
function Identify.showCandidates(identity, candidates, on_select, on_manual_search)
    local title = _("Goodreads KO Sync\nWhich book is this?")
    if identity and identity.title then
        title = string.format(_("Goodreads KO Sync\n%s"), identity.title)
    end
    Widgets.candidateDialog(candidates, on_select, {
        title = title,
        on_manual_search = on_manual_search,
    })
end

-- Show the unidentified-book screen.
-- handlers = { find_manually, find, snooze, cancel }
function Identify.showUnidentified(identity, handlers)
    handlers = handlers or {}
    local dialog
    local lines = { _("Goodreads KO Sync"), "", _("Couldn't link this book."), "" }
    if identity then
        lines[#lines + 1] = string.format("%s: %s", _("Title"),
            identity.title or _("unknown"))
        lines[#lines + 1] = string.format("%s: %s", _("Author"),
            identity.primary_author or _("unknown"))
        if identity.isbn13 then
            lines[#lines + 1] = string.format("%s: %s", _("ISBN"), identity.isbn13)
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("Find it manually with a title, author, ISBN, or Goodreads ID, or let the plugin find it automatically.")
    local buttons = {}
    local function add(text, callback)
        buttons[#buttons + 1] = { {
            text = text,
            callback = function()
                UIManager:close(dialog)
                if callback then callback() end
            end,
        } }
    end
    -- Manual first, then automatic. "Find manually" opens the single shared
    -- prompt (title/author/ISBN/Goodreads ID) used everywhere in the plugin.
    add(_("Find manually"), handlers.find_manually)
    add(_("Find automatically"), handlers.find)
    add(_("Ask me in an hour"), handlers.snooze)
    add(_("Not now"), handlers.cancel)

    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        buttons = buttons,
        width_factor = 0.9,
    }
    UIManager:show(dialog)
end

return Identify
