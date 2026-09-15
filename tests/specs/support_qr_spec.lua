local SupportQR = require("goodreadskosync.ui.support_qr")

describe("support_qr", function()
    it("encodes the Buy Me a Coffee URL", function()
        assert_equal("https://buymeacoffee.com/gkgangavarapu", SupportQR.url)
    end)

    it("is a square 29x29 matrix of 0/1 digits", function()
        assert_equal(29, SupportQR.modules)
        assert_equal(29, #SupportQR.rows)
        for _, row in ipairs(SupportQR.rows) do
            assert_equal(29, #row)
            assert_true(row:match("^[01]+$") ~= nil)
        end
    end)

    it("has the three finder patterns in the expected corners", function()
        local finder = "1111111"
        assert_equal(finder, SupportQR.rows[1]:sub(1, 7))
        assert_equal(finder, SupportQR.rows[1]:sub(-7))
        assert_equal(finder, SupportQR.rows[29]:sub(1, 7))
    end)
end)
