local Resolver = require("goodreadskosync.resolver.resolver")
local Search = require("goodreadskosync.resolver.search")

local function fakeProvider(candidates)
    return {
        search_books = function()
            return candidates
        end,
    }
end

local function fakeMappings(initial)
    local data = initial or {}
    return {
        get = function(key) return data[key] end,
        put = function(key, value) data[key] = value end,
    }
end

local sapiens = {
    title = "Sapiens",
    authors = { "Yuval Noah Harari" },
    isbn13 = "9780062316097",
}

describe("resolver.resolver", function()
    it("uses a confirmed stored mapping before searching", function()
        local mappings = fakeMappings({
            ["9780062316097"] = {
                goodreads_id = "23692271",
                isbn13 = "9780062316097",
                title = "Sapiens",
                author = "Yuval Noah Harari",
                confirmed = true,
            },
        })
        local result = Resolver.resolve({
            metadata = sapiens,
            mappings = mappings,
            provider = fakeProvider({}),
            no_cache = true,
        })
        assert_equal("mapped", result.status)
        assert_equal("23692271", result.selected.goodreads_id)
    end)

    it("ignores an unconfirmed mapping", function()
        local mappings = fakeMappings({
            ["9780062316097"] = { goodreads_id = "1", confirmed = false },
        })
        local result = Resolver.resolve({
            metadata = sapiens,
            mappings = mappings,
            provider = fakeProvider({ {
                goodreads_id = "23692271", title = "Sapiens",
                authors = { "Yuval Noah Harari" }, isbn13 = "9780062316097",
            } }),
            no_cache = true,
        })
        assert_equal("auto", result.status)
    end)

    it("auto-selects an exact ISBN match", function()
        local result = Resolver.resolve({
            metadata = sapiens,
            provider = fakeProvider({ {
                goodreads_id = "23692271", title = "Sapiens",
                authors = { "Yuval Noah Harari" }, isbn13 = "9780062316097",
            } }),
            no_cache = true,
        })
        assert_equal("auto", result.status)
        assert_equal("23692271", result.selected.goodreads_id)
    end)

    it("asks the user when editions are ambiguous", function()
        local result = Resolver.resolve({
            metadata = { title = "Dune", authors = { "Frank Herbert" } },
            provider = fakeProvider({
                { goodreads_id = "1", title = "Dune", authors = { "Frank Herbert" },
                    publication_year = 1965 },
                { goodreads_id = "2", title = "Dune", authors = { "Frank Herbert" },
                    publication_year = 2005 },
            }),
            no_cache = true,
        })
        assert_true(result.status == "manual" or result.status == "confirm")
        assert_nil(result.selected)
        assert_equal(2, #result.candidates)
    end)

    it("reports unidentified when there are no candidates", function()
        local result = Resolver.resolve({
            metadata = { title = "Nothing", authors = { "No One" } },
            provider = fakeProvider({}),
            no_cache = true,
        })
        assert_equal("unidentified", result.status)
    end)

    it("reports unidentified without a provider", function()
        local result = Resolver.resolve({ metadata = sapiens })
        assert_equal("unidentified", result.status)
        assert_equal("no_provider", result.reason)
    end)

    it("prefers an explicit Goodreads id for the search query", function()
        assert_equal("17306293",
            Search.buildQuery({ goodreads_id = "17306293", title = "Shift" }))
        assert_equal("9780062316097",
            Search.buildQuery({ isbn13 = "9780062316097", title = "Sapiens" }))
        assert_equal("Shift Hugh Howey",
            Search.buildQuery({ title = "Shift", primary_author = "Hugh Howey" }))
    end)

    it("builds a persistent mapping record", function()
        local identity = Resolver.identify(sapiens, nil)
        local record = Resolver.buildMapping(identity.local_key, identity, {
            goodreads_id = "23692271", title = "Sapiens",
            authors = { "Yuval Noah Harari" }, isbn13 = "9780062316097",
        })
        assert_equal("23692271", record.goodreads_id)
        assert_true(record.confirmed)
        assert_equal("Yuval Noah Harari", record.author)
    end)

    it("marks several editions of one work as ambiguous", function()
        local result = Resolver.resolve({
            metadata = { title = "Dune", authors = { "Frank Herbert" } },
            provider = fakeProvider({
                { goodreads_id = "1", title = "Dune", authors = { "Frank Herbert" } },
                { goodreads_id = "2", title = "Dune", authors = { "Frank Herbert" } },
            }),
            no_cache = true,
        })
        assert_true(result.ambiguous)
    end)

    it("does not mark a single clear match as ambiguous", function()
        local result = Resolver.resolve({
            metadata = { title = "Dune", authors = { "Frank Herbert" } },
            provider = fakeProvider({
                { goodreads_id = "1", title = "Dune", authors = { "Frank Herbert" } },
                { goodreads_id = "2", title = "Something Else", authors = { "Other" } },
            }),
            no_cache = true,
        })
        assert_false(result.ambiguous)
    end)

    it("does not mark an identifier match as ambiguous", function()
        local result = Resolver.resolve({
            metadata = sapiens,
            provider = fakeProvider({
                { goodreads_id = "23692271", title = "Sapiens",
                    authors = { "Yuval Noah Harari" }, isbn13 = "9780062316097" },
                { goodreads_id = "2", title = "Sapiens",
                    authors = { "Yuval Noah Harari" } },
            }),
            no_cache = true,
        })
        assert_equal("auto", result.status)
        assert_false(result.ambiguous)
        assert_equal("23692271", result.selected.goodreads_id)
    end)

    it("builds a title query for the fallback", function()
        assert_equal("Sapiens Yuval Noah Harari",
            Search.buildTitleQuery({ title = "Sapiens", primary_author = "Yuval Noah Harari" }))
        assert_equal("Sapiens", Search.buildTitleQuery({ title = "Sapiens" }))
        assert_equal("", Search.buildTitleQuery({}))
    end)

    it("falls back to a title search when an identifier finds nothing", function()
        local asked = {}
        local provider = {
            search_books = function(_, query)
                asked[#asked + 1] = query
                if query == "9780062316097" then return {} end
                return { { goodreads_id = "23692271", title = "Sapiens",
                    authors = { "Yuval Noah Harari" } } }
            end,
        }
        local result = Resolver.resolve({
            metadata = sapiens, provider = provider, no_cache = true,
        })
        assert_equal("9780062316097", asked[1])
        assert_equal("Sapiens Yuval Noah Harari", asked[2])
        assert_equal(1, #result.candidates)
    end)

    it("does not fall back when the query was given explicitly", function()
        local calls = 0
        local provider = {
            search_books = function() calls = calls + 1; return {} end,
        }
        Resolver.resolve({
            metadata = sapiens, provider = provider, no_cache = true, query = "no such book",
        })
        assert_equal(1, calls)
    end)
end)
