local Parse = require("goodreadskosync.browse.parse")

local HTML = [[
<html><head><title>Martyr! by Kaveh Akbar | Goodreads</title>
<script>var x = 1;</script>
<style>.a { color: red; }</style></head>
<body>
<div>Home</div>
<div class="content">
<h1>Martyr!</h1>
<p>A novel about Cyrus Shams.</p>
<a href="/book/show/139400713">Martyr!</a>
<a href="https://www.goodreads.com/book/show/139400713">Martyr! (dup)</a>
<a href="https://example.com/x">external</a>
<a href="/author/show/123">Kaveh Akbar</a>
</div>
<div>Terms</div>
<div>Privacy</div>
</body></html>]]

local function contains(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

describe("browse.parse", function()
    it("extracts the title", function()
        local page = Parse.page(HTML, "https://www.goodreads.com/book/show/139400713")
        assert_equal("Martyr! by Kaveh Akbar | Goodreads", page.title)
    end)

    it("keeps content paragraphs and drops chrome", function()
        local page = Parse.page(HTML, "https://www.goodreads.com/book/show/139400713")
        assert_true(contains(page.paragraphs, "Martyr!"))
        assert_true(contains(page.paragraphs, "A novel about Cyrus Shams."))
        assert_false(contains(page.paragraphs, "Home"))
        assert_false(contains(page.paragraphs, "Terms"))
        assert_false(contains(page.paragraphs, "Privacy"))
    end)

    it("collects goodreads links, deduped and absolute", function()
        local page = Parse.page(HTML, "https://www.goodreads.com/book/show/139400713")
        assert_equal(2, #page.links)
        assert_equal("https://www.goodreads.com/book/show/139400713", page.links[1].href)
        assert_equal("https://www.goodreads.com/author/show/123", page.links[2].href)
    end)
end)
