local Update = require("goodreadskosync.update")

local RELEASE = [==[{"tag_name":"v0.5.0","assets":[
{"browser_download_url":"https://github.com/gkgangavarapu/goodreadskosync/releases/download/v0.5.0/goodreadskosync-0.5.0.zip"},
{"browser_download_url":"https://github.com/gkgangavarapu/goodreadskosync/releases/download/v0.5.0/goodreadskosync-0.5.0.zip.sha256"}
]}]==]

describe("update.parse_release", function()
    it("parses the version and asset URLs", function()
        local info = Update.parse_release(RELEASE)
        assert_not_nil(info)
        assert_equal("0.5.0", info.version)
        assert_true(info.zip_url:match("%.zip$") ~= nil)
        assert_true(info.sha_url:match("%.sha256$") ~= nil)
    end)

    it("returns nil when the repo/response is missing", function()
        assert_nil(Update.parse_release('{"message":"Not Found"}'))
        assert_nil(Update.parse_release(nil))
    end)
end)

describe("update.normalize_channel", function()
    it("keeps dev, defaults everything else to stable", function()
        assert_equal("dev", Update.normalize_channel("dev"))
        assert_equal("stable", Update.normalize_channel("stable"))
        assert_equal("stable", Update.normalize_channel(nil))
        assert_equal("stable", Update.normalize_channel("weird"))
    end)
end)

describe("update.is_newer", function()
    it("compares semantic versions", function()
        assert_true(Update.is_newer("0.5.0", "0.4.0"))
        assert_false(Update.is_newer("0.4.0", "0.4.0"))
        assert_false(Update.is_newer("0.3.9", "0.4.0"))
        assert_true(Update.is_newer("1.0.0", "0.9.9"))
        assert_true(Update.is_newer("0.4.1", "0.4"))
    end)

    it("ignores a -dev suffix", function()
        assert_true(Update.is_newer("1.18.3-dev", "1.17.4"))
        assert_false(Update.is_newer("1.18.3", "1.18.3-dev"))
    end)
end)

describe("update.release_from_table", function()
    it("reads the version (stripping v and -dev) and asset URLs", function()
        local info = Update.release_from_table({
            tag_name = "v1.18.3-dev",
            html_url = "https://github.com/x/y/releases/tag/v1.18.3-dev",
            assets = {
                { browser_download_url = "https://x/goodreadskosync-1.18.3.zip" },
                { browser_download_url = "https://x/goodreadskosync-1.18.3.zip.sha256" },
            },
        })
        assert_equal("1.18.3", info.version)
        assert_true(info.zip_url:match("%.zip$") ~= nil)
        assert_true(info.sha_url:match("%.zip%.sha256$") ~= nil)
    end)

    it("returns nil without a tag", function()
        assert_nil(Update.release_from_table({ assets = {} }))
        assert_nil(Update.release_from_table(nil))
    end)
end)
