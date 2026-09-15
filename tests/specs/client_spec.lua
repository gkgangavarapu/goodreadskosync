local Client = require("goodreadskosync.goodreads.client")
local Constants = require("goodreadskosync.constants")
local FakeHttp = require("support.fake_http")
local Http = require("goodreadskosync.goodreads.http")

local AUTO_COMPLETE = [==[[{"imageUrl":"http://img/cover.jpg","bookId":"23692271",
"title":"Sapiens: A Brief History of Humankind","numPages":512,
"author":{"id":1,"name":"Yuval Noah Harari"},
"bookUrl":"/book/show/23692271-sapiens"}]]==]

local BOOK_HTML = [[<html><head>
<script type="application/ld+json">{"@type":"Book","name":"Sapiens","image":"http://img","author":[{"@type":"Person","name":"Yuval Noah Harari"}]}</script>
</head><body><span>"numPages":512</span></body></html>]]

local REVIEW_EDIT = [[<html><body>
<a href="/book/show/23692271">book</a>
<script>{"shelf":{"__typename":"Shelf","name":"currently-reading"}}</script>
<input name="review[rating]" value="4">
</body></html>]]

local function client_with(responses)
    local transport, calls = FakeHttp.scripted(responses)
    local http = Http:new{ transport = transport }
    return Client:new(http), http, calls
end

describe("goodreads.client", function()
    it("normalizes auto-complete search results", function()
        local client = client_with({ { status = 200, body = AUTO_COMPLETE } })
        local results, err = client:search_books("sapiens")
        assert_nil(err)
        assert_equal(1, #results)
        assert_equal("23692271", results[1].goodreads_id)
        assert_equal("Sapiens: A Brief History of Humankind", results[1].title)
        assert_equal("Yuval Noah Harari", results[1].authors[1])
        assert_equal(512, results[1].pages)
    end)

    it("annotates an identifier query so the matcher sees a hard match", function()
        local client = client_with({ { status = 200, body = AUTO_COMPLETE } })
        local results = client:search_books("9780062316097")
        assert_equal("9780062316097", results[1].isbn13)
    end)

    it("parses a book page", function()
        local client = client_with({ { status = 200, body = BOOK_HTML } })
        local book = client:get_book("23692271")
        assert_equal("Sapiens", book.title)
        assert_equal("Yuval Noah Harari", book.authors[1])
        assert_equal(512, book.pages)
    end)

    it("writes a shelf with the CSRF token", function()
        local client, http, calls = client_with({ { status = 200 } })
        http.csrf_token = "C"
        assert_true(client:set_shelf("42", Constants.SHELF.CURRENTLY_READING))
        assert_true(calls[1].url:find("/shelf/add_to_shelf", 1, true) ~= nil)
        assert_true(calls[1].body:find("book_id=42", 1, true) ~= nil)
        assert_true(calls[1].body:find("name=currently%-reading") ~= nil)
        assert_equal("C", calls[1].headers["X-CSRF-Token"])
    end)

    it("writes progress as a percent only", function()
        local client, http, calls = client_with({ { status = 200 } })
        http.csrf_token = "C"
        assert_true(client:update_progress("42", 67.4))
        assert_true(calls[1].body:find("user_status%5Bpercent%5D=67", 1, true) ~= nil)
        assert_nil(calls[1].body:find("user_status%5Bpage%5D", 1, true))
    end)

    it("sets a rating via the review endpoint", function()
        local client, http, calls = client_with({ { status = 204 } })
        http.csrf_token = "C"
        assert_true(client:set_rating("42", 4))
        assert_true(calls[1].url:find("rating=4", 1, true) ~= nil)
    end)

    it("removes a shelf", function()
        local client, http, calls = client_with({ { status = 200 } })
        http.csrf_token = "C"
        assert_true(client:remove_shelf("42"))
        assert_true(calls[1].url:find("/review/destroy/42", 1, true) ~= nil)
    end)

    it("reads shelf and rating state", function()
        local client = client_with({ { status = 200, body = REVIEW_EDIT } })
        local state = client:get_book_shelves("23692271")
        assert_equal(Constants.SHELF.CURRENTLY_READING, state.shelf)
        assert_equal(4, state.rating)
    end)
end)
