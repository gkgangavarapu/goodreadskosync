--[[--
Support dialog.

Shows a short message, a QR code for the Buy Me a Coffee page, and the URL as
plain text. The dialog is only shown when the user opens More -> Support this
project, so it never appears while reading.

The QR is drawn directly from a precomputed matrix (see ui/support_qr.lua): no
network access, no external service, and no dependency on KOReader's image or QR
widgets, so it renders on every KOReader version.

@module koplugin.goodreads.ui.support
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Logging = require("goodreadskosync.logging")
local Size = require("ui/size")
local SupportQR = require("goodreadskosync.ui.support_qr")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local _ = require("gettext")

local Screen = Device.screen

-- Paints the precomputed matrix onto whatever blitbuffer it is given. This
-- avoids ImageWidget and its scaling path entirely, which is what made the QR
-- invisible on some KOReader builds.
local QrWidget = Widget:extend{}

function QrWidget:init()
    self.modules = SupportQR.modules
    self.rows = SupportQR.rows
    self.quiet = self.quiet or 4
    self.module_size = self.module_size or 1
    self.total = self.modules + 2 * self.quiet
end

function QrWidget:getSize()
    local size = self.total * self.module_size
    return { w = size, h = size }
end

function QrWidget:paintTo(bb, x, y)
    local ms = self.module_size
    local quiet = self.quiet
    local modules = self.modules
    local size = self.total * ms

    bb:paintRect(x, y, size, size, Blitbuffer.COLOR_WHITE)
    for r = 1, modules do
        local row = self.rows[r]
        local py = y + (quiet + r - 1) * ms
        for c = 1, modules do
            if row:sub(c, c) == "1" then
                bb:paintRect(x + (quiet + c - 1) * ms, py, ms, ms, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

local Support = {}

Support.URL = SupportQR.url

local MESSAGE = _("If you find this plugin useful, you can support its continued development.")
local HINT = _("Scan the QR code with your phone to support the project.")

local function plainText()
    return MESSAGE .. "\n\n" .. HINT .. "\n\n" .. Support.URL
end

function Support.show()
    -- Never let an unexpected rendering problem break the plugin.
    local ok, err = pcall(Support.showDialog)
    if not ok then
        Logging.error("support: failed to show dialog:", tostring(err))
        Logging.trace("support: failed to show dialog:", tostring(err))
        UIManager:show(InfoMessage:new{
            text = plainText(),
            timeout = 10,
        })
    end
end

function Support.showDialog()
    local outer_padding = Size.padding.fullscreen
    local qr_size = math.min(Screen:scaleBySize(360),
        Screen:getWidth() - 4 * outer_padding)

    local total = SupportQR.modules + 8
    local module_size = math.max(1, math.floor(qr_size / total))
    local qr_widget = QrWidget:new{
        quiet = 4,
        module_size = module_size,
    }

    -- TextBoxWidget requires a face; without one it throws in font.lua.
    local face = Font:getFace("infofont")
    local message = TextBoxWidget:new{
        text = MESSAGE,
        face = face,
        width = qr_size,
        alignment = "center",
    }
    local hint = TextBoxWidget:new{
        text = HINT,
        face = face,
        width = qr_size,
        alignment = "center",
    }
    local url = TextBoxWidget:new{
        text = Support.URL,
        face = face,
        width = qr_size,
        alignment = "center",
    }
    local qr = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        margin = 0,
        padding = outer_padding,
    }
    qr[1] = qr_widget
    local content = VerticalGroup:new{ align = "center" }
    content[1] = message
    content[2] = VerticalSpan:new{ width = Screen:scaleBySize(8) }
    content[3] = hint
    content[4] = VerticalSpan:new{ width = Screen:scaleBySize(12) }
    content[5] = qr
    content[6] = VerticalSpan:new{ width = Screen:scaleBySize(12) }
    content[7] = url

    local dialog = InputContainer:new{ modal = true }
    if Device:hasKeys() then
        dialog.key_events = { AnyKeyPressed = { { Device.input.group.Any } } }
    end
    if Device:isTouchDevice() then
        dialog.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(),
                        h = Screen:getHeight(),
                    },
                },
            },
        }
    end
    local center = CenterContainer:new{ dimen = Screen:getSize() }
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        padding = outer_padding,
    }
    frame[1] = content
    center[1] = frame
    dialog[1] = center
    dialog.onAnyKeyPressed = function(self)
        UIManager:close(self)
        return true
    end
    dialog.onTapClose = dialog.onAnyKeyPressed
    dialog.onClose = dialog.onAnyKeyPressed
    UIManager:show(dialog)
end

return Support
