local Images = require("goodreadskosync.browse.images")

describe("browse.images", function()
    it("collects and absolutizes img srcs (deduped, https only)", function()
        local html = [[
<img src="/images/a.jpg">
<img src="https://s.gr-assets.com/images/b.png">
<img src="//s.gr-assets.com/images/c.gif">
<img src="https://s.gr-assets.com/images/b.png">
<img src="data:image/png;base64,AAAA">
<img src="https://example.com/x.jpg">
]]
        local urls = Images.collect(html, "https://www.goodreads.com/book/show/1")
        assert_equal(4, #urls)
        assert_equal("https://www.goodreads.com/images/a.jpg", urls[1])
        assert_equal("https://s.gr-assets.com/images/b.png", urls[2])
        assert_equal("https://s.gr-assets.com/images/c.gif", urls[3])
        assert_equal("https://example.com/x.jpg", urls[4])
    end)

    it("picks a sane file extension", function()
        assert_equal("jpg", Images.extension("https://x/a.jpeg"))
        assert_equal("png", Images.extension("https://x/a.png?w=100"))
        assert_equal("gif", Images.extension("https://x/a.gif"))
        assert_equal("jpg", Images.extension("https://x/noext"))
    end)

    it("rewrites original urls to local relative paths", function()
        local html = [[<img src="https://x/a.png"><img src="/b.jpg">]]
        local out = Images.rewrite(html, {
            ["https://x/a.png"] = "browse-img/abc.png",
        })
        assert_true(out:find('src="browse-img/abc.png"', 1, true) ~= nil)
        assert_true(out:find("/b.jpg", 1, true) ~= nil)
    end)
end)

describe("browser.engine", function()
    local Engine = require("goodreadskosync.browser.engine")

    it("accepts the mock engine", function()
        local ok = Engine.validate(Engine.mock())
        assert_true(ok)
    end)

    it("rejects an engine missing methods", function()
        local bad = Engine.mock()
        bad.scroll = nil
        local ok, err = Engine.validate(bad)
        assert_false(ok)
        assert_true(err:find("scroll", 1, true) ~= nil)
    end)

    it("mock loads a url and reports it", function()
        local e = Engine.mock()
        assert_true(e:load("https://www.goodreads.com/"))
        assert_equal("https://www.goodreads.com/", e:url())
        assert_false(e:capabilities().js)
    end)
end)
