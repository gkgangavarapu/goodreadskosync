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

describe("update.is_newer", function()
    it("compares semantic versions", function()
        assert_true(Update.is_newer("0.5.0", "0.4.0"))
        assert_false(Update.is_newer("0.4.0", "0.4.0"))
        assert_false(Update.is_newer("0.3.9", "0.4.0"))
        assert_true(Update.is_newer("1.0.0", "0.9.9"))
        assert_true(Update.is_newer("0.4.1", "0.4"))
    end)
end)
