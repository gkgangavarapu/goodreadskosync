local ShelfCache = require("goodreadskosync.sync.shelf_cache")

describe("shelf_cache.needsRefresh", function()
    it("always refreshes when forced", function()
        assert_true(ShelfCache.needsRefresh({ remote_shelf_at = 1000 }, 1000, true, 3600))
    end)

    it("refreshes when the cache is missing", function()
        assert_true(ShelfCache.needsRefresh({}, 1000, false, 3600))
        assert_true(ShelfCache.needsRefresh(nil, 1000, false, 3600))
    end)

    it("reuses a fresh cache", function()
        assert_false(ShelfCache.needsRefresh({ remote_shelf_at = 1000 }, 2000, false, 3600))
    end)

    it("refreshes once the ttl has passed", function()
        assert_true(ShelfCache.needsRefresh({ remote_shelf_at = 1000 }, 1000 + 3601, false, 3600))
        assert_false(ShelfCache.needsRefresh({ remote_shelf_at = 1000 }, 1000 + 3599, false, 3600))
    end)

    it("treats a malformed timestamp as missing", function()
        assert_true(ShelfCache.needsRefresh({ remote_shelf_at = "x" }, 2000, false, 3600))
    end)
end)

describe("shelf_cache.apply", function()
    it("stores the shelf, rating and timestamp", function()
        local state = {}
        ShelfCache.apply(state, { shelf = "want_to_read", rating = 4 }, 123)
        assert_equal("want_to_read", state.remote_shelf)
        assert_equal(4, state.remote_rating)
        assert_equal(123, state.remote_shelf_at)
    end)

    it("caches an empty remote so a removed book is not refetched", function()
        local state = {}
        ShelfCache.apply(state, { shelf = nil }, 50)
        assert_nil(state.remote_shelf)
        assert_equal(50, state.remote_shelf_at)
    end)

    it("ignores a failed read", function()
        local state = { remote_shelf = "read", remote_shelf_at = 5 }
        ShelfCache.apply(state, nil, 999)
        assert_equal("read", state.remote_shelf)
        assert_equal(5, state.remote_shelf_at)
    end)
end)

describe("shelf_cache.invalidate", function()
    it("updates the cached shelf after a local write", function()
        local state = { remote_shelf_at = 10 }
        ShelfCache.invalidate(state, "read", 99)
        assert_equal("read", state.remote_shelf)
        assert_equal(99, state.remote_shelf_at)
    end)
end)
