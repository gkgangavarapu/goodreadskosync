local Util = require("goodreadskosync.util")

describe("util.sha256", function()
    it("hashes the empty string", function()
        assert_equal(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            Util.sha256Hex(""))
    end)

    it("hashes 'abc'", function()
        assert_equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            Util.sha256Hex("abc"))
    end)

    it("hashes a longer message spanning multiple blocks", function()
        assert_equal(
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            Util.sha256Hex(
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
    end)
end)

describe("util.isbn", function()
    it("validates ISBN-10 including X check digit", function()
        assert_true(Util.isValidIsbn10("0-306-40615-2"))
        assert_true(Util.isValidIsbn10("0306406152"))
        assert_true(Util.isValidIsbn10("080442957X"))
        assert_false(Util.isValidIsbn10("0306406153"))
        assert_false(Util.isValidIsbn10("123"))
    end)

    it("validates ISBN-13", function()
        assert_true(Util.isValidIsbn13("978-0-306-40615-7"))
        assert_true(Util.isValidIsbn13("9780306406157"))
        assert_false(Util.isValidIsbn13("9780306406158"))
        assert_false(Util.isValidIsbn13("1234567890123"))
    end)

    it("converts ISBN-10 to ISBN-13", function()
        assert_equal("9780306406157", Util.isbn10to13("0306406152"))
        assert_equal("9780306406157", Util.isbn10to13("0-306-40615-2"))
    end)

    it("converts ISBN-13 to ISBN-10 only for 978 prefixes", function()
        assert_equal("0306406152", Util.isbn13to10("9780306406157"))
        assert_nil(Util.isbn13to10("9791234567896"))
    end)

    it("round-trips conversion", function()
        assert_equal("0306406152", Util.isbn13to10(Util.isbn10to13("0306406152")))
    end)

    it("finds ISBNs in free text and metadata strings", function()
        local found = Util.findIsbns("identifier: ISBN:9780062316097 extra")
        assert_equal(1, #found)
        assert_equal("9780062316097", found[1])
    end)

    it("rejects invalid ISBN-looking numbers", function()
        assert_equal(0, #Util.findIsbns("1234567890123"))
    end)
end)

describe("util.asin", function()
    it("accepts B-prefixed 10-character identifiers", function()
        assert_true(Util.isAsin("B00J8QK4CE"))
    end)

    it("rejects arbitrary 10-character identifiers", function()
        assert_false(Util.isAsin("0B00J8QK4C"))
        assert_false(Util.isAsin("B00J8QK4C"))
        assert_false(Util.isAsin("B00J8QK4CE1"))
    end)

    it("finds ASINs with word boundaries", function()
        local found = Util.findAsins("ASIN: B00J8QK4CE and B00J8QK4CE again")
        assert_equal(1, #found)
        assert_equal("B00J8QK4CE", found[1])
    end)
end)

describe("util.goodreads_id", function()
    it("finds explicit goodreads identifiers", function()
        assert_equal("23692271", Util.findGoodreadsIds("Goodreads ID: 23692271")[1])
        assert_equal("1234", Util.findGoodreadsIds("goodreads:1234")[1])
        assert_equal("5", Util.findGoodreadsIds(
            "https://www.goodreads.com/book/show/5")[1])
    end)

    it("does not infer an id from a bare number", function()
        assert_equal(0, #Util.findGoodreadsIds("9780062316097"))
    end)
end)

describe("util.normalization", function()
    it("normalizes whitespace and punctuation", function()
        assert_equal("the hobbit", Util.normalizeTitle("  The   Hobbit "))
        assert_equal("sapiens", Util.normalizeTitle("Sapiens"))
    end)

    it("decodes entities", function()
        assert_equal("Tom & Jerry", Util.decodeEntities("Tom &amp; Jerry"))
        assert_equal("café", Util.decodeEntities("caf&#233;"))
    end)

    it("strips subtitles from the core title", function()
        assert_equal("sapiens", Util.titleCore("Sapiens: A Brief History"))
    end)

    it("splits multiple authors", function()
        local list = Util.splitAuthors("Yuval Noah Harari")
        assert_equal(1, #list)
        assert_equal("Yuval Noah Harari", list[1])
        assert_equal(2, #Util.splitAuthors("Frank Herbert and Bill Ransom"))
        assert_equal(2, #Util.splitAuthors("A; B"))
    end)

    it("normalizes authors for matching", function()
        assert_equal("yuval n harari", Util.normalizeAuthor("Yuval N. Harari"))
    end)
end)

describe("util.localKey", function()
    it("prefers ISBN13 over other identifiers", function()
        assert_equal("9780062316097", Util.localKey({
            isbn13 = "9780062316097",
            asin = "B00J8QK4CE",
            title = "Sapiens",
        }))
    end)

    it("falls back to a metadata hash", function()
        local key = Util.localKey({ title = "Dune", primary_author = "Frank Herbert" })
        assert_true(key:match("^sha:[0-9a-f]+$") ~= nil)
    end)

    it("is stable across reordering", function()
        local a = Util.localKey({ title = "Dune", primary_author = "Frank Herbert" })
        local b = Util.localKey({ primary_author = "Frank Herbert", title = "Dune" })
        assert_equal(a, b)
    end)
end)

describe("util.percentToInt", function()
    it("rounds to the nearest whole percent", function()
        assert_equal(68, Util.percentToInt(0.678))
        assert_equal(67, Util.percentToInt(0.674))
        assert_equal(100, Util.percentToInt(1.5))
        assert_equal(0, Util.percentToInt(-1))
        assert_nil(Util.percentToInt(nil))
    end)
end)
