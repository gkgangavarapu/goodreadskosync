--[[--
EPUB OPF metadata extraction.

`parseOpf` and `rootfilePath` are pure functions over XML strings so they can
be tested without a real EPUB. `extract` reads a real EPUB through KOReader's
`ffi/archiver` when available.

@module koplugin.goodreads.resolver.epub
--]]

local Util = require("goodreadskosync.util")

local Epub = {}

--------------------------------------------------------------------------------
-- Small XML helpers (namespace-agnostic, OPF-shaped)
--------------------------------------------------------------------------------

local function stripTags(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("<[^>]->", " ")
    return Util.collapseWhitespace(Util.decodeEntities(s))
end

local function parseAttributes(attr_string)
    local attrs = {}
    if type(attr_string) ~= "string" then return attrs end
    for key, _, value in attr_string:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
        attrs[key] = Util.decodeEntities(value)
        -- Also index by the local name (drop any namespace prefix).
        local local_name = key:match(":([%w_%-]+)$")
        if local_name and attrs[local_name] == nil then
            attrs[local_name] = Util.decodeEntities(value)
        end
    end
    return attrs
end

-- Iterate over all elements with the given local name, yielding the attribute
-- string, inner text (or nil for self-closing tags), and a self-closing flag.
-- Uses a positional scan so that a local name never matches a tag suffix
-- (e.g. "title" must not match "subtitle").
local function eachElement(xml, local_name, fn)
    local pos = 1
    while true do
        local s, e, tag, attrs = xml:find("<([%w_%-:]+)([^>]-)>", pos)
        if not s then break end
        local name = tag:match(":([%w_%-]+)$") or tag
        local self_closing = attrs:match("/%s*$") ~= nil
        if name == local_name then
            local body = nil
            if not self_closing then
                local close = xml:find("</" .. tag .. "%s*>", e + 1)
                if not close then
                    close = xml:find("</[%w_%-:]*" .. name .. "%s*>", e + 1)
                end
                if close then body = xml:sub(e + 1, close - 1) end
            end
            fn(parseAttributes(attrs), body, self_closing)
        end
        pos = e + 1
    end
end

--------------------------------------------------------------------------------
-- Container
--------------------------------------------------------------------------------

function Epub.rootfilePath(container_xml)
    if type(container_xml) ~= "string" then return nil end
    local path = container_xml:match("<rootfile[^>]-full%-path%s*=%s*[\"']([^\"']+)[\"']")
    return path
end

--------------------------------------------------------------------------------
-- OPF
--------------------------------------------------------------------------------

local function classifyIdentifier(value, scheme, result)
    if type(value) ~= "string" then return end
    local lower = value:lower()
    local normalized_scheme = (scheme or ""):lower()

    local is_isbn = normalized_scheme:find("isbn", 1, true) ~= nil
        or lower:find("urn:isbn", 1, true) ~= nil
        or lower:find("^isbn", 1) ~= nil
    local is_goodreads = normalized_scheme:find("goodreads", 1, true) ~= nil
        or lower:find("goodreads", 1, true) ~= nil
    local is_asin = normalized_scheme:find("asin", 1, true) ~= nil
        or lower:find("urn:asin", 1, true) ~= nil
        or lower:find("mobi%-asin", 1) ~= nil
        or lower:find("^asin", 1) ~= nil

    if is_goodreads then
        for _, id in ipairs(Util.findGoodreadsIds(value)) do
            if not result.goodreads_id then result.goodreads_id = id end
        end
    end
    if is_asin then
        for _, asin in ipairs(Util.findAsins(value)) do
            if not result.asin then result.asin = asin end
        end
    end
    if is_isbn or not (is_goodreads or is_asin) then
        for _, isbn in ipairs(Util.findIsbns(value)) do
            if #isbn == 13 and not result.isbn13 then
                result.isbn13 = isbn
            elseif #isbn == 10 and not result.isbn10 then
                result.isbn10 = isbn
            end
        end
    end
end

-- Parse an OPF document into a normalized metadata table.
function Epub.parseOpf(xml)
    local result = {
        title = nil,
        authors = {},
        contributors = {},
        identifiers = {},
        publisher = nil,
        language = nil,
        date = nil,
        publication_year = nil,
        series = nil,
        series_index = nil,
        isbn10 = nil,
        isbn13 = nil,
        asin = nil,
        goodreads_id = nil,
    }
    if type(xml) ~= "string" or xml == "" then return result end

    eachElement(xml, "title", function(_, body)
        if not result.title and body then
            local value = stripTags(body)
            if value ~= "" then result.title = value end
        end
    end)

    eachElement(xml, "creator", function(attrs, body)
        local name = stripTags(body)
        if name == "" then return end
        local role = attrs.role or attrs["opf:role"] or "aut"
        local entry = { name = name, role = role:lower() }
        if entry.role == "aut" or entry.role == "" then
            result.authors[#result.authors + 1] = name
        else
            result.contributors[#result.contributors + 1] = entry
        end
    end)

    eachElement(xml, "publisher", function(_, body)
        if not result.publisher and body then
            local value = stripTags(body)
            if value ~= "" then result.publisher = value end
        end
    end)

    eachElement(xml, "language", function(_, body)
        if not result.language and body then
            local value = stripTags(body)
            if value ~= "" then result.language = value end
        end
    end)

    eachElement(xml, "date", function(_, body)
        if not result.date and body then
            local value = stripTags(body)
            if value ~= "" then
                result.date = value
                local year = value:match("(%d%d%d%d)")
                if year then result.publication_year = tonumber(year) end
            end
        end
    end)

    eachElement(xml, "identifier", function(attrs, body)
        local value = stripTags(body)
        if value == "" then return end
        local scheme = attrs.scheme or attrs["opf:scheme"] or attrs.id
        result.identifiers[#result.identifiers + 1] = {
            scheme = scheme, value = value, id = attrs.id,
        }
        classifyIdentifier(value, scheme, result)
    end)

    -- <meta name="..." content="..."/> and <meta property="...">text</meta>
    eachElement(xml, "meta", function(attrs, body)
        local name = attrs.name or attrs.property
        local content = attrs.content or (body and stripTags(body)) or ""
        if not name then return end
        local lower = name:lower()
        if lower == "calibre:series" or lower == "belongs-to-collection" then
            result.series = result.series or content
        elseif lower == "calibre:series_index" or lower == "group-position" then
            result.series_index = result.series_index or content
        elseif lower == "calibre:isbn" or lower:find("isbn", 1, true) then
            classifyIdentifier(content, "ISBN", result)
        elseif lower:find("asin", 1, true) then
            classifyIdentifier(content, "ASIN", result)
        elseif lower:find("goodreads", 1, true) then
            classifyIdentifier(content, "goodreads", result)
        end
    end)

    if not result.title or result.title == "" then
        result.title = nil
    end
    return result
end

--------------------------------------------------------------------------------
-- EPUB file extraction
--------------------------------------------------------------------------------

local function findOpfEntry(reader)
    if reader.entries then
        for entry_path in pairs(reader.entries) do
            if entry_path:lower():match("%.opf$") then return entry_path end
        end
    end
    return nil
end

-- Read an EPUB and return parsed OPF metadata, or nil + reason.
function Epub.extract(path)
    if type(path) ~= "string" or path == "" then
        return nil, "no path"
    end
    local ok, archiver = pcall(require, "ffi/archiver")
    if not ok or not archiver then
        return nil, "archiver unavailable"
    end

    local reader = archiver.Reader:new()
    pcall(function() reader:open(path) end)

    local container_xml
    pcall(function()
        container_xml = reader:extractToMemory("META-INF/container.xml")
    end)
    local opf_path = container_xml and Epub.rootfilePath(container_xml)
    if not opf_path then opf_path = findOpfEntry(reader) end

    local opf_xml
    if opf_path then
        pcall(function() opf_xml = reader:extractToMemory(opf_path) end)
    end
    pcall(function() reader:close() end)

    if not opf_xml then
        return nil, "no opf found"
    end
    return Epub.parseOpf(opf_xml)
end

-- Build metadata from KOReader's already-parsed document props.
function Epub.fromDocProps(doc_props)
    local result = Epub.parseOpf(nil)
    if type(doc_props) ~= "table" then return result end
    result.title = doc_props.display_title or doc_props.title
    if doc_props.authors then
        result.authors = Util.splitAuthors(doc_props.authors)
    end
    result.publisher = doc_props.publisher
    result.language = doc_props.language
    result.series = doc_props.series
    result.series_index = doc_props.series_index
    if doc_props.identifiers then
        if type(doc_props.identifiers) == "table" then
            for _, entry in ipairs(doc_props.identifiers) do
                if type(entry) == "table" then
                    classifyIdentifier(entry.value or entry[2] or "",
                        entry.scheme or entry[1], result)
                    result.identifiers[#result.identifiers + 1] = entry
                else
                    classifyIdentifier(tostring(entry), nil, result)
                end
            end
        elseif type(doc_props.identifiers) == "string" then
            classifyIdentifier(doc_props.identifiers, nil, result)
        end
    end
    return result
end

Epub._stripTags = stripTags
Epub._parseAttributes = parseAttributes

return Epub
