local Identifiers = require("goodreadskosync.resolver.identifiers")
local Matcher = require("goodreadskosync.resolver.matcher")

local function identity(overrides)
    local base = {
        title = "Sapiens",
        authors = { "Yuval Noah Harari" },
        isbn13 = "9780062316097",
    }
    for k, v in pairs(overrides or {}) do
        if v == false then base[k] = nil else base[k] = v end
    end
    return Identifiers.build(base, nil)
end

local function candidate(overrides)
    local base = {
        goodreads_id = "23692271",
        title = "Sapiens",
        authors = { "Yuval Noah Harari" },
        isbn13 = "9780062316097",
        publication_year = 2015,
    }
    for k, v in pairs(overrides or {}) do
        if v == false then base[k] = nil else base[k] = v end
    end
    return base
end

describe("resolver.matcher", function()
    it("scores an exact Goodreads ID match as automatic", function()
        local id = identity({ isbn13 = false, goodreads_id = "23692271" })
        local ranked = Matcher.rank(id, { candidate({ isbn13 = false }) })
        assert_equal("auto", ranked[1].decision)
        assert_true(ranked[1].score >= 90)
    end)

    it("scores an exact ISBN match as automatic", function()
        local ranked = Matcher.rank(identity(), { candidate() })
        assert_equal("auto", ranked[1].decision)
        assert_true(ranked[1].has_identifier_match)
    end)

    it("never auto-selects on title/author alone", function()
        local id = identity({ isbn13 = false })
        local ranked = Matcher.rank(id, {
            candidate({ isbn13 = false, goodreads_id = false, publisher = "Harper" }),
        })
        assert_false(ranked[1].has_identifier_match)
        assert_false(ranked[1].decision == "auto")
        assert_true(ranked[1].decision == "confirm" or ranked[1].decision == "manual")
    end)

    it("penalizes a clearly different author", function()
        local id = identity({ isbn13 = false })
        local ranked = Matcher.rank(id, {
            candidate({ isbn13 = false, goodreads_id = false,
                authors = { "Completely Different" } }),
        })
        assert_true(ranked[1].score < 50)
    end)

    it("deduplicates candidates by identity", function()
        local ranked = Matcher.rank(identity(), { candidate(), candidate() })
        assert_equal(1, #ranked)
    end)

    it("prefers the higher-scoring candidate", function()
        local ranked = Matcher.rank(identity(), {
            candidate({ isbn13 = "9780000000000", goodreads_id = "1",
                title = "Something Else", authors = { "Other" } }),
            candidate(),
        })
        assert_equal("23692271", ranked[1].goodreads_id)
    end)

    it("does not pick an automatic match when the top two tie", function()
        local id = identity({ isbn13 = false, goodreads_id = false })
        local ranked = Matcher.rank(id, {
            candidate({ isbn13 = false, goodreads_id = "1" }),
            candidate({ isbn13 = false, goodreads_id = "2" }),
        })
        assert_nil(Matcher.bestAutomatic(ranked))
    end)
end)
