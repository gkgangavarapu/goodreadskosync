local Diagnostics = require("goodreadskosync.diagnostics")

local function find(checks, id)
    for _i, check in ipairs(checks) do
        if check.id == id then return check end
    end
    return nil
end

local function healthy(extra)
    local ctx = {
        online = true,
        provider_id = "goodreads",
        provider_available = true,
        authenticated = true,
        session_state = "valid",
        session_expired = false,
        queue_pending = 0,
        queue_failed = 0,
        logging_enabled = true,
        clock_year = 2026,
        clock_text = "2026-10-15 23:00",
    }
    for key, value in pairs(extra or {}) do ctx[key] = value end
    return ctx
end

describe("diagnostics.sessionCheck", function()
    it("passes a working session", function()
        local check = Diagnostics.sessionCheck(true)
        assert_equal("session_live", check.id)
        assert_equal(Diagnostics.STATUS.OK, check.status)
    end)

    it("fails when Goodreads rejected the session", function()
        local check = Diagnostics.sessionCheck(nil, "AUTH_REQUIRED")
        assert_equal(Diagnostics.STATUS.FAIL, check.status)
        assert_true(check.detail:find("AUTH_REQUIRED", 1, true) ~= nil)
    end)

    it("warns when Goodreads gates the request behind a sign-in check", function()
        assert_equal(Diagnostics.STATUS.WARN,
            Diagnostics.sessionCheck(nil, "SIGNIN_BLOCKED").status)
    end)

    it("warns on a plain network error", function()
        local check = Diagnostics.sessionCheck(nil, "NETWORK_ERROR")
        assert_equal(Diagnostics.STATUS.WARN, check.status)
        assert_true(check.detail:find("NETWORK_ERROR", 1, true) ~= nil)
    end)

    it("warns without crashing on an unknown error", function()
        assert_equal(Diagnostics.STATUS.WARN, Diagnostics.sessionCheck(nil, nil).status)
    end)
end)

