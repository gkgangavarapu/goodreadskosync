--[[--
Candidate scoring.

The weights and penalties are intentionally simple and deterministic so they
can be unit tested and reasoned about. Automatic selection is only ever
allowed when a hard identifier matched: a high title/author score alone is
never enough, because multiple editions routinely share a title.

@module koplugin.goodreads.resolver.matcher
--]]

local Constants = require("goodreadskosync.constants")
local Util = require("goodreadskosync.util")

local Matcher = {}

local function candidateAuthors(candidate)
    if type(candidate.authors) == "table" then return candidate.authors end
    if type(candidate.authors) == "string" then
        return Util.splitAuthors(candidate.authors)
    end
    if type(candidate.author) == "string" then
        return Util.splitAuthors(candidate.author)
    end
    return {}
end

local function tokenSet(s)
    local set = {}
    for token in (s or ""):gmatch("%w+") do set[token] = true end
    return set
end

-- Jaccard similarity over word tokens, in [0, 1].
local function similarity(a, b)
    local sa, sb = tokenSet(a), tokenSet(b)
    local intersection, union = 0, 0
    local seen = {}
    for token in pairs(sa) do
        union = union + 1
        seen[token] = true
        if sb[token] then intersection = intersection + 1 end
    end
    for token in pairs(sb) do
        if not seen[token] then union = union + 1 end
    end
    if union == 0 then return 0 end
    return intersection / union
end

local function titleSimilarity(a, b)
    local full = similarity(Util.normalizeTitle(a), Util.normalizeTitle(b))
    local core = similarity(Util.titleCore(a), Util.titleCore(b))
    return math.max(full, core)
end

local function authorSimilarity(a, b)
    return similarity(Util.normalizeAuthor(a), Util.normalizeAuthor(b))
end

-- Score a single candidate against an identity. Returns score, breakdown.
function Matcher.score(identity, candidate)
    local score = 0
    local reasons = {}
    local has_identifier_match = false

    local c_isbn13 = candidate.isbn13
    local c_isbn10 = candidate.isbn10
    local c_gr = candidate.goodreads_id

    if identity.goodreads_id and c_gr
        and tostring(identity.goodreads_id) == tostring(c_gr) then
        score = score + 100
        has_identifier_match = true
        reasons[#reasons + 1] = "goodreads_id+100"
    end

    if identity.isbn13 and c_isbn13 and identity.isbn13 == c_isbn13 then
        score = score + 95
        has_identifier_match = true
        reasons[#reasons + 1] = "isbn13+95"
    elseif identity.isbn10 and c_isbn10 and identity.isbn10 == c_isbn10 then
        score = score + 95
        has_identifier_match = true
        reasons[#reasons + 1] = "isbn10+95"
    elseif identity.isbn13 and c_isbn10 and identity.isbn13 == Util.isbn10to13(c_isbn10) then
        score = score + 95
        has_identifier_match = true
        reasons[#reasons + 1] = "isbn-cross+95"
    end

    if identity.asin and candidate.asin and identity.asin == candidate.asin then
        score = score + 90
        has_identifier_match = true
        reasons[#reasons + 1] = "asin+90"
    end

    local t_sim = titleSimilarity(identity.title, candidate.title)
    if t_sim >= 0.999 then
        score = score + 50
        reasons[#reasons + 1] = "title-exact+50"
    elseif t_sim >= 0.85 then
        score = score + 30
        reasons[#reasons + 1] = "title-close+30"
    elseif t_sim >= 0.6 then
        score = score + 20
        reasons[#reasons + 1] = "title-similar+20"
    elseif t_sim < 0.3 and identity.title and candidate.title then
        score = score - 30
        reasons[#reasons + 1] = "title-mismatch-30"
    end

    local a_sim = authorSimilarity(identity.primary_author, candidateAuthors(candidate)[1])
    if identity.primary_author and candidateAuthors(candidate)[1] then
        if a_sim >= 0.999 then
            score = score + 35
            reasons[#reasons + 1] = "author-exact+35"
        elseif a_sim >= 0.6 then
            score = score + 20
            reasons[#reasons + 1] = "author-similar+20"
        elseif a_sim < 0.3 then
            score = score - 50
            reasons[#reasons + 1] = "author-different-50"
        end
    end

    if identity.publisher and candidate.publisher
        and Util.normalizeAuthor(identity.publisher) == Util.normalizeAuthor(candidate.publisher) then
        score = score + 10
        reasons[#reasons + 1] = "publisher+10"
    end

    if identity.publication_year and candidate.publication_year
        and tonumber(identity.publication_year) == tonumber(candidate.publication_year) then
        score = score + 10
        reasons[#reasons + 1] = "year+10"
    end

    if identity.language and candidate.language
        and identity.language:lower() == candidate.language:lower() then
        score = score + 5
        reasons[#reasons + 1] = "language+5"
    end

    -- Different-edition penalty: same work signals but a conflicting ISBN.
    if identity.isbn13 and c_isbn13 and identity.isbn13 ~= c_isbn13
        and t_sim >= 0.85 and a_sim >= 0.6 then
        score = score - 20
        reasons[#reasons + 1] = "edition-20"
    end

    if score < 0 then score = 0 end
    if score > 100 then score = 100 end
    return score, { reasons = reasons, has_identifier_match = has_identifier_match }
end

-- Decide how a scored candidate may be used.
function Matcher.classify(score, has_identifier_match)
    if score >= Constants.CONFIDENCE.AUTO and has_identifier_match then
        return "auto"
    elseif score >= Constants.CONFIDENCE.CONFIRM then
        return "confirm"
    end
    return "manual"
end

-- Rank and deduplicate candidates. Returns a new list, best first, each entry
-- annotated with `score`, `has_identifier_match`, and `decision`.
function Matcher.rank(identity, candidates)
    local scored = {}
    local seen = {}
    for _, candidate in ipairs(candidates or {}) do
        local key = candidate.goodreads_id or candidate.isbn13 or candidate.asin
            or (candidate.title or "") .. "\1" .. (candidateAuthors(candidate)[1] or "")
        if not seen[key] then
            seen[key] = true
            local score, detail = Matcher.score(identity, candidate)
            local entry = Util.deepcopy(candidate)
            entry.score = score
            entry.has_identifier_match = detail.has_identifier_match
            entry.reasons = detail.reasons
            entry.decision = Matcher.classify(score, detail.has_identifier_match)
            scored[#scored + 1] = entry
        end
    end
    table.sort(scored, function(a, b)
        if a.score == b.score then
            return tostring(a.goodreads_id) < tostring(b.goodreads_id)
        end
        return a.score > b.score
    end)
    return scored
end

-- Pick a single automatic match, or nil if the user must decide.
function Matcher.bestAutomatic(ranked)
    if not ranked or #ranked == 0 then return nil end
    local best = ranked[1]
    if best.decision ~= "auto" then return nil end
    -- Require a clear margin over the runner-up to avoid ambiguous editions.
    if ranked[2] and ranked[2].score == best.score then return nil end
    return best
end

Matcher._similarity = similarity
Matcher._titleSimilarity = titleSimilarity
Matcher._authorSimilarity = authorSimilarity
Matcher.candidateAuthors = candidateAuthors

return Matcher
