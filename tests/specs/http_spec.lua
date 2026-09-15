local Constants = require("goodreadskosync.constants")
local Http = require("goodreadskosync.goodreads.http")
local FakeHttp = require("support.fake_http")

describe("goodreads.http cookies", function()
    it("drops jwt_token and cookie attributes", function()
        local sanitized = Http.sanitizeCookie(
            "jwt_token=stale; _session_id2=xyz; path=/; at-main=1; HttpOnly")
        assert_equal("_session_id2=xyz; at-main=1", sanitized)
    end)

    it("merges Set-Cookie values, overriding existing names", function()
        local merged = Http.mergeSetCookie(
            "_session_id2=old; at-main=1",
            "_session_id2=new; session-token=t; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
        assert_true(merged:find("_session_id2=new", 1, true) ~= nil)
        assert_true(merged:find("at%-main=1") ~= nil)
        assert_true(merged:find("session%-token=t") ~= nil)
        assert_true(merged:find("Path") == nil)
    end)

    it("resolves absolute URLs", function()
        assert_equal("https://a.com/y", Http.absolute("https://a.com/x", "/y"))
        assert_equal("https://b.com/z", Http.absolute("https://a.com/x", "//b.com/z"))
        assert_equal("https://a.com/base/p", Http.absolute("https://a.com/x", "base/p"))
    end)
end)

describe("goodreads.http requests", function()
    it("reads the LuaSocket (1, code, headers, statusline) return tuple", function()
        package.preload["socket.http"] = function()
            return { request = function(req)
                if req.sink then req.sink("hello") end
                return 1, 200, { ["content-type"] = "text/html" }, "HTTP/1.1 200 OK"
            end }
        end
        package.preload["ltn12"] = function()
            return {
                sink = { table = function(t)
                    return function(chunk)
                        if chunk then t[#t + 1] = chunk end
                        return 1
                    end
                end },
                source = { string = function(s) return function() return s end end },
            }
        end

        local ok, status, headers, body = Http.default_transport({
            url = "https://example.invalid/", method = "GET",
        })
        assert_true(ok)
        assert_equal(200, status)
        assert_equal("hello", body)
        assert_equal("text/html", headers["content-type"])

        package.loaded["socket.http"] = nil
        package.loaded["ltn12"] = nil
        package.preload["socket.http"] = nil
        package.preload["ltn12"] = nil
    end)

    it("follows redirects and rotates cookies", function()
        local transport, calls = FakeHttp.scripted({
            { status = 302, headers = {
                location = "/next",
                ["set-cookie"] = "_session_id2=abc",
            } },
            { status = 200, body = "done" },
        })
        local http = Http:new{ transport = transport }
        local resp = http:get("https://www.goodreads.com/start")

        assert_nil(resp.error)
        assert_equal("done", resp.body)
        assert_equal("https://www.goodreads.com/next", calls[2].url)
        assert_true(http:get_cookie_header():find("_session_id2=abc", 1, true) ~= nil)
    end)

    it("classifies interception responses", function()
        local transport = FakeHttp.scripted({
            { status = 403, headers = { ["x-challenge"] = "challenge" } },
        })
        local http = Http:new{ transport = transport }
        local resp = http:get("https://www.goodreads.com/")
        assert_equal(Constants.ERROR.SIGNIN_BLOCKED, resp.error)
        assert_equal(true, resp.blocked)
    end)

    it("classifies status codes", function()
        local cases = {
            [401] = Constants.ERROR.AUTH_REQUIRED,
            [403] = Constants.ERROR.AUTH_REQUIRED,
            [404] = Constants.ERROR.NOT_FOUND,
            [409] = Constants.ERROR.CONFLICT,
            [429] = Constants.ERROR.RATE_LIMITED,
            [500] = Constants.ERROR.SERVER_ERROR,
            [418] = Constants.ERROR.INVALID_RESPONSE,
        }
        for status, expected in pairs(cases) do
            local transport = FakeHttp.scripted({ { status = status } })
            local http = Http:new{ transport = transport }
            local resp = http:get("https://www.goodreads.com/")
            assert_equal(expected, resp.error)
        end
    end)

    it("classifies network failures", function()
        local transport = FakeHttp.scripted({ { ok = false } })
        local http = Http:new{ transport = transport }
        local resp = http:get("https://www.goodreads.com/")
        assert_equal(Constants.ERROR.NETWORK_ERROR, resp.error)
    end)

    it("detects a sign-in page as an expired session", function()
        local transport = FakeHttp.scripted({
            { status = 200, body = '<form action="/ap/signin"><input name="email"></form>' },
        })
        local http = Http:new{ transport = transport }
        local resp = http:get("https://www.goodreads.com/review/list")
        assert_equal(Constants.ERROR.AUTH_REQUIRED, resp.error)
    end)

    it("encodes POST forms and sets headers", function()
        local transport, calls = FakeHttp.scripted({ { status = 200 } })
        local http = Http:new{ transport = transport }
        http:post_form("https://www.goodreads.com/x", { b = "two words", a = "1" })

        assert_equal("a=1&b=two%20words", calls[1].body)
        assert_equal("application/x-www-form-urlencoded; charset=UTF-8",
            calls[1].headers["Content-Type"])
        assert_equal(tostring(#calls[1].body), calls[1].headers["Content-Length"])
    end)

    it("attaches the CSRF token when requested", function()
        local transport, calls = FakeHttp.scripted({ { status = 200 } })
        local http = Http:new{ transport = transport, csrf_token = "TOKEN" }
        http:post_form("https://www.goodreads.com/x", { a = "1" }, { csrf = true })
        assert_equal("TOKEN", calls[1].headers["X-CSRF-Token"])
    end)
end)
