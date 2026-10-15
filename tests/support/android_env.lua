--[[--
Android environment emulation.

The plugin has to work on Android (KOReader shipped as an app) as well as on
Kindle, but CI has no Android device. This fixture installs Android-shaped
stubs for the few KOReader modules the plugin touches, so specs can exercise the
platform-dependent paths off-device:

  * `datastorage` -> the app's data directory on external storage
    (`/storage/emulated/0/koreader`), which is what makes the plugin's paths
    absolute on Android instead of `.` as on Kindle;
  * `device` -> an Android device: not a Kindle, no shell tooling, clipboard
    backed by the Android bridge;
  * `logger` -> silent, so trace output stays out of the test transcript.

Everything else keeps running against host Lua. The plugin never calls Android
APIs directly, so there is nothing else worth faking.

    local env = AndroidEnv.install()
    local Storage = env.require("goodreadskosync.storage")
    assert_equal("/storage/emulated/0/koreader/settings/goodreadskosync",
        Storage.getBaseDir())
    AndroidEnv.uninstall()

`install()` returns a handle whose `require(name)` bypasses the module cache, so
a spec gets instances built on the stubs. `uninstall()` restores the real
modules; instances handed out by `env.require` must not outlive it.

@module tests.support.android_env
--]]

local AndroidEnv = {}

-- Where KOReader keeps its data when it runs as an Android app.
AndroidEnv.DATA_DIR = "/storage/emulated/0/koreader"

-- A real, writable directory used when a spec needs the files to actually
-- exist (the emulated Android path above does not exist on the host).
AndroidEnv.SANDBOX = "./tests/.tmp/android/koreader"

-- KOReader modules the plugin loads. Replaced while the emulation is active.
local STUB_MODULES = {
    "datastorage", "device", "android", "logger", "version",
    "ui/network/manager",
}

-- Plugin modules that read platform state and are therefore reloaded so they
-- pick up the stubs rather than a cached instance.
local RELOAD_MODULES = {
    "goodreadskosync.storage",
    "goodreadskosync.logging",
    "goodreadskosync.crypto_util",
    "goodreadskosync.diagnostics",
    "goodreadskosync.auth.session",
    "goodreadskosync.auth.credentials",
    "goodreadskosync.auth.manager",
    "goodreadskosync.providers.base",
    "goodreadskosync.providers.goodreads_web",
    "goodreadskosync.providers.native_kindle",
    "goodreadskosync.providers.official_api",
    "goodreadskosync.providers.mock",
}

local saved_preload = {}
local saved_loaded = {}
local active = false

-- Portable recursive mkdir. Kept here rather than in the plugin: the plugin
-- relies on the shell it already has, the test runner has to work on Windows
-- and Linux.
local function mkdirp(path)
    local cmd
    if os.getenv("OS") ~= nil then
        cmd = 'mkdir "' .. path:gsub("/", "\\") .. '" 2>nul'
    else
        cmd = 'mkdir -p "' .. path .. '" 2>/dev/null'
    end
    os.execute(cmd)
end

AndroidEnv.mkdirp = mkdirp

local function stub_datastorage(data_dir)
    return function()
        local ds = {}
        function ds:getDataDir() return data_dir end
        function ds:getSettingsDir() return data_dir .. "/settings" end
        function ds:getHistoryDir() return data_dir .. "/history" end
        return ds
    end
end

local function stub_device(clipboard)
    return function()
        local input = {}
        function input.setClipboardText(text)
            clipboard.text = text
            return true
        end
        return {
            model = "Android",
            input = input,
            isKindle = function() return false end,
            isTouchDevice = function() return true end,
            hasClipboard = function() return true end,
            hasWifiToggle = function() return true end,
        }
    end
end

local function stub_android(data_dir)
    return function()
        return {
            getExternalStoragePath = function()
                return (data_dir:match("^(.-)/koreader$") or data_dir)
            end,
            isFullscreen = function() return false end,
            setClipboardText = function() return true end,
        }
    end
end

local function stub_logger()
    return function()
        local noop = function() end
        return { dbg = noop, info = noop, warn = noop, err = noop }
    end
end

-- Install the Android stubs. opts.data_dir overrides the emulated data
-- directory (use AndroidEnv.SANDBOX when the spec writes real files).
function AndroidEnv.install(opts)
    opts = opts or {}
    local data_dir = opts.data_dir or AndroidEnv.DATA_DIR
    local clipboard = { text = nil }

    for _i, name in ipairs(STUB_MODULES) do
        saved_preload[name] = package.preload[name]
        saved_loaded[name] = package.loaded[name]
        package.loaded[name] = nil
    end
    for _i, name in ipairs(RELOAD_MODULES) do
        package.loaded[name] = nil
    end

    package.preload["datastorage"] = stub_datastorage(data_dir)
    package.preload["device"] = stub_device(clipboard)
    package.preload["android"] = stub_android(data_dir)
    package.preload["logger"] = stub_logger()
    package.preload["version"] = function()
        return { getShortVersion = function() return "android-emulated" end }
    end
    package.preload["ui/network/manager"] = function()
        return {
            isConnected = function() return true end,
            isOnline = function() return true end,
        }
    end

    active = true
    return {
        data_dir = data_dir,
        clipboard = clipboard,
        require = function(name)
            package.loaded[name] = nil
            return require(name)
        end,
    }
end

-- Restore the real KOReader modules and the pre-emulation plugin instances.
function AndroidEnv.uninstall()
    if not active then return end
    active = false
    for _i, name in ipairs(STUB_MODULES) do
        package.preload[name] = saved_preload[name]
        package.loaded[name] = saved_loaded[name]
    end
    for _i, name in ipairs(RELOAD_MODULES) do
        package.loaded[name] = nil
    end
end

-- Run `fn(env)` with the emulation installed, always tearing it down again so a
-- failing assertion cannot leak the stubs into the next spec.
function AndroidEnv.with(opts, fn)
    local env = AndroidEnv.install(opts)
    local ok, err = pcall(fn, env)
    AndroidEnv.uninstall()
    if not ok then error(err, 0) end
end

-- Real sandbox data directory, created on first use.
function AndroidEnv.sandboxDataDir()
    mkdirp(AndroidEnv.SANDBOX .. "/settings/goodreadskosync")
    return AndroidEnv.SANDBOX
end

return AndroidEnv