describe("diagnostics.evaluate", function()
    it("reports nothing to fix when everything is healthy", function()
        local counts = Diagnostics.counts(Diagnostics.evaluate(healthy()))
        assert_equal(0, counts.fail)
        assert_equal(0, counts.warn)
        assert_equal(Diagnostics.STATUS.OK, Diagnostics.verdict(counts))
    end)

    it("fails the network check when offline", function()
        local checks = Diagnostics.evaluate(healthy{ online = false })
        assert_equal(Diagnostics.STATUS.FAIL, find(checks, "network").status)
        assert_equal(Diagnostics.STATUS.FAIL, Diagnostics.verdict(Diagnostics.counts(checks)))
    end)

    it("fails the account check when signed out", function()
        local checks = Diagnostics.evaluate(healthy{
            authenticated = false, session_state = "missing",
        })
        assert_equal(Diagnostics.STATUS.FAIL, find(checks, "account").status)
        assert_equal(Diagnostics.STATUS.WARN, find(checks, "session").status)
    end)

    it("fails the session check when the saved session expired", function()
        local checks = Diagnostics.evaluate(healthy{ session_expired = true })
        assert_equal(Diagnostics.STATUS.FAIL, find(checks, "session").status)
    end)

    it("fails the provider check when none is registered", function()
        local checks = Diagnostics.evaluate(healthy{
            provider_id = nil, provider_available = false,
        })
        assert_equal(Diagnostics.STATUS.FAIL, find(checks, "provider").status)
    end)

    it("warns about failed queued syncs", function()
        local checks = Diagnostics.evaluate(healthy{ queue_pending = 2, queue_failed = 1 })
        assert_equal(Diagnostics.STATUS.WARN, find(checks, "queue").status)
        assert_equal(Diagnostics.STATUS.WARN,
            Diagnostics.verdict(Diagnostics.counts(checks)))
    end)

    it("fails on an implausible device clock", function()
        local checks = Diagnostics.evaluate(healthy{ clock_year = 1970 })
        assert_equal(Diagnostics.STATUS.FAIL, find(checks, "clock").status)
    end)

    it("warns when diagnostic logging is off", function()
        local checks = Diagnostics.evaluate(healthy{ logging_enabled = false })
        assert_equal(Diagnostics.STATUS.WARN, find(checks, "logging").status)
    end)

    it("includes the live session result when one was run", function()
        local checks = Diagnostics.evaluate(healthy{
            session_live = Diagnostics.sessionCheck(nil, "AUTH_REQUIRED"),
        })
        assert_equal(Diagnostics.STATUS.FAIL, find(checks, "session_live").status)
    end)

    it("notes a skipped live check", function()
        local checks = Diagnostics.evaluate(healthy{
            online = false, session_live_skipped = true,
        })
        assert_equal(Diagnostics.STATUS.WARN, find(checks, "session_live").status)
    end)

    it("keeps the canonical order", function()
        local checks = Diagnostics.evaluate(healthy{
            session_live = Diagnostics.sessionCheck(true),
        })
        local ids = {}
        for _i, check in ipairs(checks) do ids[#ids + 1] = check.id end
        assert_equal(table.concat(Diagnostics.CHECKS, ","), table.concat(ids, ","))
    end)
end)

describe("diagnostics.formatChecks", function()
    it("renders compact, one line per check", function()
        local text = Diagnostics.formatChecks(
            Diagnostics.evaluate(healthy{ online = false }), nil, { compact = true })
        assert_true(text:find("[FAIL] network: offline", 1, true) ~= nil)
        assert_true(text:find("[ OK ] account: signed_in=true", 1, true) ~= nil)
    end)

    it("uses translated labels and hints on screen", function()
        local labels = {
            network = {
                name = "Network",
                hints = { fail = "Turn on Wi-Fi." },
            },
        }
        local text = Diagnostics.formatChecks(
            Diagnostics.evaluate(healthy{ online = false }), labels)
        assert_true(text:find("[FAIL] Network", 1, true) ~= nil)
        assert_true(text:find("-> Turn on Wi-Fi.", 1, true) ~= nil)
    end)

    it("does not print a hint for a passing check", function()
        local labels = {
            network = { name = "Network", hints = { fail = "Turn on Wi-Fi." } },
        }
        local text = Diagnostics.formatChecks(Diagnostics.evaluate(healthy()), labels)
        assert_nil(text:find("Turn on Wi-Fi.", 1, true))
    end)
end)

describe("diagnostics.tail", function()
    it("keeps the last lines", function()
        assert_equal("c\nd", Diagnostics.tail("a\nb\nc\nd\n", 2))
    end)

    it("keeps everything when the limit is larger", function()
        assert_equal("a\nb", Diagnostics.tail("a\nb", 10))
    end)

    it("handles empty input", function()
        assert_equal("", Diagnostics.tail("", 5))
        assert_equal("", Diagnostics.tail(nil, 5))
    end)
end)

describe("diagnostics.tailFile", function()
    it("reads only the tail of a file", function()
        local path = os.tmpname()
        local file = io.open(path, "w")
        for i = 1, 500 do file:write("line", i, "\n") end
        file:close()

        local tail = Diagnostics.tailFile(path, 4096, 3)
        assert_equal("line498\nline499\nline500", tail)
        os.remove(path)
    end)

    it("returns nil for a missing file", function()
        assert_nil(Diagnostics.tailFile("./tests/.tmp/does-not-exist.log", 1024, 5))
    end)
end)

describe("diagnostics.settingsLines", function()
    it("includes only allow-listed keys", function()
        local lines = Diagnostics.settingsLines({
            sync_preset = "medium",
            logging = true,
            password = "hunter2",
            title = "Sapiens",
        })
        local text = table.concat(lines, "\n")
        assert_true(text:find("sync_preset=medium", 1, true) ~= nil)
        assert_true(text:find("logging=true", 1, true) ~= nil)
        assert_nil(text:find("hunter2", 1, true))
        assert_nil(text:find("Sapiens", 1, true))
    end)

    it("skips unset keys", function()
        assert_equal(0, #Diagnostics.settingsLines({}))
    end)
end)

describe("diagnostics.buildReport", function()
    it("writes the header then titled sections", function()
        local report = Diagnostics.buildReport({ "head", "generated=now" }, {
            { title = "checks", lines = { "a", "b" } },
            { title = "state", lines = { "c" } },
        })
        assert_equal(
            "head\ngenerated=now\n\n## checks\na\nb\n\n## state\nc\n", report)
    end)
end)

describe("diagnostics.absolutePath", function()
    it("joins a relative path onto the working directory", function()
        assert_equal("/mnt/us/koreader/settings/goodreadskosync/login.log",
            Diagnostics.absolutePath("./settings/goodreadskosync/login.log",
                "/mnt/us/koreader"))
    end)

    it("keeps an absolute path untouched", function()
        assert_equal("/tmp/report.txt",
            Diagnostics.absolutePath("/tmp/report.txt", "/mnt/us/koreader"))
    end)

    it("does not double the separator when the directory ends in one", function()
        assert_equal("/mnt/us/koreader/crash.log",
            Diagnostics.absolutePath("./crash.log", "/mnt/us/koreader/"))
    end)

    it("leaves the path alone when there is no working directory", function()
        assert_equal("./crash.log", Diagnostics.absolutePath("./crash.log", nil))
        assert_equal("./crash.log", Diagnostics.absolutePath("./crash.log", "relative"))
    end)

    it("handles empty and nil input", function()
        assert_nil(Diagnostics.absolutePath(nil, "/mnt/us/koreader"))
        assert_equal("", Diagnostics.absolutePath("", "/mnt/us/koreader"))
    end)
end)

describe("diagnostics.fileName", function()
    it("is a timestamped text file", function()
        local name = Diagnostics.fileName(os.time({ year = 2026, month = 10, day = 15,
            hour = 9, min = 8, sec = 7 }))
        assert_equal("goodreads-diagnostics-20261015-090807.txt", name)
    end)
end)
