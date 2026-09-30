local Engine = require("goodreadskosync.browser.engine")
local Host = require("goodreadskosync.browser.host")
local Platform = require("goodreadskosync.browser.platform")
local NetSurf = require("goodreadskosync.browser.engines.netsurf")

-- A fake helper: writes a PGM + JSON for the requested url/scroll.
local function fake_run(w, h, scroll_h)
    return function(_, argv)
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

local function engine(w, h, scroll_h)
    return NetSurf.new{
        bin = "/fake",
        platform = Platform.new{ run = fake_run(w or 4, h or 3, scroll_h or 9) },
        tmp_dir = ".",
    }
end

describe("browser.platform", function()
    it("provides overridable defaults", function()
        local p = Platform.new{ tmp_dir = function() return "/x" end }
        assert_equal("/x", p:tmp_dir())
        assert_true(type(p.read) == "function")
        assert_true(type(p.run) == "function")
    end)
end)

describe("browser.engine", function()
    it("accepts the mock engine", function()
        assert_true(Engine.validate(Engine.mock()))
    end)

    it("rejects an engine missing methods", function()
        local bad = Engine.mock()
        bad.scroll = nil
        local ok, err = Engine.validate(bad)
        assert_false(ok)
        assert_true(err:find("scroll", 1, true) ~= nil)
    end)

    it("mock reports structured capabilities", function()
        local caps = Engine.mock():capabilities()
        assert_false(caps.js.enabled)
        assert_true(caps.images.raster)
        assert_equal("2.1", caps.css.level)
    end)

    it("normalizes partial capability tables", function()
        local caps = Engine.normalize{ engine = "x", https = true }
        assert_true(caps.https)
        assert_false(caps.forms)
        assert_equal(0, caps.html.level)
    end)

    it("reads dotted capabilities and checks requirements", function()
        local caps = Engine.normalize{ images = { raster = true } }
        assert_true(Engine.capability(caps, "images.raster"))
        assert_true(Engine.meets(caps, { "images.raster" }))
        assert_false(Engine.meets(caps, { "images.svg" }))
        assert_false(Engine.meets(caps, { "forms" }))
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

    it("chooses an engine by capability and availability", function()
        local require_hitmap = { "hitmap", "https" }
        assert_equal("netsurf", Host.choose({ "netsurf", "cre" }, require_hitmap))
        assert_equal("netsurf", Host.choose({ "netsurf", "cre" }, require_hitmap,
            function() return true end))
        assert_nil(Host.choose({ "netsurf", "cre" }, require_hitmap,
            function() return false end))
        -- CRE has no hitmap, so a hitmap requirement excludes it entirely.
        assert_nil(Host.choose({ "cre" }, require_hitmap))
    end)

    it("builds a viewport without assuming dimensions", function()
        local vp = Host.viewport(600, 800, { dpi = 300, scale = 1 })
        assert_equal(600, vp.w)
        assert_equal(800, vp.h)
        assert_equal(300, vp.dpi)
        assert_equal(1, vp.scale)
    end)
end)

describe("browser.engines.netsurf", function()
    it("parses a P5 PGM header", function()
        local pgm = NetSurf.parse_pgm("P5\n3 2\n255\n" .. string.rep("\0", 6))
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
        local e = engine()
        assert_true(Engine.validate(e))
        assert_false(e:capabilities().js.enabled)
        assert_true(e:capabilities().images.raster)
        assert_true(e:capabilities().https)
    end)

    it("loads, renders and reads dimensions/hits", function()
        local e = engine(4, 3, 9)
        assert_true(e:load("https://example.com/"))
        local frame = e:render()
        assert_equal(4, frame.width)
        assert_equal(3, frame.height)
        assert_equal(9, frame.scroll_h)
        assert_equal(1, #frame.hits)
        assert_equal("T", e:title())
    end)

    it("navigates on tap and tracks history", function()
        local e = engine()
        assert_true(e:load("https://example.com/"))
        assert_true(e:tap(1, 1))
        assert_equal("https://x/next", e:url())
        assert_true(e:back())
        assert_equal("https://example.com/", e:url())
        assert_true(e:forward())
        assert_equal("https://x/next", e:url())
    end)

    it("scrolls by re-invoking the helper", function()
        local e = engine()
        assert_true(e:load("https://example.com/"))
        assert_true(e:scroll(0, 5))
        assert_equal(5, e:render().scroll_y)
    end)

    it("formats a Cookie header as Netscape cookie lines", function()
        local lines = NetSurf.netscape_cookie_lines(
            "sst-main=abc; ccsid=555-1", ".goodreads.com", 1821801443)
        assert_equal(2, #lines)
        assert_equal(".goodreads.com\tTRUE\t/\tFALSE\t1821801443\tsst-main\tabc",
            lines[1])
    end)

    it("ignores a missing/empty cookie header", function()
        assert_equal(0, #NetSurf.netscape_cookie_lines(nil))
        assert_equal(0, #NetSurf.netscape_cookie_lines(""))
    end)

    it("writes the cookie jar file via the platform", function()
        local path = "./.netsurf-cookies-test"
        local e = NetSurf.new{ bin = "/fake", cookie_file = path, tmp_dir = ".",
            platform = Platform.new{ run = fake_run(4, 3, 9) } }
        e:set_cookies("a=1; b=2", ".goodreads.com", 0)
        local f = io.open(path, "r")
        local body = f:read("*a")
        f:close()
        os.remove(path)
        assert_true(body:find("# Netscape HTTP Cookie File", 1, true) ~= nil)
        assert_true(body:find("goodreads.com\tTRUE\t/\tFALSE\t0\ta\t1", 1, true) ~= nil)
    end)
end)

describe("browser.host engine factory", function()
    it("refuses NetSurf when the helper is missing", function()
        local eng, err = Host.create_engine(Host.NETSURF, { bin = "/no/such/bin" })
        assert_nil(eng)
        assert_true(err:find("not found", 1, true) ~= nil)
    end)

    it("creates a contract-compliant NetSurf engine when the helper exists", function()
        local path = "./.netsurf-fake-bin2"
        local f = io.open(path, "w"); f:write("#!/bin/sh\n"); f:close()
        local eng = Host.create_engine(Host.NETSURF, {
            bin = path,
            platform = Platform.new{ run = fake_run(4, 3, 9) },
            viewport = { w = 4, h = 3 },
        })
        os.remove(path)
        assert_true(Engine.validate(eng))
        assert_equal("netsurf", eng:capabilities().engine)
    end)

    it("refuses unknown engines", function()
        local eng, err = Host.create_engine("webview", {})
        assert_nil(eng)
        assert_true(err:find("unsupported", 1, true) ~= nil)
    end)
end)

describe("browser.engines.netsurf helper robustness", function()
    local function writing_run(w, h, code, opts)
        opts = opts or {}
        return function(_, argv)
            local out = nil
            for i = 1, #argv do
                if argv[i] == "--out" then out = argv[i + 1] end
            end
            if not opts.no_pgm then
                local f = io.open(out .. ".pgm", "wb")
                f:write(string.format("P5\n%d %d\n255\n", w, h))
                f:write(string.rep("\7", w * h))
                f:close()
            end
            if not opts.no_json then
                local j = io.open(out .. ".json", "w")
                j:write(opts.bad_json and "not json"
                    or string.format('{"url":"u","title":"t","width":%d,"height":%d,"hits":[]}',
                        w, h))
                j:close()
            end
            return true, "", "", code
        end
    end

    it("consumes a valid frame even when the helper exits nonzero", function()
        local e = NetSurf.new{ bin = "/fake", tmp_dir = ".",
            platform = Platform.new{ run = writing_run(4, 3, 134) } }
        assert_true(e:load("https://x/"))
        local frame = e:render()
        assert_equal(4, frame.width)
        assert_equal(134, frame.helper_exit)
    end)

    it("reports a helper exit when no output was written", function()
        local e = NetSurf.new{ bin = "/fake", tmp_dir = ".",
            platform = Platform.new{ run = writing_run(4, 3, 134,
                { no_pgm = true, no_json = true }) } }
        local ok, err = e:load("https://x/")
        assert_nil(ok)
        assert_true(err:find("helper exit 134", 1, true) ~= nil)
    end)

    it("reports missing output on a clean exit", function()
        local e = NetSurf.new{ bin = "/fake", tmp_dir = ".",
            platform = Platform.new{ run = writing_run(4, 3, 0,
                { no_pgm = true, no_json = true }) } }
        local ok, err = e:load("https://x/")
        assert_nil(ok)
        assert_equal("missing output files", err)
    end)

    it("reports bad output for corrupt json", function()
        local e = NetSurf.new{ bin = "/fake", tmp_dir = ".",
            platform = Platform.new{ run = writing_run(4, 3, 0, { bad_json = true }) } }
        local ok, err = e:load("https://x/")
        assert_nil(ok)
        assert_equal("bad output", err)
    end)

    it("reports bad output for corrupt json even on nonzero exit", function()
        local e = NetSurf.new{ bin = "/fake", tmp_dir = ".",
            platform = Platform.new{ run = writing_run(4, 3, 134, { bad_json = true }) } }
        local ok, err = e:load("https://x/")
        assert_nil(ok)
        assert_true(err:find("helper exit 134", 1, true) ~= nil)
    end)
end)

describe("browser.platform io", function()
    it("writes, reads, checks and removes files", function()
        local p = Platform.new()
        local path = "./.platform-io-test"
        assert_true(p:write(path, "hello"))
        assert_true(p:exists(path))
        assert_equal("hello", p:read(path))
        p:remove(path)
        assert_false(p:exists(path))
        assert_nil(p:read(path))
    end)

    it("quotes arguments for the shell", function()
        local seen = nil
        local p = Platform.new{ run = function(_, argv)
            seen = argv
            return true, "", "", 0
        end }
        p:run({ "/bin/x", "--url", "https://a/b?c=d&e" })
        assert_equal("https://a/b?c=d&e", seen[3])
    end)
end)

describe("browse.frame", function()
    local Frame = require("goodreadskosync.browse.frame")

    it("reads grayscale bytes and defaults to white", function()
        local pixels = string.char(0, 128, 255, 64)
        assert_equal(0, Frame.gray_at(pixels, 2, 0, 0))
        assert_equal(128, Frame.gray_at(pixels, 2, 1, 0))
        assert_equal(255, Frame.gray_at(pixels, 2, 0, 1))
        assert_equal(255, Frame.gray_at(pixels, 2, 9, 9))
    end)

    it("validates frames", function()
        assert_true(Frame.is_valid{ width = 2, height = 2, bitmap = string.rep("\0", 4) })
        assert_false(Frame.is_valid{ width = 2, height = 2, bitmap = "xx" })
        assert_false(Frame.is_valid(nil))
    end)

    it("re-encodes to PGM", function()
        local pgm = Frame.to_pgm(2, 1, string.char(1, 2))
        assert_true(pgm:find("P5\n2 1\n255\n", 1, true) == 1)
        assert_equal(2, #pgm - #("P5\n2 1\n255\n"))
    end)
end)
