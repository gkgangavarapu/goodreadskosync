--[[--
Pure utility functions shared across the plugin.

This module MUST NOT depend on KOReader, the network, or the filesystem so
that it can be exercised directly by the unit test suite.

@module koplugin.goodreads.util
--]]

local Util = {}

local floor = math.floor
local MOD32 = 4294967296

--------------------------------------------------------------------------------
-- String helpers
--------------------------------------------------------------------------------

function Util.trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.isBlank(s)
    return type(s) ~= "string" or s:match("^%s*$") ~= nil
end

function Util.startsWith(s, prefix)
    return type(s) == "string" and type(prefix) == "string"
        and s:sub(1, #prefix) == prefix
end

function Util.collapseWhitespace(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("[\r\n\t\194\160]+", " ") -- CR/LF/TAB/NBSP
    s = s:gsub("%s+", " ")
    return Util.trim(s)
end

-- Decode the small set of HTML/XML entities that appear in OPF metadata.
function Util.decodeEntities(s)
    if type(s) ~= "string" then return "" end
    local named = {
        amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
        nbsp = " ", ndash = "-", mdash = "-", hellip = "...",
        lsquo = "'", rsquo = "'", ldquo = '"', rdquo = '"',
    }
    s = s:gsub("&#x(%x+);", function(hex)
        local n = tonumber(hex, 16)
        return n and Util.codepointToUtf8(n) or ""
    end)
    s = s:gsub("&#(%d+);", function(dec)
        local n = tonumber(dec, 10)
        return n and Util.codepointToUtf8(n) or ""
    end)
    s = s:gsub("&([%a]+);", function(name)
        return named[name:lower()] or ("&" .. name .. ";")
    end)
    return s
end

-- Minimal UTF-8 encoder for numeric character references. Only handles the
-- ranges that can realistically appear in book metadata.
function Util.codepointToUtf8(n)
    if not n or n < 0 then return "" end
    if n < 0x80 then
        return string.char(n)
    elseif n < 0x800 then
        return string.char(0xC0 + floor(n / 64), 0x80 + (n % 64))
    elseif n < 0x10000 then
        return string.char(0xE0 + floor(n / 4096),
            0x80 + (floor(n / 64) % 64), 0x80 + (n % 64))
    else
        return string.char(0xF0 + floor(n / 262144),
            0x80 + (floor(n / 4096) % 64),
            0x80 + (floor(n / 64) % 64), 0x80 + (n % 64))
    end
end

--------------------------------------------------------------------------------
-- Metadata normalization
--------------------------------------------------------------------------------

local function foldPunctuation(s)
    -- Normalize the most common typographic variants to ASCII equivalents.
    local map = {
        ["\226\128\152"] = "'", ["\226\128\153"] = "'", -- curly single quotes
        ["\226\128\156"] = '"', ["\226\128\157"] = '"', -- curly double quotes
        ["\226\128\147"] = "-", ["\226\128\148"] = "-", -- en/em dash
        ["\226\128\166"] = "...",                        -- ellipsis
        ["\194\160"] = " ",                              -- NBSP
    }
    for from, to in pairs(map) do
        s = s:gsub(from, to)
    end
    return s
end

-- Full normalized title, used as one half of the local-key hash.
function Util.normalizeTitle(title)
    if type(title) ~= "string" then return "" end
    title = Util.decodeEntities(title)
    title = foldPunctuation(title)
    title = title:lower()
    title = title:gsub("[\"'`]", "")
    title = Util.collapseWhitespace(title)
    return title
end

-- The core title with any subtitle removed, used as a softer matching signal.
function Util.titleCore(title)
    local normalized = Util.normalizeTitle(title)
    local core = normalized:match("^([^:]+):") or normalized
    core = core:match("^([^%|]+)%|") or core
    return Util.trim(core)
end

function Util.normalizeAuthor(author)
    if type(author) ~= "string" then return "" end
    author = Util.decodeEntities(author)
    author = foldPunctuation(author)
    author = author:lower()
    author = author:gsub("%.", "")
    author = Util.collapseWhitespace(author)
    return author
end

-- Split an author string into individual names. Handles the separators that
-- calibre and EPUB producers actually emit.
function Util.splitAuthors(authors)
    local list = {}
    if type(authors) == "table" then
        for _, a in ipairs(authors) do
            local cleaned = Util.collapseWhitespace(Util.decodeEntities(a))
            if cleaned ~= "" then list[#list + 1] = cleaned end
        end
        return list
    end
    if type(authors) ~= "string" then return list end
    authors = authors:gsub("%s+and%s+", ";")
    authors = authors:gsub("%s+&%s+", ";")
    for part in authors:gmatch("[^;]+") do
        local cleaned = Util.collapseWhitespace(Util.decodeEntities(part))
        if cleaned ~= "" then list[#list + 1] = cleaned end
    end
    return list
end

function Util.primaryAuthor(authors)
    local list = Util.splitAuthors(authors)
    return list[1] or ""
end

--------------------------------------------------------------------------------
-- ISBN
--------------------------------------------------------------------------------

function Util.stripIsbnSeparators(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[^%dXx]", "")):upper()
end

function Util.isValidIsbn10(isbn)
    if type(isbn) ~= "string" then return false end
    isbn = Util.stripIsbnSeparators(isbn)
    if #isbn ~= 10 or not isbn:match("^%d%d%d%d%d%d%d%d%d[%dX]$") then
        return false
    end
    local sum = 0
    for i = 1, 9 do
        sum = sum + tonumber(isbn:sub(i, i)) * i
    end
    local last = isbn:sub(10, 10)
    local check = (last == "X") and 10 or tonumber(last)
    sum = sum + check * 10
    return sum % 11 == 0
end

function Util.isValidIsbn13(isbn)
    if type(isbn) ~= "string" then return false end
    isbn = Util.stripIsbnSeparators(isbn)
    if #isbn ~= 13 or not isbn:match("^%d+$") then return false end
    if not (isbn:sub(1, 3) == "978" or isbn:sub(1, 3) == "979") then
        return false
    end
    local sum = 0
    for i = 1, 12 do
        local digit = tonumber(isbn:sub(i, i))
        sum = sum + digit * (i % 2 == 1 and 1 or 3)
    end
    local check = (10 - (sum % 10)) % 10
    return check == tonumber(isbn:sub(13, 13))
end

-- Compute the ISBN-13 check digit for the first 12 digits.
local function isbn13CheckDigit(first12)
    local sum = 0
    for i = 1, 12 do
        local digit = tonumber(first12:sub(i, i))
        sum = sum + digit * (i % 2 == 1 and 1 or 3)
    end
    return (10 - (sum % 10)) % 10
end

function Util.isbn10to13(isbn10)
    isbn10 = Util.stripIsbnSeparators(isbn10)
    if not Util.isValidIsbn10(isbn10) then return nil end
    local first12 = "978" .. isbn10:sub(1, 9)
    return first12 .. tostring(isbn13CheckDigit(first12))
end

function Util.isbn13to10(isbn13)
    isbn13 = Util.stripIsbnSeparators(isbn13)
    if not Util.isValidIsbn13(isbn13) or isbn13:sub(1, 3) ~= "978" then
        return nil
    end
    local core = isbn13:sub(4, 12) -- 9 digits
    local sum = 0
    for i = 1, 9 do
        sum = sum + tonumber(core:sub(i, i)) * i
    end
    local check = sum % 11
    local check_char = (check == 10) and "X" or tostring(check)
    return core .. check_char
end

-- Extract every valid ISBN from free text / a metadata field.
function Util.findIsbns(text)
    local found, seen = {}, {}
    if type(text) ~= "string" then return found end
    for raw in text:gmatch("[%dXx][%dXx%-%s]*[%dXx]") do
        local digits = Util.stripIsbnSeparators(raw)
        local candidates = {}
        if #digits == 13 or #digits == 10 then
            candidates = { digits }
        elseif #digits > 13 then
            -- Take the first valid 13-digit window.
            candidates = { digits:sub(1, 13) }
        end
        for _, candidate in ipairs(candidates) do
            if (#candidate == 13 and Util.isValidIsbn13(candidate))
                or (#candidate == 10 and Util.isValidIsbn10(candidate))
            then
                if not seen[candidate] then
                    seen[candidate] = true
                    found[#found + 1] = candidate
                end
            end
        end
    end
    return found
end

--------------------------------------------------------------------------------
-- ASIN
--------------------------------------------------------------------------------

-- Conservative ASIN detection: a 10-character identifier beginning with "B".
-- Not every 10-character identifier is an ASIN, so we never infer one.
function Util.isAsin(value)
    return type(value) == "string"
        and value:match("^B[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]$") ~= nil
end

function Util.findAsins(text)
    local found, seen = {}, {}
    if type(text) ~= "string" then return found end
    local upper = text:upper()
    for candidate in upper:gmatch("%f[%w]B[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]%f[^%w]") do
        if not seen[candidate] then
            seen[candidate] = true
            found[#found + 1] = candidate
        end
    end
    return found
end

--------------------------------------------------------------------------------
-- Goodreads ID
--------------------------------------------------------------------------------

-- Only recognize explicit Goodreads identifiers. We never guess an ID from an
-- arbitrary number.
function Util.findGoodreadsIds(text)
    local found, seen = {}, {}
    if type(text) ~= "string" then return found end
    local lower = text:lower()
    for id in lower:gmatch("goodreads%s*id[%s:_#-]*(%d+)") do
        if #id >= 1 and not seen[id] then
            seen[id] = true
            found[#found + 1] = id
        end
    end
    for id in lower:gmatch("goodreads[%s:_#-]+(%d+)") do
        if #id >= 1 and not seen[id] then
            seen[id] = true
            found[#found + 1] = id
        end
    end
    for id in lower:gmatch("goodreads%.com/book/show/(%d+)") do
        if not seen[id] then
            seen[id] = true
            found[#found + 1] = id
        end
    end
    return found
end

function Util.isGoodreadsId(value)
    return type(value) == "string" and value:match("^%d+$") ~= nil
end

--------------------------------------------------------------------------------
-- Local key
--------------------------------------------------------------------------------

-- Deterministic content-independent key used to persist a book mapping.
-- Prefers a real identifier, then falls back to a hash of normalized metadata.
function Util.localKey(identity)
    identity = identity or {}
    if identity.isbn13 and identity.isbn13 ~= "" then return identity.isbn13 end
    if identity.isbn10 and identity.isbn10 ~= "" then return identity.isbn10 end
    if identity.asin and identity.asin ~= "" then return identity.asin end
    if identity.goodreads_id and identity.goodreads_id ~= "" then
        return "gr:" .. identity.goodreads_id
    end
    local title = Util.normalizeTitle(identity.title)
    local author = Util.normalizeAuthor(identity.primary_author or identity.author)
    local year = tostring(identity.publication_year or "")
    return "sha:" .. Util.sha256Hex(title .. "\1" .. author .. "\1" .. year)
end

--------------------------------------------------------------------------------
-- Percent helpers
--------------------------------------------------------------------------------

function Util.percentToInt(percent)
    if type(percent) ~= "number" then return nil end
    local value = floor(percent * 100 + 0.5)
    if value < 0 then value = 0 end
    if value > 100 then value = 100 end
    return value
end

--------------------------------------------------------------------------------
-- SHA-256 (pure Lua, 32-bit arithmetic)
--------------------------------------------------------------------------------

local function band(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
        if a % 2 == 1 and b % 2 == 1 then r = r + p end
        a = floor(a / 2); b = floor(b / 2); p = p * 2
    end
    return r
end

local function bor(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
        if a % 2 == 1 or b % 2 == 1 then r = r + p end
        a = floor(a / 2); b = floor(b / 2); p = p * 2
    end
    return r
end

local function bxor(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
        if (a % 2) ~= (b % 2) then r = r + p end
        a = floor(a / 2); b = floor(b / 2); p = p * 2
    end
    return r
end

local function bnot(a)
    return MOD32 - 1 - a
end

local function rshift(a, n)
    return floor(a / 2 ^ n)
end

local function lshift(a, n)
    return (a * 2 ^ n) % MOD32
end

local function rotr(a, n)
    return bor(rshift(a, n), lshift(a, 32 - n))
end

local SHA256_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256ProcessChunk(state, chunk)
    local w = {}
    for i = 1, 16 do
        local base = (i - 1) * 4
        w[i] = chunk:byte(base + 1) * 0x1000000
            + chunk:byte(base + 2) * 0x10000
            + chunk:byte(base + 3) * 0x100
            + chunk:byte(base + 4)
    end
    for i = 17, 64 do
        local v15, v2 = w[i - 15], w[i - 2]
        local s0 = bxor(bxor(rotr(v15, 7), rotr(v15, 18)), rshift(v15, 3))
        local s1 = bxor(bxor(rotr(v2, 17), rotr(v2, 19)), rshift(v2, 10))
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD32
    end

    local a, b, c, d, e, f, g, h =
        state[1], state[2], state[3], state[4],
        state[5], state[6], state[7], state[8]

    for i = 1, 64 do
        local S1 = bxor(bxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local temp1 = (h + S1 + ch + SHA256_K[i] + w[i]) % MOD32
        local S0 = bxor(bxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
        local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
        local temp2 = (S0 + maj) % MOD32

        h = g; g = f; f = e
        e = (d + temp1) % MOD32
        d = c; c = b; b = a
        a = (temp1 + temp2) % MOD32
    end

    state[1] = (state[1] + a) % MOD32
    state[2] = (state[2] + b) % MOD32
    state[3] = (state[3] + c) % MOD32
    state[4] = (state[4] + d) % MOD32
    state[5] = (state[5] + e) % MOD32
    state[6] = (state[6] + f) % MOD32
    state[7] = (state[7] + g) % MOD32
    state[8] = (state[8] + h) % MOD32
end

function Util.sha256Hex(message)
    if type(message) ~= "string" then message = "" end
    local state = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }

    local bit_length = #message * 8
    local padded = message .. "\128"
    while (#padded % 64) ~= 56 do
        padded = padded .. "\0"
    end
    -- 64-bit big-endian length; high 32 bits are effectively always zero here.
    local high = floor(bit_length / MOD32)
    local low = bit_length % MOD32
    padded = padded
        .. string.char(floor(high / 0x1000000) % 256, floor(high / 0x10000) % 256,
            floor(high / 0x100) % 256, high % 256)
        .. string.char(floor(low / 0x1000000) % 256, floor(low / 0x10000) % 256,
            floor(low / 0x100) % 256, low % 256)

    for offset = 0, #padded - 64, 64 do
        sha256ProcessChunk(state, padded:sub(offset + 1, offset + 64))
    end

    local out = {}
    for i = 1, 8 do
        out[#out + 1] = string.format("%08x", state[i])
    end
    return table.concat(out)
end

--------------------------------------------------------------------------------
-- Tables
--------------------------------------------------------------------------------

function Util.deepcopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for k, v in pairs(value) do
        copy[Util.deepcopy(k, seen)] = Util.deepcopy(v, seen)
    end
    return copy
end

function Util.countKeys(t)
    local n = 0
    if type(t) ~= "table" then return n end
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Short book label for toasts (kept brief; never splits a UTF-8 character).
function Util.shortTitle(title)
    if type(title) ~= "string" or title == "" then return nil end
    if #title <= 28 then return title end
    local cut = 28
    while cut > 1 do
        local b = title:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return title:sub(1, cut) .. "…"
end

return Util
