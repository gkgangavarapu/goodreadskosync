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

-- html, url, nav{ back, reload, home }, extra_css, opts -> full document string
-- opts.site_css = false skips the site's own CSS (clean "reader" style; the
-- default), because CRE cannot render modern flex/grid CSS and the site CSS
-- applied to a stripped DOM looks broken.
function Render.page(html, url, nav, extra_css, opts)
    opts = opts or {}
    html = tostring(html or "")
    local host = (url and url:match("^(https?://[^/]+)")) or "https://www.goodreads.com"

    -- Keep the page's own inline (critical) CSS so CRE can style it like the site.
    local inline_css = {}
    for css in html:gmatch("<style[^>]*>(.-)</style>") do
        inline_css[#inline_css + 1] = css
    end

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

    local css_head = ""
    if opts.site_css ~= false then
        local site_css = table.concat(inline_css, "\n") .. "\n" .. tostring(extra_css or "")
        if #site_css > 400000 then site_css = site_css:sub(1, 400000) end
        css_head = "<style>" .. site_css .. "</style>"
    end

    return "<html><head><meta charset='utf-8'><title>" .. title ..
        "</title><style>" .. STYLE .. "</style>" ..
        css_head .. "</head><body>" ..
        navhtml .. body .. "</body></html>"
end

return Render
