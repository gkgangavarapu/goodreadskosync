local Reading = require("goodreadskosync.reading")

local CHALLENGE = [==[{"daysRemaining":98,"readingGoal":12,"readingProgress":10,"booksRead":"[{\"sourceOrigin\":\"GOODREADS\",\"bookUri\":\"kca://book/amzn1.gr.book.v1.x\",\"asin\":\"B1\",\"dateRead\":\"2026-09-17\"}]"}]==]

describe("reading", function()
    it("parses reading-challenge JSON", function()
        local c = Reading.parseChallenge(CHALLENGE)
        assert_not_nil(c)
        assert_equal(12, c.goal)
        assert_equal(10, c.books_read)
        assert_equal(98, c.days_remaining)
        assert_equal(1, #c.books)
        assert_equal("B1", c.books[1].asin)
        assert_equal("2026-09-17", c.books[1].date_read)
    end)

    it("falls back to the book list length when progress is absent", function()
        local c = Reading.parseChallenge([[{"readingGoal":5,"booksRead":"[{},{}]"}]])
        assert_equal(2, c.books_read)
    end)

    it("returns nil for invalid JSON", function()
        assert_nil(Reading.parseChallenge("not json"))
    end)

    it("computes percent and pace", function()
        local now = os.time{ year = 2026, month = 9, day = 26, hour = 12 }
        local c = Reading.enrich({ goal = 12, books_read = 10, days_remaining = 98 }, now)
        assert_equal(83, c.percent)
        assert_not_nil(c.pace)
        assert_equal("ahead", c.pace_label)
    end)

    it("handles a missing goal", function()
        local c = Reading.enrich({ goal = 0, books_read = 0 })
        assert_equal(0, c.percent)
        assert_nil(c.pace)
    end)

    it("parses reading-stats rows in order", function()
        local html = [[
<div class="yearCount "><span class="left year">2026</span>
  <span class="count">10</span></div>
<div class="yearCount zeroYear"><span class="left year">2025</span>
  <span class="count">0</span></div>]]
        local years = Reading.parseStats(html)
        assert_equal(2, #years)
        assert_equal(2026, years[1].year)
        assert_equal(10, years[1].books)
        assert_equal(0, years[2].books)
    end)

    it("extracts a hidden input value by name", function()
        local html = [[<input type='hidden' name='anti-csrftoken-a2z' value='tok123' />]]
        assert_equal("tok123", Reading.hiddenInput(html, "anti-csrftoken-a2z"))
        assert_nil(Reading.hiddenInput(html, "missing"))
    end)

    it("knows leap years", function()
        assert_equal(366, Reading.days_in_year(2024))
        assert_equal(365, Reading.days_in_year(2026))
    end)
end)
