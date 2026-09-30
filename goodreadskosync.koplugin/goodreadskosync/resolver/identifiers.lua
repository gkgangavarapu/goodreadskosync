--[[--
Builds a canonical BookIdentity from raw EPUB metadata and the filename.

Identifier priority (highest first):
  1. explicit Goodreads ID
  2. ISBN-13
  3. ISBN-10
  4. ASIN
  5. ISBN embedded in the filename
  6. ASIN embedded in the filename
  7. EPUB metadata (title + author)
  8. title + author
  9. title only

@module koplugin.goodreads.resolver.identifiers
--]]

local Constants = require("goodreadskosync.constants")
local Util = require("goodreadskosync.util")
local Isbn = require("goodreadskosync.resolver.isbn")
local Asin = require("goodreadskosync.resolver.asin")

local Identifiers = {}

local function identifierSourceForPriority(index)
    local order = {
        Constants.IDENTIFIER_SOURCE.GOODREADS_ID,
        Constants.IDENTIFIER_SOURCE.ISBN13,
        Constants.IDENTIFIER_SOURCE.ISBN10,
        Constants.IDENTIFIER_SOURCE.ASIN,
        Constants.IDENTIFIER_SOURCE.FILENAME_ISBN,
        Constants.IDENTIFIER_SOURCE.FILENAME_ASIN,
        Constants.IDENTIFIER_SOURCE.METADATA,
        Constants.IDENTIFIER_SOURCE.TITLE_AUTHOR,
        Constants.IDENTIFIER_SOURCE.TITLE,
    }
    return order[index]
end

-- Whether a source represents a hard identifier match (used by the matcher to
-- decide whether an automatic selection is permitted).
function Identifiers.isHardSource(source)
    return source == Constants.IDENTIFIER_SOURCE.GOODREADS_ID
        or source == Constants.IDENTIFIER_SOURCE.ISBN13
        or source == Constants.IDENTIFIER_SOURCE.ISBN10
        or source == Constants.IDENTIFIER_SOURCE.ASIN
        or source == Constants.IDENTIFIER_SOURCE.FILENAME_ISBN
        or source == Constants.IDENTIFIER_SOURCE.FILENAME_ASIN
end

-- Build the canonical identity. `metadata` is the output of resolver.epub.
function Identifiers.build(metadata, filename)
    metadata = metadata or {}
    local identity = {
        title = metadata.title,
        authors = metadata.authors or {},
        primary_author = (metadata.authors and metadata.authors[1]) or nil,
        publisher = metadata.publisher,
        language = metadata.language,
        publication_year = metadata.publication_year,
        series = metadata.series,
        series_index = metadata.series_index,
        isbn13 = metadata.isbn13,
        isbn10 = metadata.isbn10,
        asin = metadata.asin,
        goodreads_id = metadata.goodreads_id,
    }

    local source
    if identity.goodreads_id then
        source = Constants.IDENTIFIER_SOURCE.GOODREADS_ID
    elseif identity.isbn13 then
        source = Constants.IDENTIFIER_SOURCE.ISBN13
    elseif identity.isbn10 then
        source = Constants.IDENTIFIER_SOURCE.ISBN10
    elseif identity.asin then
        source = Constants.IDENTIFIER_SOURCE.ASIN
    else
        local filename_isbns = Util.findIsbns(filename or "")
        if #filename_isbns > 0 then
            for _, isbn in ipairs(filename_isbns) do
                if #isbn == 13 and not identity.isbn13 then
                    identity.isbn13 = isbn
                elseif #isbn == 10 and not identity.isbn10 then
                    identity.isbn10 = isbn
                end
            end
            source = Constants.IDENTIFIER_SOURCE.FILENAME_ISBN
        else
            local filename_asins = Util.findAsins(filename or "")
            if #filename_asins > 0 then
                identity.asin = filename_asins[1]
                source = Constants.IDENTIFIER_SOURCE.FILENAME_ASIN
            elseif identity.title and identity.primary_author then
                source = Constants.IDENTIFIER_SOURCE.TITLE_AUTHOR
            else
                source = Constants.IDENTIFIER_SOURCE.TITLE
            end
        end
    end

    -- Normalize ISBNs for consistent storage.
    if identity.isbn13 then identity.isbn13 = Isbn.to13(identity.isbn13) end
    if identity.isbn10 then identity.isbn10 = Isbn.to10(identity.isbn10) end
    if not identity.isbn13 and identity.isbn10 then
        identity.isbn13 = Isbn.to13(identity.isbn10)
    end
    if not identity.isbn10 and identity.isbn13 then
        identity.isbn10 = Isbn.to10(identity.isbn13)
    end
    if identity.asin then identity.asin = Asin.normalize(identity.asin) end

    identity.source = source
    identity.local_key = Util.localKey(identity)
    return identity
end

-- Convert a stored mapping record back into an identity-shaped table.
function Identifiers.fromMapping(mapping)
    if type(mapping) ~= "table" then return nil end
    return {
        goodreads_id = mapping.goodreads_id,
        isbn13 = mapping.isbn13,
        isbn10 = mapping.isbn10,
        asin = mapping.asin,
        title = mapping.title,
        authors = mapping.authors or {},
        primary_author = mapping.author or (mapping.authors and mapping.authors[1]),
        source = Constants.IDENTIFIER_SOURCE.MAPPING,
        local_key = mapping.local_key,
    }
end

Identifiers.priorityOrder = identifierSourceForPriority

return Identifiers
