--[[--
Wide, fixed-width toast.

KOReader's stock Notification sizes its box to the text, so short messages get a
cramped box. This subclasses Notification and keeps its tap-through, auto-timeout
and stacking behaviour, but forces a comfortable fixed width (default 92% of the
screen) so every toast is equally readable.

@module koplugin.goodreads.ui.toast
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Notification = require("ui/widget/notification")
local RectSpan = require("ui/widget/rectspan")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Screen = Device.screen

local Toast = Notification:extend{
    width_factor = 0.92, -- fraction of screen width
    alignment = "left",
}

function Toast:init()
    self.face = self.face or Font:getFace("infofont")
    local outer = Size.margin.default
    local pad = Size.padding.default

    local card_width = self.width
        or math.floor(Screen:getWidth() * (self.width_factor or 0.92))
    local text_width = card_width - 2 * pad
    if text_width < 1 then text_width = card_width end

    local text_widget = TextBoxWidget:new{
        text = self.text,
        face = self.face,
        width = text_width,
        alignment = self.alignment or "left",
    }
    local text_size = text_widget:getSize()

    -- A fixed-width, centered text area makes the card the same width for short
    -- and long messages alike.
    local center = CenterContainer:new{
        dimen = Geom:new{ w = text_width, h = text_size.h },
    }
    center[1] = text_widget

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        margin = outer,
        padding = pad,
    }
    self.frame[1] = center

    self:_cleanShownStack()
    table.insert(Notification._shown_list, UIManager:getTime())
    self._shown_idx = #Notification._shown_list

    local notif_height = self.frame:getSize().h
    local group = VerticalGroup:new{ align = "center" }
    group[1] = RectSpan:new{
        width = Screen:getWidth(),
        height = notif_height * (self._shown_idx - 1) + outer,
    }
    group[2] = self.frame
    self[1] = group
end

return Toast
