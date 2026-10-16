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

    it("is unambiguous when the file's ISBN pins the edition", function()
        local ranked = Matcher.rank(identity(), {
            candidate(),
            candidate({ isbn13 = false, goodreads_id = "999" }),
        })
        assert_true(ranked[1].has_identifier_match)
        assert_true(Matcher.unambiguous(ranked))
    end)

    it("is ambiguous when two editions of one work tie", function()
        local ranked = Matcher.rank(identity({ isbn13 = false }), {
            candidate({ isbn13 = false, goodreads_id = "1" }),
            candidate({ isbn13 = false, goodreads_id = "2" }),
        })
        assert_equal(2, #ranked)
        assert_equal(1, #Matcher.sameWorkEditions(ranked))
        assert_false(Matcher.unambiguous(ranked))
    end)

    it("is ambiguous when a competing edition is close behind", function()
        -- Same work, different years: the file's year lifts one by only 10 points.
        local ranked = Matcher.rank(
            identity({ isbn13 = false, publication_year = 2015 }), {
                candidate({ isbn13 = false, goodreads_id = "1", publication_year = 2015 }),
                candidate({ isbn13 = false, goodreads_id = "2", publication_year = 2005 }),
            })
        assert_true(ranked[1].score > ranked[2].score)
        assert_true(ranked[1].score - ranked[2].score < 15)
        assert_equal(1, #Matcher.sameWorkEditions(ranked))
        assert_false(Matcher.unambiguous(ranked))
    end)

    it("is unambiguous when the best stands clearly ahead and is alone", function()
        local ranked = Matcher.rank(identity({ isbn13 = false }), {
            candidate({ isbn13 = false, goodreads_id = "1" }),
            { goodreads_id = "2", title = "Something Else", authors = { "Other" } },
        })
        assert_equal(0, #Matcher.sameWorkEditions(ranked))
        assert_true(ranked[1].score - ranked[2].score >= 15)
        assert_true(Matcher.unambiguous(ranked))
    end)

    it("is unambiguous for a single confident match", function()
        local ranked = Matcher.rank(identity({ isbn13 = false }), {
            candidate({ isbn13 = false, goodreads_id = "1" }),
        })
        assert_equal("confirm", ranked[1].decision)
        assert_true(Matcher.unambiguous(ranked))
    end)

    it("is never unambiguous for a weak match", function()
        local ranked = Matcher.rank(identity({ isbn13 = false }), {
            { goodreads_id = "1", title = "Something Else", authors = { "Other" } },
        })
        assert_equal("manual", ranked[1].decision)
        assert_false(Matcher.unambiguous(ranked))
    end)

    it("reports no editions for a single candidate", function()
        local ranked = Matcher.rank(identity(), { candidate() })
        assert_equal(0, #Matcher.sameWorkEditions(ranked))
    end)

    it("treats a series-decorated Goodreads title as the same book", function()
        local ranked = Matcher.rank(identity({ isbn13 = false }), {
            candidate({ isbn13 = false, goodreads_id = "1",
                title = "Sapiens (Sapiens, #1)" }),
        })
        assert_equal("confirm", ranked[1].decision)
        assert_true(Matcher.unambiguous(ranked))
    end)

    it("does not treat a sequel as another edition", function()
        local id = Identifiers.build(
            { title = "Dune", authors = { "Frank Herbert" } }, nil)
        local ranked = Matcher.rank(id, {
            { goodreads_id = "1", title = "Dune (Dune, #1)",
                authors = { "Frank Herbert" } },
            { goodreads_id = "2", title = "Dune Messiah (Dune, #2)",
                authors = { "Frank Herbert" } },
        })
        assert_equal("1", ranked[1].goodreads_id)
        assert_equal(0, #Matcher.sameWorkEditions(ranked))
        assert_true(ranked[1].score - ranked[2].score >= 15)
        assert_true(Matcher.unambiguous(ranked))
    end)
end)
