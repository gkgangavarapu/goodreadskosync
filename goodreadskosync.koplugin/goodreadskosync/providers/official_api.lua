--[[--
Official API provider (unavailable placeholder).

Goodreads retired its public API in December 2020. This provider implements the
interface and reports itself unavailable so that, should an official API ever
return, it can be plugged in without changing the resolver, sync engine, UI, or
storage.

@module koplugin.goodreads.providers.official_api
--]]

local Base = require("goodreadskosync.providers.base")
local Constants = require("goodreadskosync.constants")

local OfficialApi = Base:extend({
    id = "official_api",
    display_name = "Official Goodreads API",
})

function OfficialApi:is_available()
    return false, "no official Goodreads API is currently available"
end

function OfficialApi:get_capabilities()
    return {
        search = true,
        shelves = true,
        progress = true,
        completion = true,
        rating = true,
        authentication = true,
    }
end

function OfficialApi:authenticate()
    return false, Constants.ERROR.PROVIDER_UNAVAILABLE
end

return OfficialApi
