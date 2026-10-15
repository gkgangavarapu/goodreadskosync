--[[--
Android support, exercised against an emulated Android environment.

CI has no Android device, so `tests/support/android_env.lua` installs stubs for
the KOReader modules that behave differently when KOReader runs as an app: the
data directory lives on external storage (`/storage/emulated/0/koreader`), the
device is not a Kindle, and there is no KOReader `crash.log`.

These specs pin the behaviour that matters for Android users - absolute paths,
where the plugin writes its files, which provider is chosen, and the clipboard -
so a change that silently breaks Android fails here instead of on someone's
phone.
--]]

local AndroidEnv = require("support.android_env")

local ANDROID_BASE = "/storage/emulated/0/koreader/settings/goodreadskosync"

describe("android: plugin storage", function()
    it("keeps the settings directory absolute on external storage", function()
        AndroidEnv.with(nil, function(env)
            local Storage = env.require("goodreadskosync.storage")
            assert_equal(ANDROID_BASE, Storage.getBaseDir())
        end)
    end)

    it("writes plugin state under the Android settings directory", function()
        AndroidEnv.with({ data_dir = AndroidEnv.sandboxDataDir() }, function(env)
            local Storage = env.require("goodreadskosync.storage")
            local Constants = env.require("goodreadskosync.constants")
            local store = Storage.open(Constants.STORAGE.SETTINGS)
            store:set("auto_link", true)
            assert_true(store:flush())

            local path = env.data_dir .. "/settings/goodreadskosync/"
                .. Constants.STORAGE.SETTINGS .. ".lua"
            local file = io.open(path, "r")
            assert_not_nil(file)
            file:close()
            os.remove(path)
        end)
    end)
end)

describe("android: diagnostic log", function()
    it("appends the trace log under the Android settings directory", function()
        AndroidEnv.with({ data_dir = AndroidEnv.sandboxDataDir() }, function(env)
            local path = env.data_dir .. "/settings/goodreadskosync/login.log"
            os.remove(path)

            local Logging = env.require("goodreadskosync.logging")
            Logging.setEnabled(true)
            Logging.diag("android emulation line")

            local file = io.open(path, "r")
            assert_not_nil(file)
            local text = file:read("*a")
            file:close()
            assert_true(text:find("android emulation line", 1, true) ~= nil)
            os.remove(path)
        end)
    end)

    it("never writes the log when diagnostic logging is off", function()
        AndroidEnv.with({ data_dir = AndroidEnv.sandboxDataDir() }, function(env)
            local path = env.data_dir .. "/settings/goodreadskosync/login.log"
            os.remove(path)

            local Logging = env.require("goodreadskosync.logging")
            Logging.setEnabled(false)
            Logging.diag("must not be written")

            assert_nil(io.open(path, "r"))
        end)
    end)
end)

describe("android: diagnostics report", function()
    it("leaves the absolute Android paths alone", function()
        AndroidEnv.with(nil, function(env)
            local Diagnostics = env.require("goodreadskosync.diagnostics")
            assert_equal(ANDROID_BASE .. "/login.log",
                Diagnostics.absolutePath(ANDROID_BASE .. "/login.log",
                    AndroidEnv.DATA_DIR))
        end)
    end)

    it("says the crash log is missing, since Android has none", function()
        AndroidEnv.with(nil, function(env)
            local Diagnostics = env.require("goodreadskosync.diagnostics")
            local text = table.concat(Diagnostics.platformLines{
                data_dir = ANDROID_BASE,
                crash_log_found = false,
            }, "\n")
            assert_true(text:find("crash_log=missing", 1, true) ~= nil)
            assert_true(text:find(ANDROID_BASE, 1, true) ~= nil)
        end)
    end)
end)

describe("android: provider selection", function()
    it("never offers the Kindle-native provider", function()
        AndroidEnv.with(nil, function(env)
            local Auth = env.require("goodreadskosync.auth.manager")
            local native
            for _i, entry in ipairs(Auth.discover()) do
                if entry.id == "native_kindle" then native = entry end
            end
            assert_not_nil(native)
            assert_false(native.available)
            assert_equal("not a Kindle device", native.reason)
        end)
    end)

    it("auto-selects the web provider", function()
        AndroidEnv.with(nil, function(env)
            local Auth = env.require("goodreadskosync.auth.manager")
            local selected = Auth.auto_select(Auth.discover())
            assert_not_nil(selected)
            assert_equal("goodreads_web", selected.id)
        end)
    end)
end)

