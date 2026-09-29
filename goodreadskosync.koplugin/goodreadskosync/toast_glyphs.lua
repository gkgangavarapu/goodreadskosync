--[[--
Toast/banner decoration.

Toasts use a small monochrome leading glyph (dot, check, star, ...) that renders
with the fonts KOReader already bundles. Emoji are intentionally NOT used:
KOReader has no colour-emoji font, so emoji show as empty boxes on most devices.
Banners use KOReader's SVG icon set instead of a text glyph.

Style is configurable: "symbols" (default) or "none".

@module koplugin.goodreads.toast_glyphs
--]]

local ToastGlyphs = {}

local DEFAULT_STYLE = "symbols"

-- Only glyphs that render with the bundled fonts (NotoSans + FreeSans/Symbols
-- fallbacks). Keep these conservative and monochrome.
local SETS = {
    symbols = {
        default = "•", book = "•", success = "✓", warn = "!",
        fail = "✗", info = "i", star = "★", sync = "~",
        note = "*", link = "→", trophy = "★", heart = "♥",
        clock = ":", wifi = "~",
    },
}

-- KOReader SVG icons (resources/icons/mdlight) for banners.
local ICONS = {
    default = "notice-info", info = "notice-info", question = "notice-question",
    success = "check", warn = "notice-warning", fail = "notice-warning",
    star = "star.full", book = "book.opened", link = "bookmark",
    sync = "cre.render.reload",
}

local style = DEFAULT_STYLE

function ToastGlyphs.setStyle(value)
    if value == "none" or SETS[value] then
        style = value
        return true
    end
    return false
end

function ToastGlyphs.getStyle()
    return style
end

-- Glyph for a notification kind ("success", "warn", ...). Empty when disabled.
function ToastGlyphs.forKind(kind)
    if style == "none" then return "" end
    local set = SETS[style] or SETS[DEFAULT_STYLE]
    return set[kind or "default"] or set.default or ""
end

-- KOReader icon name for a banner kind.
function ToastGlyphs.icon(kind)
    return ICONS[kind or "default"] or ICONS.default
end

ToastGlyphs.STYLES = { "symbols", "none" }

return ToastGlyphs
