--[[--
Reading Challenge and reading-stats parsing/derivation.

Pure helpers with no KOReader dependencies, so they run on stock Lua 5.1 in the
unit suite. The Goodreads HTTP calls live in goodreads/api.lua; the UI lives in
ui/reading.lua.

@module koplugin.goodreads.reading
--]]

local Json = require("goodreadskosync.goodreads.json")

local Reading = {}

-- Parse the JSON from GET /readingchallenges/goals/data.
-- Shape: { daysRemaining, readingGoal, readingProgress, booksRead = "<json>" }
function Reading.parseChallenge(text)
    local decoded = Json.decode_any(text)
    if type(decoded) ~= "table" then return nil, "invalid json" end

    local books = {}
    if type(decoded.booksRead) == "string" and decoded.booksRead ~= "" then
        local list = Json.decode_any(decoded.booksRead)
        if type(list) == "table" then
            for i = 1, #list do
                local b = list[i]
                if type(b) == "table" then
                    books[#books + 1] = {
                        book_uri = b.bookUri,
                        asin = b.asin,
                        date_read = b.dateRead,
                    }
                end
            end
        end
    end

    local read = tonumber(decoded.readingProgress)
    if read == nil then read = #books end

    return {
        goal = tonumber(decoded.readingGoal) or 0,
        books_read = read,
        days_remaining = tonumber(decoded.daysRemaining),
        books = books,
    }
end

local function days_in_year(year)
    if (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0 then return 366 end
    return 365
end
Reading.days_in_year = days_in_year

-- Add derived fields (percent, expected, pace) used by the UI.
function Reading.enrich(challenge, now)
    challenge = challenge or {}
    now = now or os.time()
    local goal = tonumber(challenge.goal) or 0
    local read = tonumber(challenge.books_read) or 0
    local out = {
        goal = goal,
        books_read = read,
        days_remaining = challenge.days_remaining,
        books = challenge.books or {},
        percent = 0,
        pace = nil,
        pace_diff = nil,
        pace_label = nil,
    }
    if goal > 0 then
        out.percent = math.floor((read / goal) * 100 + 0.5)
    end

    local days = tonumber(challenge.days_remaining)
    if goal > 0 and days then
        local year = tonumber(os.date("%Y", now)) or 1970
        local total = days_in_year(year)
        if days > total then days = total end
        if days < 0 then days = 0 end
        local elapsed = total - days
        local expected = goal * (elapsed / total)
        local diff = read - expected
        out.pace = { expected = expected, diff = diff }
        out.pace_diff = diff
        if diff >= 0.5 then
            out.pace_label = "ahead"
        elseif diff <= -0.5 then
            out.pace_label = "behind"
        else
            out.pace_label = "on_track"
        end
    end
    return out
end

-- Parse GET /review/stats/<user_id>. The server renders rows as
--   class="left year">2026 ... class="count">10
-- so we read the (year, book count) pairs in document order.
function Reading.parseStats(html)
    local years = {}
    if type(html) ~= "string" then return years end
    for year, count in html:gmatch('class="left year">(%d%d%d%d).-class="count">(%d+)') do
        years[#years + 1] = { year = tonumber(year), books = tonumber(count) }
    end
    return years
end

-- Pull a hidden input value out of an HTML page (attribute order agnostic).
-- Returns nil when absent.
function Reading.hiddenInput(html, name)
    if type(html) ~= "string" or type(name) ~= "string" then return nil end
    local escaped = name:gsub("([^%w])", "%%%1")
    local value = html:match("<input[^>]-name='"
        .. escaped .. "'[^>]-value='([^']*)'")
        or html:match('<input[^>]-name="'
        .. escaped .. '"[^>]-value="([^"]*)"')
        or html:match("<input[^>]-value='([^']*)'[^>]-name='"
        .. escaped .. "'")
        or html:match('<input[^>]-value="([^"]*)"[^>]-name="'
        .. escaped .. '"')
    if value == nil or value == "" then return nil end
    return value
end

return Reading