describe("android: device capabilities", function()
    it("reports a clipboard, so the report summary can be copied", function()
        AndroidEnv.with(nil, function(env)
            local Device = require("device")
            assert_true(Device:hasClipboard() == true)
            Device.input.setClipboardText("hello")
            assert_equal("hello", env.clipboard.text)
        end)
    end)
end)

-- Everything the plugin keeps on disk has to survive a restart on Android too.
-- Each case writes through the real module and reads it back with a freshly
-- loaded instance, so the Android paths, the fallback serializer and the
-- crypto-degrades-to-plaintext path are all exercised end to end.
describe("android: plugin state on disk", function()
    local function sandbox(extra)
        local opts = { data_dir = AndroidEnv.sandboxDataDir() }
        for key, value in pairs(extra or {}) do opts[key] = value end
        return opts
    end

    local function clean(env)
        env.require("goodreadskosync.storage").reset()
    end

    it("round-trips book mappings", function()
        AndroidEnv.with(sandbox(), function(env)
            clean(env)
            local Mappings = env.require("goodreadskosync.mappings")
            local key = "key=" .. string.rep("ab", 20)
            assert_true(Mappings.put(key, { goodreads_id = "123", title = "Dune" }))

            local reloaded = env.require("goodreadskosync.mappings")
            assert_equal(1, reloaded.count())
            assert_equal("123", reloaded.get(key).goodreads_id)
        end)
    end)

    it("round-trips the sync queue", function()
        AndroidEnv.with(sandbox(), function(env)
            clean(env)
            local Queue = env.require("goodreadskosync.sync.queue")
            assert_true(Queue.enqueue({ operation = "progress", book_id = "k1" }))
            assert_true(Queue.enqueue({ operation = "shelf", book_id = "k1" }))

            local reloaded = env.require("goodreadskosync.sync.queue")
            assert_equal(2, reloaded.size())
        end)
    end)

    it("round-trips the saved session, plaintext when libcrypto is absent", function()
        AndroidEnv.with(sandbox(), function(env)
            clean(env)
            local Session = env.require("goodreadskosync.auth.session")
            local saved = Session.mark_valid(Session.new(), {
                cookies = "_goodreads_session=abc; csrf=def",
                user_id = "42",
            })
            assert_true(Session.save(saved))

            local reloaded = env.require("goodreadskosync.auth.session")
            local loaded = reloaded.load()
            assert_equal("valid", loaded.state)
            assert_equal("_goodreads_session=abc; csrf=def", loaded.cookies)
            assert_equal("42", loaded.user_id)
            assert_true(reloaded.is_valid(loaded))
        end)
    end)

    it("round-trips remembered credentials", function()
        AndroidEnv.with(sandbox(), function(env)
            clean(env)
            local Credentials = env.require("goodreadskosync.auth.credentials")
            assert_true(Credentials.save("reader@example.com", "hunter2"))

            local reloaded = env.require("goodreadskosync.auth.credentials")
            local loaded = reloaded.load()
            assert_equal("reader@example.com", loaded.email)
            assert_equal("hunter2", loaded.password)
            reloaded.clear()
        end)
    end)
end)

describe("android: cover cache", function()
    it("keeps covers inside the Android data directory", function()
        AndroidEnv.with(nil, function(env)
            local Covers = env.require("goodreadskosync.covers")
            assert_equal(ANDROID_BASE .. "/goodreads-covers", Covers.dir())
        end)
    end)

    it("creates the cache directory on demand", function()
        AndroidEnv.with({ data_dir = AndroidEnv.sandboxDataDir() }, function(env)
            local Covers = env.require("goodreadskosync.covers")
            Covers.ensureDir()
            local probe = io.open(Covers.dir() .. "/probe", "w")
            assert_not_nil(probe)
            probe:close()
            os.remove(Covers.dir() .. "/probe")
        end)
    end)
end)

describe("android: kindle-only code stays put", function()
    it("refuses to talk to the device when it is not a Kindle", function()
        AndroidEnv.with(nil, function(env)
            local NativeKindle = env.require("goodreadskosync.providers.native_kindle")
            local instance = NativeKindle:new()
            local available = instance:is_available()
            assert_false(available)
            local ok, err = instance:authenticate()
            assert_false(ok)
            assert_equal("PROVIDER_UNAVAILABLE", err)
        end)
    end)

    it("falls back to the built-in browser when the Kindle helper is absent", function()
        AndroidEnv.with(nil, function(env)
            local Host = env.require("goodreadskosync.browser.host")
            local engine, reason = Host.resolve(
                "netsurf", "/mnt/us/koreader/goodreadskosync/bin/netsurf_render")
            assert_equal("cre", engine)
            assert_equal("netsurf helper not found", reason)
        end)
    end)
end)
