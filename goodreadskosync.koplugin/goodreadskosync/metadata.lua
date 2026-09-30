--[[--
Document metadata acquisition.

Combines KOReader's already-parsed document properties with a direct OPF read
when a real EPUB is available. The OPF read is best-effort: if the archiver is
unavailable (or the file is not an EPUB), we fall back to `doc_props`.

@module koplugin.goodreads.metadata
--]]

local Logging = require("goodreadskosync.logging")
local Epub = require("goodreadskosync.resolver.epub")
local Util = require("goodreadskosync.util")

local Metadata = {}

function Metadata.basename(path)
    if type(path) ~= "string" then return nil end
    return path:match("[^/\\]+$") or path
end

-- Fill empty fields in `primary` from `fallback`.
function Metadata.merge(primary, fallback)
    local merged = Util.deepcopy(primary or {})
    fallback = fallback or {}
    if not merged.title or merged.title == "" then
        merged.title = fallback.title
    end
    if not merged.authors or #merged.authors == 0 then
        merged.authors = fallback.authors or {}
    end
    for _, field in ipairs({ "publisher", "language", "publication_year",
        "series", "series_index", "isbn10", "isbn13", "asin", "goodreads_id" }) do
        if merged[field] == nil or merged[field] == "" then
            merged[field] = fallback[field]
        end
    end
    if (not merged.identifiers or #merged.identifiers == 0) and fallback.identifiers then
        merged.identifiers = fallback.identifiers
    end
    return merged
end

-- Extract metadata for the currently open document.
-- Returns metadata, filename.
function Metadata.fromDocument(ui)
    local doc_props = ui and ui.doc_props
    local file = ui and ui.document and ui.document.file
    local filename = Metadata.basename(file)

    local from_props = Epub.fromDocProps(doc_props)
    if not file then
        return from_props, filename
    end

    local ok, opf = pcall(Epub.extract, file)
    if ok and opf then
        return Metadata.merge(opf, from_props), filename
    end
    Logging.debug("metadata: OPF extraction unavailable, using document props")
    return from_props, filename
end

-- Extract metadata for an arbitrary EPUB path (used by diagnostics/tests).
function Metadata.fromPath(path)
    local ok, opf = pcall(Epub.extract, path)
    if ok and opf then return opf end
    return nil
end

return Metadata
