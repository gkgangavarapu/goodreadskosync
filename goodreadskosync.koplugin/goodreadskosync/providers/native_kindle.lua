--[[--
Native Kindle provider (detection + interface only).

This provider deliberately does NOT reimplement the Kindle native Goodreads
integration in this pass. It only detects whether the device could support it
and exposes the three independent native paths the real implementation will
use, per the architecture of koreader-goodreads-native:

  * shelves      -> KAF/LIPC shelf action
  * progress     -> native Grok progress request
  * rating       -> native Grok rating property

Keeping the paths separate here means a future implementation can fill them in
without touching the resolver, sync engine, UI, or storage.

@module koplugin.goodreads.providers.native_kindle
--]]

local Base = require("goodreadskosync.providers.base")
local Constants = require("goodreadskosync.constants")
local Logging = require("goodreadskosync.logging")

local NativeKindle = Base:extend({
    id = "native_kindle",
    display_name = "Native Kindle",
})

local LIPC_HASH_TOOL = "/usr/bin/lipc-hash-prop"

local function command_first_line(command)
    local pipe = io.popen(command .. " 2>/dev/null", "r")
    if not pipe then return nil end
    local line = pipe:read("*l")
    pipe:close()
    return line
end

function NativeKindle:get_firmware_version()
    local version = command_first_line("lipc-get-prop com.lab126.system version")
    if not version then
        local file = io.open("/etc/version", "r")
        if file then
            version = file:read("*l")
            file:close()
        end
    end
    return version
end

-- A device is only "available" when it is a Kindle, the LIPC tool exists, and
-- the native framework responds. Anything else must never attempt native calls.
function NativeKindle:is_available()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table"
        or type(Device.isKindle) ~= "function" or not Device:isKindle() then
        return false, "not a Kindle device"
    end
    local lipc = io.open(LIPC_HASH_TOOL, "r")
    if not lipc then
        return false, "Kindle LIPC tools unavailable"
    end
    lipc:close()
    local version = self:get_firmware_version()
    if not version then
        return false, "Kindle firmware version could not be determined"
    end
    Logging.info("native_kindle: firmware", version)
    return true, "Kindle firmware " .. version
end

-- Detection is implemented; the native shelf/progress/rating paths are not
-- implemented in this pass, so automatic selection must skip this provider.
function NativeKindle:is_implemented()
    return false
end

function NativeKindle:get_capabilities()
    return {
        search = false,
        shelves = true,
        progress = true,
        completion = true,
        rating = true,
        authentication = true, -- uses the device's linked account
    }
end

function NativeKindle:authenticate()
    local available, reason = self:is_available()
    if not available then
        return false, Constants.ERROR.PROVIDER_UNAVAILABLE
    end
    -- The native path relies on the Kindle's own linked Goodreads account;
    -- there is no token to obtain here.
    return true, { username = "kindle-native", display_name = reason }
end

function NativeKindle:get_account()
    local available = self:is_available()
    if not available then return nil, Constants.ERROR.PROVIDER_UNAVAILABLE end
    return { username = "kindle-native", display_name = "Kindle linked account" }
end

-- The three native paths, kept independent. Not implemented in this pass.
function NativeKindle:_shelf_action()
    return false, Constants.ERROR.UNSUPPORTED
end

function NativeKindle:_progress_request()
    return false, Constants.ERROR.UNSUPPORTED
end

function NativeKindle:_rating_request()
    return false, Constants.ERROR.UNSUPPORTED
end

function NativeKindle:set_shelf() return self:_shelf_action() end
function NativeKindle:mark_read() return self:_shelf_action() end
function NativeKindle:mark_currently_reading() return self:_shelf_action() end
function NativeKindle:mark_want_to_read() return self:_shelf_action() end
function NativeKindle:update_progress() return self:_progress_request() end
function NativeKindle:set_rating() return self:_rating_request() end
function NativeKindle:clear_rating() return self:_rating_request() end

function NativeKindle:search_books()
    -- Native Kindle Goodreads does not expose a metadata search.
    return nil, Constants.ERROR.UNSUPPORTED
end

function NativeKindle:get_shelf() return nil, Constants.ERROR.UNSUPPORTED end
function NativeKindle:get_book() return nil, Constants.ERROR.UNSUPPORTED end

return NativeKindle
