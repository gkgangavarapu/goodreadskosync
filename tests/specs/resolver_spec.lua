local Resolver = require("goodreadskosync.resolver.resolver")

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
end)
