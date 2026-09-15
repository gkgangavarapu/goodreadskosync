--[[--
ASIN-specific helpers.

ASINs are always an optimization, never a requirement: arbitrary sideloaded
EPUBs without an ASIN must resolve through ISBN or metadata instead.

@module koplugin.goodreads.resolver.asin
--]]

local Util = require("goodreadskosync.util")

local Asin = {}

function Asin.isValid(value)
    return Util.isAsin(value)
end

function Asin.normalize(value)
    if type(value) ~= "string" then return nil end
    local upper = value:upper()
    return Util.isAsin(upper) and upper or nil
end

function Asin.fromMetadata(metadata)
    if type(metadata) ~= "table" then return nil end
    if Util.isAsin(metadata.asin) then return metadata.asin end
    if metadata.identifiers then
        for _, entry in ipairs(metadata.identifiers) do
            local value = type(entry) == "table" and (entry.value or entry[2]) or entry
            for _, asin in ipairs(Util.findAsins(value or "")) do
                return asin
            end
        end
    end
    return nil
end

function Asin.fromText(text)
    return Util.findAsins(text or "")
end

return Asin
