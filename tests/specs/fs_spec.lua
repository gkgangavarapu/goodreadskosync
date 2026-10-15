local Fs = require("goodreadskosync.fs")

-- Run `fn` with a fake frontend `util` installed, so the KOReader path can be
-- exercised off-device. The real module is restored afterwards.
local function with_makepath(makePath, fn)
    local saved_preload = package.preload["util"]
    local saved_loaded = package.loaded["util"]
    package.preload["util"] = function() return { makePath = makePath } end
    package.loaded["util"] = nil
    local ok, err = pcall(fn)
    package.preload["util"] = saved_preload
    package.loaded["util"] = saved_loaded
    if not ok then error(err, 0) end
end

describe("fs.makeDir", function()
    it("creates nested directories without KOReader", function()
        local dir = "./tests/.tmp/fs/no-koreader/a/b/c"
        assert_true(Fs.makeDir(dir))
        local probe = io.open(dir .. "/probe", "w")
        assert_not_nil(probe)
        probe:close()
        os.remove(dir .. "/probe")
    end)

    it("prefers KOReader's util.makePath when it is available", function()
        local asked = {}
        local dir = "/storage/emulated/0/koreader/settings/goodreadskosync"
        with_makepath(function(path)
            asked[#asked + 1] = path
            return true
        end, function()
            assert_true(Fs.makeDir(dir))
        end)
        assert_equal(1, #asked)
        assert_equal(dir, asked[1])
    end)

    it("still creates the directory when makePath is unavailable", function()
        local dir = "./tests/.tmp/fs/no-makepath"
        with_makepath(nil, function()
            -- a makePath that is not a function must not be called
            assert_true(Fs.makeDir(dir))
        end)
        local probe = io.open(dir .. "/probe", "w")
        assert_not_nil(probe)
        probe:close()
        os.remove(dir .. "/probe")
    end)

    it("falls back to the shell when makePath reports failure", function()
        local dir = "./tests/.tmp/fs/makepath-failed"
        with_makepath(function() return false end, function()
            assert_true(Fs.makeDir(dir))
        end)
        local probe = io.open(dir .. "/probe", "w")
        assert_not_nil(probe)
        probe:close()
        os.remove(dir .. "/probe")
    end)

    it("ignores empty input", function()
        assert_false(Fs.makeDir(nil))
        assert_false(Fs.makeDir(""))
        assert_false(Fs.makeDir(42))
    end)
end)
