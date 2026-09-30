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

describe("browse.images.prune", function()
    it("is a no-op for a missing directory (never throws)", function()
        local fs = {
            attributes = function() return nil end,
            dir = function() error("dir() must not be called for a missing dir") end,
        }
        assert_equal(0, Images.prune("/no/such/dir", 3, fs))
    end)

    it("removes the oldest files beyond keep", function()
        local names = { ".grkprune_a", ".grkprune_b", ".grkprune_c", ".grkprune_d", ".grkprune_e" }
        local mtime = {
            [".grkprune_a"] = 1, [".grkprune_b"] = 5, [".grkprune_c"] = 3,
            [".grkprune_d"] = 2, [".grkprune_e"] = 4,
        }
        for _, n in ipairs(names) do
            local f = io.open(n, "w"); f:write("x"); f:close()
        end
        local i = 0
        local fs = {
            attributes = function(path, key)
                if key == "mode" then return "directory" end
                local n = path:match("([^/]+)$")
                if mtime[n] then return { mode = "file", modification = mtime[n] } end
                return nil
            end,
            dir = function()
                return function() i = i + 1; return names[i] end
            end,
        }
        local removed = Images.prune(".", 3, fs)
        assert_equal(2, removed)
        local function exists(n) local f = io.open(n, "r"); if f then f:close() return true end return false end
        assert_false(exists(".grkprune_a"))
        assert_false(exists(".grkprune_d"))
        assert_true(exists(".grkprune_b"))
        assert_true(exists(".grkprune_c"))
        assert_true(exists(".grkprune_e"))
        for _, n in ipairs(names) do os.remove(n) end
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
        assert_false(e:capabilities().js.enabled)
    end)
end)
