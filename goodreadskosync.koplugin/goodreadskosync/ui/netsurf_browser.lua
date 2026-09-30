--[[--
NetSurf browser view (generic Browser UI display component).

Displays the bitmap returned by a BrowserEngine through KOReader widgets and
routes taps/swipes to the engine's hitmap and scroll. It knows nothing about
NetSurf specifics: it asks the Browser Host for an engine and uses only the
BrowserEngine contract. CRE is untouched and remains the fallback.

@module koplugin.goodreads.ui.netsurf_browser
--]]

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")

local Frame = require("goodreadskosync.browse.frame")
local Host = require("goodreadskosync.browser.host")
local Logging = require("goodreadskosync.logging")

local NetSurfBrowser = InputContainer:extend{}

function NetSurfBrowser:init()
    local screen = Device.screen
    self.width = screen:getWidth()
    self.height = screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.viewport = Host.viewport(self.width, self.height, {
        dpi = screen.getDPI and screen:getDPI() or nil,
        scale = 1,
    })

    self.title = ""
    self.url = ""
    self.hits = {}
    self.scroll_y = 0
    self.scroll_h = self.height
    self._bb = nil

    local ctx = self.ctx or {}
    local engine, err = Host.create_engine(
        ctx.engine_name or Host.NETSURF, {
            bin = ctx.bin,
            cookie_file = ctx.cookie_file,
            platform = ctx.platform,
            viewport = self.viewport,
        })
    self.engine = engine
    self.error = err

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
end

-- Build a KOReader BB8 from an engine frame (raw 8-bit grayscale bytes).
-- BB8 stores one byte per pixel, so a straight memcpy is exact and fast.
function NetSurfBrowser:_to_bb(frame)
    local bb = Blitbuffer.new(frame.width, frame.height, Blitbuffer.TYPE_BB8)
    local pixels = frame.bitmap or ""
    local n = frame.width * frame.height
    if #pixels >= n and bb.data then
        ffi.copy(bb.data, pixels, n)
    else
        for y = 0, frame.height - 1 do
            local row = y * frame.width
            for x = 0, frame.width - 1 do
                local v = pixels:byte(row + x + 1) or 255
                bb:setPixel(x, y, Blitbuffer.Color8(v))
            end
        end
    end
    return bb
end

-- Pull the latest frame from the engine and refresh the displayed bitmap.
function NetSurfBrowser:_update()
    if not self.engine then return false, self.error end
    local frame = self.engine:render()
    if not Frame.is_valid(frame) then return false, "bad frame" end
    self.title = self.engine:title()
    self.url = self.engine:url()
    self.hits = frame.hits or {}
    self.scroll_y = frame.scroll_y or 0
    self.scroll_h = frame.scroll_h or frame.height
    self.last_frame = frame
    self._bb = self:_to_bb(frame)
    return true
end

-- load(url, cookie_header) -> ok, err. Invoked through the Browser Host engine.
function NetSurfBrowser:load(url, cookie_header)
    if not self.engine then
        return false, self.error or "no engine"
    end
    local ok, err = self.engine:load(url, cookie_header, self.viewport)
    if not ok then
        Logging.trace("netsurf_browser: load failed ", tostring(err))
        return false, err
    end
    return self:_update()
end

function NetSurfBrowser:goBack()
    if self.engine and self.engine:back() then return self:_update() end
    return false
end

function NetSurfBrowser:goForward()
    if self.engine and self.engine:forward() then return self:_update() end
    return false
end

function NetSurfBrowser:reload()
    if self.engine and self.engine:reload() then
        -- reload() returns via _invoke; refresh from the render result.
        return self:_update()
    end
    return false
end

function NetSurfBrowser:paintTo(bb, x, y)
    if self._bb then
        self._bb:paintTo(bb, x, y)
    end
end

function NetSurfBrowser:onTap(_, ges)
    if not self.engine then return true end
    local ok, action = self.engine:tap(ges.pos.x, ges.pos.y)
    if ok then
        Logging.trace("netsurf_browser: tap -> ", tostring(action), " url=", self.engine:url())
        self:_update()
    end
    UIManager:setDirty(self, "ui")
    return true
end

function NetSurfBrowser:onSwipe(_, ges)
    if not self.engine then return true end
    local amount = math.floor(self.height * 0.8)
    local dy = 0
    if ges.direction == "north" then dy = amount
    elseif ges.direction == "south" then dy = -amount end
    if dy ~= 0 then
        self.engine:scroll(0, dy)
        self:_update()
    end
    UIManager:setDirty(self, "ui")
    return true
end

function NetSurfBrowser:onCloseWidget()
    self._bb = nil
end

return NetSurfBrowser
