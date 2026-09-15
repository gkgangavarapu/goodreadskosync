local Logging = require("goodreadskosync.logging")
local Network = require("goodreadskosync.network")

describe("logging.redact", function()
    it("removes token values", function()
        assert_equal("token=<redacted>", Logging.redact("token=abc123"))
    end)

    it("removes cookie values", function()
        local redacted = Logging.redact("Cookie: sessionid=deadbeef")
        assert_false(redacted:find("deadbeef", 1, true) ~= nil)
    end)

    it("removes authorization headers", function()
        local redacted = Logging.redact("Authorization: Bearer abc.def.ghi")
        assert_false(redacted:find("abc.def.ghi", 1, true) ~= nil)
    end)

    it("removes passwords", function()
        local redacted = Logging.redact("password=hunter2")
        assert_false(redacted:find("hunter2", 1, true) ~= nil)
    end)
end)

describe("logging.diagnosticSummary", function()
    it("includes allowlisted fields only", function()
        local summary = Logging.diagnosticSummary({
            provider = "mock",
            queue_size = 2,
            title = "Sapiens",
            secret = "abc",
        })
        assert_true(summary:find("provider=mock", 1, true) ~= nil)
        assert_true(summary:find("queue_size=2", 1, true) ~= nil)
        assert_nil(summary:find("Sapiens", 1, true))
        assert_nil(summary:find("secret", 1, true))
    end)
end)

describe("logging.levels", function()
    it("round-trips the configured level", function()
        Logging.setLevel("ERROR")
        assert_equal("ERROR", Logging.getLevel())
        Logging.setLevel("INFO")
        assert_equal("INFO", Logging.getLevel())
        Logging.setLevel("ERROR") -- keep the rest of the suite quiet
    end)
end)

describe("network.normalizeStatus", function()
    it("maps success codes to nil", function()
        assert_nil(Network.normalizeStatus(200))
        assert_nil(Network.normalizeStatus(204))
    end)

    it("maps client and server errors to canonical codes", function()
        assert_equal("AUTH_REQUIRED", Network.normalizeStatus(401))
        assert_equal("AUTH_REQUIRED", Network.normalizeStatus(403))
        assert_equal("NOT_FOUND", Network.normalizeStatus(404))
        assert_equal("CONFLICT", Network.normalizeStatus(409))
        assert_equal("INVALID_REQUEST", Network.normalizeStatus(422))
        assert_equal("RATE_LIMITED", Network.normalizeStatus(429))
        assert_equal("SERVER_ERROR", Network.normalizeStatus(500))
        assert_equal("INVALID_RESPONSE", Network.normalizeStatus(418))
        assert_equal("NETWORK_ERROR", Network.normalizeStatus(nil))
    end)
end)
