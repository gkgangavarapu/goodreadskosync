local Storage = require("goodreadskosync.storage")

describe("storage", function()
    it("persists and reloads values through the fallback backend", function()
        Storage.setBaseDir("./tests/.tmp/storage")
        Storage.reset()
        local store = Storage.open("settings")
        store:set("sync_interval", 300)
        store:set("nested", { a = 1, b = { "x", "y" } })
        assert_true(store:flush())

        -- Drop the cache so the reload genuinely comes from the file.
        Storage.clearCache()
        local reopened = Storage.open("settings")
        assert_equal(300, reopened:get("sync_interval"))
        local nested = reopened:get("nested")
        assert_equal(1, nested.a)
        assert_equal("y", nested.b[2])
    end)

    it("reuses the opened store instead of re-reading the file", function()
        Storage.setBaseDir("./tests/.tmp/storage")
        Storage.reset()
        assert_true(Storage.open("settings") == Storage.open("settings"))
        -- ... but a fresh store after clearCache.
        local first = Storage.open("settings")
        Storage.clearCache()
        assert_false(first == Storage.open("settings"))
    end)

    it("re-reads from disk after clearCache", function()
        Storage.setBaseDir("./tests/.tmp/storage")
        Storage.reset()
        Storage.open("settings"):set("from_disk", "written by the test")
        Storage.open("settings"):flush()

        -- Simulate another writer touching the file behind the cache's back.
        Storage.clearCache()
        local path = "./tests/.tmp/storage/settings.lua"
        local file = io.open(path, "r")
        assert_not_nil(file)
        local disk = file:read("*a")
        file:close()
        assert_true(disk:find("written by the test", 1, true) ~= nil)
    end)

    it("returns the default for a missing key", function()
        Storage.setBaseDir("./tests/.tmp/storage")
        local store = Storage.open("missing")
        assert_equal("fallback", store:get("nope", "fallback"))
        assert_false(store:has("nope"))
    end)

    it("deletes keys", function()
        Storage.setBaseDir("./tests/.tmp/storage")
        local store = Storage.open("deleteme")
        store:set("a", 1)
        store:flush()
        store:delete("a")
        store:flush()
        assert_false(Storage.open("deleteme"):has("a"))
    end)

    it("treats setting a key to nil as a deletion", function()
        local ls = {
            data = { a = 1 },
            saveSetting = function(self, k, v) self.data[k] = v end,
            delSetting = function(self, k) self.data[k] = nil end,
            flush = function() end,
        }
        local store = Storage._open_luasettings("/tmp/test2.lua", ls)
        store:set("a", nil)
        assert_true(store:flush())
        assert_nil(ls.data.a)
    end)

    it("persists deletions through the LuaSettings backend", function()
        -- LuaSettings keeps every saved key, so a delete must call delSetting
        -- or the value reappears on the next open (e.g. saved password).
        local ls = {
            data = { email = "a@b.c", password = "secret" },
            saveSetting = function(self, k, v) self.data[k] = v end,
            delSetting = function(self, k) self.data[k] = nil end,
            flush = function(self) self.flushed = true end,
        }
        local store = Storage._open_luasettings("/tmp/test.lua", ls)
        assert_equal("secret", store:get("password"))
        store:delete("password")
        assert_true(store:flush())
        assert_nil(ls.data.password)
        assert_equal("a@b.c", ls.data.email)
        assert_true(ls.flushed)
    end)

    it("creates the settings directory when opening a store", function()
        local dir = "./tests/.tmp/storage-missing/nested"
        os.execute('rm -rf "./tests/.tmp/storage-missing"')
        Storage.setBaseDir(dir)
        Storage.clearCache()
        local store = Storage.open("session")
        store:set("current", { state = "valid" })
        assert_true(store:flush())
        local file = io.open(dir .. "/session.lua", "r")
        assert_not_nil(file)
        file:close()
    end)

    it("creates the directory when flushing the LuaSettings backend", function()
        local Fs = require("goodreadskosync.fs")
        local made = {}
        local orig = Fs.makeDir
        Fs.makeDir = function(dir)
            made[#made + 1] = dir
            return true
        end
        local ls = {
            data = {},
            saveSetting = function(self, k, v) self.data[k] = v end,
            flush = function() end,
        }
        local ok, err = pcall(function()
            local store = Storage._open_luasettings("/tmp/missing-grks-dir/session.lua", ls)
            store:set("current", { state = "valid" })
            assert_true(store:flush())
        end)
        Fs.makeDir = orig
        if not ok then error(err, 0) end
        local saw = false
        for _, dir in ipairs(made) do
            if dir == "/tmp/missing-grks-dir" then saw = true end
        end
        assert_true(saw)
    end)

    it("logs a LuaSettings flush error instead of swallowing it", function()
        local Logging = require("goodreadskosync.logging")
        local messages = {}
        local orig = Logging.warn
        Logging.warn = function(...)
            messages[#messages + 1] = table.concat({ ... }, " ")
        end
        local ls = {
            data = {},
            saveSetting = function(self, k, v) self.data[k] = v end,
            flush = function() error("no such file or directory") end,
        }
        local ok, err = pcall(function()
            local store = Storage._open_luasettings("/tmp/grks-flush-fail.lua", ls)
            store:set("current", { state = "valid" })
            assert_false(store:flush())
        end)
        Logging.warn = orig
        if not ok then error(err, 0) end
        assert_true(#messages >= 1)
        assert_true(messages[1]:find("flush failed", 1, true) ~= nil)
        assert_true(messages[1]:find("/tmp/grks-flush-fail.lua", 1, true) ~= nil)
    end)

    it("reloads an already-open store from disk without replacing it", function()
        Storage.setBaseDir("./tests/.tmp/storage")
        Storage.reset()
        local parent = Storage.open("session")
        parent:set("current", { state = "unknown" })
        assert_true(parent:flush())

        -- A forked child writes a new session.lua while the parent still
        -- holds the pre-fork store. Simulate that with a side-channel write.
        local path = "./tests/.tmp/storage/session.lua"
        local file = io.open(path, "w")
        assert_not_nil(file)
        file:write('return {current={state="valid",user_id="123"}}\n')
        file:close()

        -- Before reload the parent still sees the stale in-memory copy.
        assert_equal("unknown", parent:get("current").state)

        Storage.reload()
        assert_true(parent == Storage.open("session"))
        assert_equal("valid", parent:get("current").state)
        assert_equal("123", parent:get("current").user_id)

        -- A later flush of the same object must not restore the stale data.
        parent:set("extra", true)
        assert_true(parent:flush())
        Storage.clearCache()
        local reopened = Storage.open("session")
        assert_equal("valid", reopened:get("current").state)
        assert_equal("123", reopened:get("current").user_id)
        assert_true(reopened:get("extra"))
    end)
end)
