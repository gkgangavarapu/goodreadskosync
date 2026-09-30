--[[--
Image URL collection and rewriting for the on-device reader.

Pure Lua (no KOReader dependencies) so it can be unit tested. The plugin
downloads the collected images with its session, saves them next to the page,
and calls `rewrite` so the document references local files (CRE does not fetch
remote images).

@module koplugin.goodreads.browse.images
--]]

local Images = {}

local function absolutize(base, src)
    if not src or src == "" then return nil end
    if src:match("^data:") then return nil end
    if src:match("^https?://") then return src end
    if src:sub(1, 2) == "//" then return "https:" .. src end
    local host = (base and base:match("^(https?://[^/]+)")) or "https://www.goodreads.com"
    if src:sub(1, 1) == "/" then return host .. src end
    return host .. "/" .. src
end

-- Absolute https image URLs on the page, in document order, deduped.
function Images.collect(html, base)
    local urls, seen = {}, {}
    if type(html) ~= "string" then return urls end
    for tag in html:gmatch("<img[^>]*>") do
        local src = tag:match('src="([^"]+)"') or tag:match("src='([^']+)'")
        local abs = absolutize(base, src)
        if abs and abs:match("^https://") and not seen[abs] then
            seen[abs] = true
            urls[#urls + 1] = abs
        end
    end
    return urls
end

-- File extension to use for a downloaded image (jpg/png/gif/webp).
function Images.extension(url)
    local path = tostring(url or ""):match("^[^?]+") or ""
    local ext = path:match("%.([%a%d]+)$")
    ext = ext and ext:lower() or nil
    if ext == "jpeg" then ext = "jpg" end
    if ext == "jpg" or ext == "png" or ext == "gif" or ext == "webp" then return ext end
    return "jpg"
end

local function escape_pattern(s)
    return (tostring(s):gsub("([^%w])", "%%%1"))
end

-- Rewrite each original URL in the HTML to its local (relative) path.
function Images.rewrite(html, map)
    if type(html) ~= "string" then return html end
    local out = html
    for url, local_path in pairs(map or {}) do
        out = out:gsub(escape_pattern(url), function() return local_path end)
    end
    return out
end

return Images
