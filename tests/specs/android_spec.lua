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
