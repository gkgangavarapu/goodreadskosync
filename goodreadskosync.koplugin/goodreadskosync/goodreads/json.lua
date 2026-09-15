--[[--
Minimal JSON decoder.

KOReader ships `json`, but the unit suite runs on stock Lua 5.1. This module
is used as a fallback (and in tests) so JSON handling is deterministic and
dependency-free. It only needs to decode; the plugin never encodes JSON.

@module koplugin.goodreads.goodreads.json
--]]

local Util = require("goodreadskosync.util")

local Json = {}

local escapes = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
    n = "\n", r = "\r", t = "\t",
}

local function skip_whitespace(s, i)
    while true do
        local c = s:sub(i, i)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            i = i + 1
        else
            return i
        end
    end
end

local parse_value

local function parse_string(s, i)
    -- s:sub(i,i) == '"'
    i = i + 1
    local out = {}
    while true do
        local c = s:sub(i, i)
        if c == "" then error("unterminated string") end
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local esc = s:sub(i + 1, i + 1)
            if esc == "u" then
                local hex = s:sub(i + 2, i + 5)
                local code = tonumber(hex, 16)
                if not code then error("bad \\u escape") end
                out[#out + 1] = Util.codepointToUtf8(code)
                i = i + 6
            else
                out[#out + 1] = escapes[esc] or esc
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local function parse_number(s, i)
    local start = i
    local c = s:sub(i, i)
    while c:match("[%d%.eE%+%-]") do
        i = i + 1
        c = s:sub(i, i)
    end
    local value = tonumber(s:sub(start, i - 1))
    if not value then error("bad number") end
    return value, i
end

local function parse_array(s, i)
    i = skip_whitespace(s, i + 1) -- skip '['
    local arr = {}
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local value
        value, i = parse_value(s, i)
        arr[#arr + 1] = value
        i = skip_whitespace(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skip_whitespace(s, i + 1)
        elseif c == "]" then
            return arr, i + 1
        else
            error("bad array")
        end
    end
end

local function parse_object(s, i)
    i = skip_whitespace(s, i + 1) -- skip '{'
    local obj = {}
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        if s:sub(i, i) ~= '"' then error("bad object key") end
        local key
        key, i = parse_string(s, i)
        i = skip_whitespace(s, i)
        if s:sub(i, i) ~= ":" then error("expected ':'") end
        i = skip_whitespace(s, i + 1)
        local value
        value, i = parse_value(s, i)
        obj[key] = value
        i = skip_whitespace(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skip_whitespace(s, i + 1)
        elseif c == "}" then
            return obj, i + 1
        else
            error("bad object")
        end
    end
end

parse_value = function(s, i)
    i = skip_whitespace(s, i)
    local c = s:sub(i, i)
    if c == "{" then return parse_object(s, i) end
    if c == "[" then return parse_array(s, i) end
    if c == '"' then return parse_string(s, i) end
    if c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4 end
    if c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5 end
    if c == "n" and s:sub(i, i + 3) == "null" then return nil, i + 4 end
    return parse_number(s, i)
end

function Json.decode(text)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    local ok, value = pcall(function()
        local v = parse_value(text, 1)
        return v
    end)
    if not ok then return nil, "invalid json" end
    return value
end

-- Prefer KOReader's json when present, otherwise this decoder.
function Json.decode_any(text)
    local ok, ko_json = pcall(require, "json")
    if ok and ko_json and type(ko_json.decode) == "function" then
        local decoded, value = pcall(ko_json.decode, text)
        if decoded then return value end
        return nil, "invalid json"
    end
    return Json.decode(text)
end

return Json
