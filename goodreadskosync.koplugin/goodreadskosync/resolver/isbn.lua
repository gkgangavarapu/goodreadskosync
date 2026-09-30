--[[--
ISBN-specific helpers built on util.lua.

@module koplugin.goodreads.resolver.isbn
--]]

local Util = require("goodreadskosync.util")

local Isbn = {}

function Isbn.normalize(value)
    return Util.stripIsbnSeparators(value)
end

-- Returns "isbn13", "isbn10", or nil.
function Isbn.kind(value)
    local normalized = Util.stripIsbnSeparators(value)
    if #normalized == 13 and Util.isValidIsbn13(normalized) then return "isbn13" end
    if #normalized == 10 and Util.isValidIsbn10(normalized) then return "isbn10" end
    return nil
end

function Isbn.isValid(value)
    return Isbn.kind(value) ~= nil
end

function Isbn.to13(value)
    local kind = Isbn.kind(value)
    if kind == "isbn13" then return Util.stripIsbnSeparators(value) end
    if kind == "isbn10" then return Util.isbn10to13(value) end
    return nil
end

function Isbn.to10(value)
    local kind = Isbn.kind(value)
    if kind == "isbn10" then return Util.stripIsbnSeparators(value) end
    if kind == "isbn13" then return Util.isbn13to10(value) end
    return nil
end

-- Pull ISBNs out of a parsed metadata table. Returns isbn13, isbn10.
function Isbn.fromMetadata(metadata)
    if type(metadata) ~= "table" then return nil, nil end
    local isbn13, isbn10 = metadata.isbn13, metadata.isbn10
    if metadata.identifiers then
        for _, entry in ipairs(metadata.identifiers) do
            local value = type(entry) == "table" and (entry.value or entry[2]) or entry
            for _, isbn in ipairs(Util.findIsbns(value or "")) do
                if #isbn == 13 and not isbn13 then isbn13 = isbn end
                if #isbn == 10 and not isbn10 then isbn10 = isbn end
            end
        end
    end
    return isbn13, isbn10
end

function Isbn.fromText(text)
    return Util.findIsbns(text or "")
end

return Isbn
