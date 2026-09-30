local Constants = require("goodreadskosync.constants")
local Shelves = require("goodreadskosync.sync.shelves")

describe("shelves", function()
    it("accepts Did Not Finish", function()
        assert_true(Shelves.isValid(Constants.SHELF.DID_NOT_FINISH))
        assert_equal("Did Not Finish", Shelves.label(Constants.SHELF.DID_NOT_FINISH))
    end)

    it("never auto-selects Did Not Finish", function()
        assert_equal(Constants.SHELF.CURRENTLY_READING, Shelves.forState(50, "reading"))
        assert_equal(Constants.SHELF.READ, Shelves.forState(100, "complete"))
    end)
end)
