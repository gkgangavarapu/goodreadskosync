--[[--
Rating helpers.

A rating is never submitted without an explicit user action, and the prompt is
remembered so it does not repeat.

@module koplugin.goodreads.sync.rating
--]]

local Rating = {}

function Rating.isValid(value)
    local n = tonumber(value)
    return n ~= nil and n == math.floor(n) and n >= 1 and n <= 5
end

function Rating.formatStars(value)
    local n = tonumber(value) or 0
    if n < 0 then n = 0 end
    if n > 5 then n = 5 end
    return string.rep("\226\152\133", n) .. string.rep("\226\152\134", 5 - n)
end

-- Whether to prompt for a rating for this book.
function Rating.shouldPrompt(state)
    if type(state) ~= "table" then return false end
    if state.rating ~= nil then return false end
    if state.rating_prompted then return false end
    return true
end

function Rating.markPrompted(state, outcome)
    state.rating_prompted = true
    state.rating_prompt_outcome = outcome
    return state
end

return Rating
