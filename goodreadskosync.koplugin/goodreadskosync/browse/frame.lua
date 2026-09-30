--[[--
Frame helpers: convert a BrowserEngine render result into pixel data.

The engine returns `render().bitmap` as raw 8-bit grayscale bytes, row-major,
`width * height` long (the payload of a P5 PGM). These helpers are pure so they
can be unit-tested; the KOReader Blitbuffer construction lives in the UI layer.

@module koplugin.goodreads.browse.frame
--]]

local Frame = {}

-- Byte value at (x, y); 255 (white) outside the buffer.
function Frame.gray_at(pixels, width, x, y)
    if type(pixels) ~= "string" or not width then return 255 end
    local idx = (y * width + x) + 1
    return pixels:byte(idx) or 255
end

-- Re-encode a frame as a P5 PGM string (used for diagnostics/tests).
function Frame.to_pgm(width, height, pixels)
    return string.format("P5\n%d %d\n255\n", width, height) .. (pixels or "")
end

-- True when the frame looks well-formed for the given viewport.
function Frame.is_valid(frame)
    if type(frame) ~= "table" then return false end
    local w, h = tonumber(frame.width), tonumber(frame.height)
    if not (w and h and w > 0 and h > 0) then return false end
    return #(frame.bitmap or "") >= w * h
end

return Frame
