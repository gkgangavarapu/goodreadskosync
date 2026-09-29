local Storage = require("goodreadskosync.storage")

describe("storage", function()
    it("persists and reloads values through the fallback backend", function()
        Storage.setBaseDir("./tests/.tmp/storage")
        Storage.reset()
        local store = Storage.open("settings")
        store:set("sync_interval", 300)
        store:set("nested", { a = 1, b = { "x", "y" } })
        assert_true(store:flush())

        local reopened = Storage.open("settings")
        assert_equal(300, reopened:get("sync_interval"))
        local nested = reopened:get("nested")
        assert_equal(1, nested.a)
        assert_equal("y", nested.b[2])
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
end)
