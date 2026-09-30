--[[--
Notes to Goodreads: highlight-dialog integration and composing/queueing a note.

These functions are mixed into the plugin as methods, so `self` is the plugin
instance (they call other plugin methods like `self:currentMapping()`).

@module koplugin.goodreads.ui.notes
--]]

local Queue = require("goodreadskosync.sync.queue")
local UIManager = require("ui/uimanager")
local Util = require("goodreadskosync.util")
local Widgets = require("goodreadskosync.ui.widgets")
local _ = require("gettext")

local Notes = {}

-- "Add note to Goodreads" entry in the highlight dialog.
function Notes:registerHighlight()
    if not self.ui or not self.ui.highlight
        or type(self.ui.highlight.addToHighlightDialog) ~= "function" then
        return
    end
    self.ui.highlight:removeFromHighlightDialog("goodreads_note")
    self.ui.highlight:addToHighlightDialog("goodreads_note", function(this)
        return {
            text = _("Add note to Goodreads"),
            enabled_func = function()
                return self:hasDocument() and self:currentMapping() ~= nil
            end,
            callback = function()
                local selected = this.selected_text
                self:promptNote(selected and selected.text or "")
                this:onClose()
            end,
        }
    end)
end

function Notes:unregisterHighlight()
    if self.ui and self.ui.highlight
        and type(self.ui.highlight.removeFromHighlightDialog) == "function" then
        self.ui.highlight:removeFromHighlightDialog("goodreads_note")
    end
end

function Notes:promptNote(text)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Add a note to Goodreads"),
        input = text or "",
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Post"),
                callback = function()
                    local note = dialog:getInputText()
                    UIManager:close(dialog)
                    self:postNote(note)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Notes:postNote(note)
    if not note or note == "" then return end
    local mapping, identity = self:currentMapping()
    if not mapping or not mapping.goodreads_id then return end
    local local_key = identity and identity.local_key
    local percent = self:currentPercent() or 0
    local t = Util.shortTitle(mapping.title or (identity and identity.title))
    local payload = {
        type = "note", note = note, percent = percent,
        value = percent, unit = "percent",
    }

    -- Persist locally first so a note is never lost, then flush in creation
    -- order. Notes are not idempotent, so each gets its own queue slot and a
    -- later note can never overwrite an earlier one.
    Queue.enqueue({
        operation = "note",
        book_id = mapping.goodreads_id,
        local_key = local_key,
        payload = payload,
    }, { unique = true })

    if not self:isOnline() then
        Widgets.notify(t and string.format(_("%s · Note saved · will post when online"), t)
            or _("Note saved · will post when online"), 3, "note")
        return
    end
    -- Posting (and its toast) is handled by the queue flush.
    self:processQueue()
end

return Notes
