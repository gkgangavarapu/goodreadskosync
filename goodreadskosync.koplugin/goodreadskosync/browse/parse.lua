--[[--
Minimal HTML -> readable text + links, for the on-device Goodreads reader.

Pure Lua (no KOReader dependencies) so it can be unit tested. It is deliberately
simple: strip scripts/styles, pull out goodreads.com links, and turn block markup
into paragraphs, dropping obvious site chrome.

@module koplugin.goodreads.browse.parse
--]]

local Util = require("goodreadskosync.util")

local Parse = {}

-- Lines that are almost always site chrome/navigation, not content.
local CHROME = {
    "home", "my books", "browse", "community", "about us", "careers", "terms",
    "privacy", "interest based ads", "ad preferences", "your ads privacy choices",
    "help", "mobile version", "company", "work with us", "connect", "sign in",
    "sign up", "sign in or create account", "search", "more", "full site",
    "get help with signing in", "goodreads llc", "an amazon company",
}

local function is_chrome(line)
    if #line <= 2 then return true end
    local l = line:lower()
    if l:match("^[%d,%+%.%s]+$") then return true end
    for i = 1, #CHROME do
        if l == CHROME[i] then return true end
    end
    return false
end

-- Turn a relative href into an absolute URL (Goodreads only, later filtered).
local function resolve(base, href)
    if not href or href == "" or href:sub(1, 1) == "#" then return nil end
    if href:match("^https?://") then return href end
    if href:sub(1, 2) == "//" then return "https:" .. href end
    local host = (base and base:match("^(https?://[^/]+)")) or "https://www.goodreads.com"
    if href:sub(1, 1) == "/" then return host .. href end
    return host .. "/" .. href
end

-- html, url -> { title, paragraphs = {...}, links = { {text, href}, ... } }
function Parse.page(html, url)
    html = tostring(html or "")
    local title = (html:match("<title[^>]*>(.-)</title>") or ""):gsub("<[^>]*>", " ")
    title = Util.decodeEntities(title):gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")

    local content = html
        :gsub("<script[^>]*>.-</script>", " ")
        :gsub("<style[^>]*>.-</style>", " ")
        :gsub("<noscript[^>]*>.-</noscript>", " ")
        :gsub("<svg[^>]*>.-</svg>", " ")
        :gsub("<!%-%-.-%-%->", " ")

    local links, seen = {}, {}
    for href, label in content:gmatch('<a[^>]-href="([^"]+)"[^>]*>(.-)</a>') do
        local text = label:gsub("<[^>]*>", " ")
        text = Util.decodeEntities(text):gsub("%s+", " ")
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        local abs = resolve(url, href)
        if text ~= "" and abs and abs:match("^https?://[^/]*goodreads%.com") and not seen[abs] then
            seen[abs] = true
            links[#links + 1] = { text = text, href = abs }
            if #links >= 200 then break end
        end
    end

    local text = content
        :gsub("<br%s*/?>", "\n")
        :gsub("</p>", "\n"):gsub("</div>", "\n"):gsub("</li>", "\n")
        :gsub("</tr>", "\n"):gsub("</h%d>", "\n")
        :gsub("<[^>]*>", " ")
    text = Util.decodeEntities(text)
    text = text:gsub("[ \t\r]+", " ")
    text = text:gsub(" *\n *", "\n")
    text = text:gsub("\n\n+", "\n")

    local paragraphs = {}
    for line in text:gmatch("[^\n]+") do
        local l = line:gsub("^%s+", ""):gsub("%s+$", "")
        if l ~= "" and not is_chrome(l) then
            paragraphs[#paragraphs + 1] = l
            if #paragraphs >= 400 then break end
        end
    end

    return { title = title, paragraphs = paragraphs, links = links }
end

return Parse
