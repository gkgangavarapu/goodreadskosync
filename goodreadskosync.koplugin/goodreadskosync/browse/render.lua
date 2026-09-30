--[[--
Turn a fetched Goodreads page into a clean, self-contained HTML document that
KOReader's HTML engine (CRE, the EPUB reader) can render properly: headings,
paragraphs, lists, and tappable links.

Pure Lua; unit-testable. Images are left as absolute URLs (CRE does not fetch
remote resources, so covers may not show yet).

@module koplugin.goodreads.browse.render
--]]

local Util = require("goodreadskosync.util")

local Render = {}

local STYLE = [[
body { margin: 0.6em; line-height: 1.45; font-size: 1em; }
h1, h2, h3 { margin: 0.7em 0 0.3em; line-height: 1.25; }
p, li, div { margin: 0.25em 0; }
a { text-decoration: underline; }
img { max-width: 100%; }
.gr-nav { margin: 0 0 0.8em; padding-bottom: 0.4em; border-bottom: 1px solid #888; }
.gr-nav a { margin-right: 1em; }
]]

local function absolutize(body, host)
    body = body:gsub('(href)="(//[^"]*)"', '%1="https:%2"')
    body = body:gsub('(href)="(/[^/][^"]*)"', '%1="' .. host .. '%2"')
    body = body:gsub('(src)="(//[^"]*)"', '%1="https:%2"')
    body = body:gsub('(src)="(/[^/][^"]*)"', '%1="' .. host .. '%2"')
    return body
end

-- html, url, nav{ back, reload, home } -> full document string
function Render.page(html, url, nav)
    html = tostring(html or "")
    local host = (url and url:match("^(https?://[^/]+)")) or "https://www.goodreads.com"

    local body = html:match("<body[^>]*>(.-)</body>") or html
    body = body
        :gsub("<script[^>]*>.-</script>", "")
        :gsub("<style[^>]*>.-</style>", "")
        :gsub("<noscript[^>]*>.-</noscript>", "")
        :gsub("<svg[^>]*>.-</svg>", "")
        :gsub("<iframe[^>]*>.-</iframe>", "")
        :gsub("<!%-%-.-%-%->", "")
        -- Drop site chrome so the page reads as an article.
        :gsub("<header[^>]*>.-</header>", "")
        :gsub("<footer[^>]*>.-</footer>", "")
        :gsub("<nav[^>]*>.-</nav>", "")
        :gsub("<aside[^>]*>.-</aside>", "")
        :gsub("<form[^>]*>.-</form>", "")
        :gsub("<button[^>]*>.-</button>", "")

    body = absolutize(body, host)

    local navhtml = ""
    if nav then
        navhtml = '<div class="gr-nav">'
        if nav.back then
            navhtml = navhtml .. '<a href="' .. nav.back .. '">Back</a>'
        end
        navhtml = navhtml .. '<a href="' .. (nav.reload or url or host) .. '">Reload</a>'
        navhtml = navhtml .. '<a href="' .. (nav.home or host) .. '">Home</a>'
        navhtml = navhtml .. '</div>'
    end

    local title = (html:match("<title[^>]*>(.-)</title>") or "Goodreads"):gsub("<[^>]*>", " ")
    title = Util.decodeEntities(title):gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")

    return "<html><head><meta charset='utf-8'><title>" .. title ..
        "</title><style>" .. STYLE .. "</style></head><body>" ..
        navhtml .. body .. "</body></html>"
end

return Render
