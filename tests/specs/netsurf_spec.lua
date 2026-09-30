local Engine = require("goodreadskosync.browser.engine")
local Host = require("goodreadskosync.browser.host")
local NetSurf = require("goodreadskosync.browser.engines.netsurf")

-- A fake helper that writes a PGM + JSON for the requested url/scroll.
local function fake_runner(w, h, scroll_h)
    return function(argv)
        local out, url, scroll = nil, "", "0"
        for i = 1, #argv do
            if argv[i] == "--out" then out = argv[i + 1]
            elseif argv[i] == "--url" then url = argv[i + 1]
            elseif argv[i] == "--scroll" then scroll = argv[i + 1] end
        end
        local f = io.open(out .. ".pgm", "wb")
        f:write(string.format("P5\n%d %d\n255\n", w, h))
        f:write(string.rep("\5", w * h))
        f:close()
        local j = io.open(out .. ".json", "w")
        j:write(string.format(
            '{"url":"%s","title":"T","width":%d,"height":%d,'
            .. '"scroll_h":%d,"scroll_y":%s,'
            .. '"hits":[{"x":0,"y":0,"w":2,"h":2,"href":"https://x/next"}]}',
            url, w, h, scroll_h, scroll))
        j:close()
        return true, "", "", 0
    end
end

describe("browser.engines.netsurf", function()
    it("parses a P5 PGM header", function()
        local data = "P5\n3 2\n255\n" .. string.rep("\0", 6)
        local pgm = NetSurf.parse_pgm(data)
        assert_equal(3, pgm.width)
        assert_equal(2, pgm.height)
        assert_equal(6, #pgm.pixels)
    end)

    it("rejects a non-PGM", function()
        assert_nil(NetSurf.parse_pgm("P6\n1 1\n255\nx"))
    end)

    it("hit-tests regions topmost first", function()
        local hits = {
            { x = 0, y = 0, w = 10, h = 10, href = "a" },
            { x = 5, y = 5, w = 10, h = 10, href = "b" },
        }
        assert_equal("b", NetSurf.hit_at(hits, 6, 6).href)
        assert_equal("a", NetSurf.hit_at(hits, 1, 1).href)
        assert_nil(NetSurf.hit_at(hits, 99, 99))
    end)

    it("implements the BrowserEngine contract", function()
        local e = NetSurf.new{ bin = "/fake", runner = fake_runner(4, 3, 9) }
        assert_true(Engine.validate(e))
        assert_false(e:capabilities().js)
        assert_true(e:capabilities().images)
    end)

    it("loads, renders and reads dimensions/hits", function()
        local e = NetSurf.new{
            bin = "/fake", runner = fake_runner(4, 3, 9), tmp_dir = ".",
        }
        assert_true(e:load("https://example.com/"))
        local frame = e:render()
        assert_equal(4, frame.width)
        assert_equal(3, frame.height)
        assert_equal(9, frame.scroll_h)
        assert_equal(1, #frame.hits)
        assert_equal("T", e:title())
    end)

    it("navigates on tap and tracks history", function()
        local e = NetSurf.new{
            bin = "/fake", runner = fake_runner(4, 3, 9), tmp_dir = ".",
        }
        assert_true(e:load("https://example.com/"))
        assert_true(e:tap(1, 1))
        assert_equal("https://x/next", e:url())
        assert_true(e:back())
        assert_equal("https://example.com/", e:url())
        assert_true(e:forward())
        assert_equal("https://x/next", e:url())
    end)

    it("formats a Cookie header as Netscape cookie lines", function()
        local lines = NetSurf.netscape_cookie_lines(
            "sst-main=abc; ccsid=555-1", ".goodreads.com", 1821801443)
        assert_equal(2, #lines)
        assert_equal(".goodreads.com\tTRUE\t/\tFALSE\t1821801443\tsst-main\tabc",
            lines[1])
        assert_equal(".goodreads.com\tTRUE\t/\tFALSE\t1821801443\tccsid\t555-1",
            lines[2])
    end)

    it("ignores a missing/empty cookie header", function()
        assert_equal(0, #NetSurf.netscape_cookie_lines(nil))
        assert_equal(0, #NetSurf.netscape_cookie_lines(""))
    end)

    it("writes the cookie jar file", function()
        local path = "./.netsurf-cookies-test"
        local e = NetSurf.new{ bin = "/fake", cookie_file = path,
            runner = fake_runner(4, 3, 9), tmp_dir = "." }
        e:set_cookies("a=1; b=2", ".goodreads.com", 0)
        local f = io.open(path, "r")
        local body = f:read("*a")
        f:close()
        os.remove(path)
        assert_true(body:find("# Netscape HTTP Cookie File", 1, true) ~= nil)
        assert_true(body:find("goodreads.com\tTRUE\t/\tFALSE\t0\ta\t1", 1, true) ~= nil)
        assert_true(body:find("goodreads.com\tTRUE\t/\tFALSE\t0\tb\t2", 1, true) ~= nil)
    end)

    it("scrolls by re-invoking the helper", function()
        local e = NetSurf.new{
            bin = "/fake", runner = fake_runner(4, 3, 9), tmp_dir = ".",
        }
        assert_true(e:load("https://example.com/"))
        assert_true(e:scroll(0, 5))
        assert_equal(5, e:render().scroll_y)
    end)
end)

describe("browser.host", function()
    it("falls back to CRE when the NetSurf helper is missing", function()
        assert_equal("cre", (Host.resolve("netsurf", "/no/such/bin")))
    end)

    it("selects NetSurf only when the helper exists", function()
        local path = "./.netsurf-fake-bin"
        local f = io.open(path, "w"); f:write("#!/bin/sh\n"); f:close()
        assert_equal("netsurf", (Host.resolve("netsurf", path)))
        os.remove(path)
    end)

    it("defaults to CRE", function()
        assert_equal("cre", (Host.resolve("cre", "")))
        assert_equal("cre", (Host.resolve(nil, nil)))
    end)
end)
