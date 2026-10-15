--[[--
crypto_util must never raise.

On Android, no reachable library exports the OpenSSL symbols the module
declares, so `lib.RAND_bytes(...)` raises "undefined symbol" instead of
returning. That used to escape from `Session.save()` right after Goodreads had
accepted the login, so a successful sign-in was reported as a failure. These
specs pin the "degrade to plaintext" contract with fake libraries.
--]]

local srep = string.rep

-- Install a fake `ffi` whose loadlib returns `lib`, plus the datastorage and
-- luasettings stubs getOrCreateKey needs, then run fn with a fresh crypto_util.
local function with_ffi(lib, fn)
    local saved_loaded = {
        ffi = package.loaded["ffi"],
        crypto = package.loaded["goodreadskosync.crypto_util"],
        ds = package.loaded["datastorage"],
        ls = package.loaded["luasettings"],
    }
    local saved_preload = {
        ffi = package.preload["ffi"],
        ds = package.preload["datastorage"],
        ls = package.preload["luasettings"],
    }

    package.loaded["ffi"] = nil
    package.loaded["goodreadskosync.crypto_util"] = nil
    package.loaded["datastorage"] = nil
    package.loaded["luasettings"] = nil

    package.preload["ffi"] = function()
        return {
            cdef = function() end,
            new = function() return {} end,
            string = function(_, n) return srep("x", n or 1) end,
            loadlib = function() return lib end,
        }
    end
    package.preload["datastorage"] = function()
        return { getSettingsDir = function() return "./tests/.tmp" end }
    end
    package.preload["luasettings"] = function()
        return {
            open = function()
                return {
                    readSetting = function() return nil end,
                    saveSetting = function() end,
                    flush = function() end,
                }
            end,
        }
    end

    local ok, err = pcall(function()
        fn(require("goodreadskosync.crypto_util"))
    end)

    package.preload["ffi"] = saved_preload.ffi
    package.preload["datastorage"] = saved_preload.ds
    package.preload["luasettings"] = saved_preload.ls
    package.loaded["ffi"] = saved_loaded.ffi
    package.loaded["goodreadskosync.crypto_util"] = saved_loaded.crypto
    package.loaded["datastorage"] = saved_loaded.ds
    package.loaded["luasettings"] = saved_loaded.ls

    if not ok then error(err, 0) end
end

describe("crypto: library that exports nothing", function()
    -- what Android actually gives us: a handle where every call raises
    local bad = setmetatable({}, {
        __index = function(_, name)
            return function() error("undefined symbol: " .. tostring(name)) end
        end,
    })

    it("is treated as unavailable, not as an error", function()
        with_ffi(bad, function(CryptoUtil)
            local blob, encrypted = CryptoUtil.protect("cookie-jar")
            assert_equal("cookie-jar", blob)
            assert_false(encrypted)
        end)
    end)

    it("round-trips unencrypted values", function()
        with_ffi(bad, function(CryptoUtil)
            assert_equal("cookie-jar", CryptoUtil.unprotect("cookie-jar", false))
        end)
    end)

    it("does not raise from getOrCreateKey", function()
        with_ffi(bad, function(CryptoUtil)
            assert_nil(CryptoUtil.getOrCreateKey())
        end)
    end)
end)

describe("crypto: library without RAND_bytes", function()
    -- the probe (EVP_aes_256_cbc) resolves, but key generation cannot work
    local lib = {
        EVP_aes_256_cbc = function() return {} end,
        RAND_bytes = function() error("undefined symbol: RAND_bytes") end,
    }

    it("still degrades to plaintext instead of raising", function()
        with_ffi(lib, function(CryptoUtil)
            assert_nil(CryptoUtil.getOrCreateKey())
            local blob, encrypted = CryptoUtil.protect("cookie-jar")
            assert_equal("cookie-jar", blob)
            assert_false(encrypted)
        end)
    end)
end)

describe("crypto: usable library", function()
    -- a library that resolves everything must still be used, so the safety
    -- guards do not silently disable encryption
    local lib = {
        EVP_aes_256_cbc = function() return {} end,
        RAND_bytes = function() return 1 end,
    }

    it("generates a key through the library", function()
        with_ffi(lib, function(CryptoUtil)
            local key = CryptoUtil.getOrCreateKey()
            assert_not_nil(key)
            assert_equal(32, #key)
        end)
    end)
end)
