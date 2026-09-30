--[[--
Shared UI widgets.

@module koplugin.goodreads.ui.widgets
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local Size = require("ui/size")
local ToastGlyphs = require("goodreadskosync.toast_glyphs")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Widgets = {}

-- Every message is prefixed so the user always knows which plugin it is from.
local BRAND = _("Goodreads KO Sync")

local function brand(text)
    local s = tostring(text or "")
    if s == "" or BRAND == "" then return s end
    return string.format("%s: %s", BRAND, s)
end

-- kind (optional) picks an icon: "success", "warn", "info", "question", ...
function Widgets.message(text, timeout, kind)
    UIManager:show(InfoMessage:new{
        text = brand(text),
        timeout = timeout or 3,
        icon = ToastGlyphs.icon(kind),
    })
end

-- Non-intrusive toast (falls back to an InfoMessage if unavailable). Repeats of
-- the same message within a couple of seconds are coalesced so multiple events
-- don't stack toasts. `kind` (optional) adds a leading glyph (emoji/symbol).
local last_notify_text, last_notify_at
function Widgets.notify(text, timeout, kind)
    -- Toasts stay quiet and unbranded: just the book/action detail.
    local body = tostring(text or "")
    if body == "" then return end
    local glyph = ToastGlyphs.forKind(kind or "default")
    local display = (glyph ~= "" and (glyph .. " " .. body)) or body
    local now = os.time()
    if display == last_notify_text and last_notify_at and now - last_notify_at < 2 then
        return
    end
    last_notify_text, last_notify_at = display, now
    -- Preferred: our wide, fixed-width toast. Falls back to the stock
    -- Notification, then to an InfoMessage, so a broken helper can't stop
    -- notifications entirely.
    local ok_toast, Toast = pcall(require, "goodreadskosync.ui.toast")
    if ok_toast and Toast then
        UIManager:show(Toast:new{
            text = display,
            timeout = timeout or 3,
            face = Font:getFace("infofont"),
        })
        return
    end
    local ok, Notification = pcall(require, "ui/widget/notification")
    if ok and Notification then
        UIManager:show(Notification:new{
            text = display,
            timeout = timeout or 3,
            face = Font:getFace("infofont"),
            margin = Size.margin.default,
            padding = Size.padding.default,
        })
    else
        UIManager:show(InfoMessage:new{
            text = display,
            timeout = timeout or 3,
            icon = ToastGlyphs.icon(kind),
        })
    end
end

-- A larger, prominent message for high-value events. Uses one of KOReader's
-- built-in icons (not an emoji) and lingers a little longer than a toast.
-- opts = { kind, icon, timeout, width, height, alignment, show_icon }
function Widgets.banner(text, opts)
    opts = opts or {}
    local msg = InfoMessage:new{
        text = brand(text),
        icon = opts.icon or ToastGlyphs.icon(opts.kind),
        show_icon = opts.show_icon ~= false,
        timeout = opts.timeout or 5,
        width = opts.width,
        height = opts.height,
        alignment = opts.alignment or "left",
    }
    UIManager:show(msg)
    return msg
end

-- "emoji" | "symbols" | "none" (see goodreadskosync.toast_glyphs).
function Widgets.setGlyphStyle(style)
    return ToastGlyphs.setStyle(style)
end

function Widgets.confirm(text, on_ok, ok_text)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = ok_text or _("OK"),
        ok_callback = on_ok,
    })
end

function Widgets.formatCandidate(candidate, index)
    local authors = candidate.authors
    if type(authors) == "table" then authors = table.concat(authors, ", ") end
    authors = authors or candidate.author or ""
    local year = candidate.publication_year and (" (" .. candidate.publication_year .. ")") or ""
    local prefix = index and ("[" .. index .. "] ") or ""
    local label = string.format("%s%s", prefix, candidate.title or _("Untitled"))
    if authors ~= "" then label = label .. "\n" .. authors end
    label = label .. year
    if candidate.score then
        label = label .. string.format("  -  %d%%", candidate.score)
    end
    return label
end

function Widgets.candidateDialog(candidates, on_select, opts)
    opts = opts or {}
    local dialog
    local buttons = {}
    for index, candidate in ipairs(candidates) do
        buttons[#buttons + 1] = { {
            text = Widgets.formatCandidate(candidate, index),
            callback = function()
                UIManager:close(dialog)
                on_select(candidate)
            end,
        } }
    end
    if opts.on_manual_search then
        buttons[#buttons + 1] = { {
            text = _("Find manually…"),
            callback = function()
                UIManager:close(dialog)
                opts.on_manual_search()
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    } }
    dialog = ButtonDialog:new{
        title = opts.title or _("Possible matches"),
        buttons = buttons,
        width_factor = 0.9,
    }
    UIManager:show(dialog)
end

function Widgets.starDialog(title, on_rate, on_skip)
    local dialog
    local row = {}
    for stars = 1, 5 do
        local value = stars
        row[#row + 1] = {
            text = string.rep("\226\152\133", stars)
                .. string.rep("\226\152\134", 5 - stars),
            callback = function()
                UIManager:close(dialog)
                on_rate(value)
            end,
        }
    end
    local buttons = {
        row,
        { {
            text = _("Skip"),
            callback = function()
                UIManager:close(dialog)
                if on_skip then on_skip() end
            end,
        } },
    }
    dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return Widgets
