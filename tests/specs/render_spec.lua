local Render = require("goodreadskosync.browse.render")

local HTML = [[
<html><head><title>Martyr! | Goodreads</title>
<script>evil()</script><style>.x{color:red}</style></head>
<body><div class="siteHeader">Home</div>
<h1>Martyr!</h1><p>A novel.</p>
<a href="/book/show/139400713">Read more</a>
<a href="https://example.com/x">ext</a>
</body></html>]]

describe("browse.render", function()
    it("produces a standalone HTML document with our stylesheet", function()
        local doc = Render.page(HTML, "https://www.goodreads.com/book/show/139400713")
        assert_true(doc:find("<html>", 1, true) ~= nil)
        assert_true(doc:find("<style>", 1, true) ~= nil)
        assert_true(doc:find("Martyr!", 1, true) ~= nil)
    end)

    it("removes scripts but keeps the page's inline CSS", function()
        local doc = Render.page(HTML, "https://www.goodreads.com/book/show/139400713")
        assert_nil(doc:find("evil()", 1, true))
        -- Inline (critical) CSS is now preserved so CRE styles it like the site.
        assert_true(doc:find("color:red", 1, true) ~= nil)
    end)

    it("drops site chrome (header/footer/nav)", function()
        local html = [[<html><body><header>HDR</header><nav>NAV</nav>]] ..
            [[<p>Content</p><footer>FTR</footer></body></html>]]
        local doc = Render.page(html, "https://www.goodreads.com/")
        assert_true(doc:find("Content", 1, true) ~= nil)
        assert_nil(doc:find("HDR", 1, true))
        assert_nil(doc:find("NAV", 1, true))
        assert_nil(doc:find("FTR", 1, true))
    end)

    it("keeps the page's inline CSS and adds fetched site CSS", function()
        local html = [[<html><head><style>.site{color:#123}</style></head>]] ..
            [[<body><p>Hi</p></body></html>]]
        local doc = Render.page(html, "https://www.goodreads.com/", nil,
            ".fetched{font-size:2em}")
        assert_true(doc:find(".site{color:#123}", 1, true) ~= nil)
        assert_true(doc:find(".fetched{font-size:2em}", 1, true) ~= nil)
    end)

    it("absolutizes relative links and adds a nav bar", function()
        local doc = Render.page(HTML, "https://www.goodreads.com/book/show/139400713",
            { back = "https://www.goodreads.com/", reload = "https://www.goodreads.com/book/show/139400713", home = "https://www.goodreads.com/" })
        assert_true(doc:find('href="https://www.goodreads.com/book/show/139400713"', 1, true) ~= nil)
        assert_true(doc:find("gr-nav", 1, true) ~= nil)
        assert_true(doc:find(">Reload<", 1, true) ~= nil)
    end)
end)
