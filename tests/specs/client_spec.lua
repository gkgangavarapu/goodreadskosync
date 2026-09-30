local Api = require("goodreadskosync.goodreads.api")
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

local BOOK_HTML_RATED = [[<html><head>
<script type="application/ld+json">{"@type":"Book","name":"Dune","image":"http://img/dune.jpg","author":[{"@type":"Person","name":"Frank Herbert"}],"aggregateRating":{"ratingValue":4.25,"ratingCount":1234,"reviewCount":56},"description":"<i>A</i> novel","publisher":"Penguin","datePublished":"1965"}</script>
</head><body></body></html>]]

-- Community review cards as server-rendered by Goodreads (per-review stars are
-- JS-filled, so often absent).
-- Recommendations: covers are plain anchors; title/author/rating live inside
-- JS tooltip strings with escaped quotes.
local AUTHORS_SEARCH = [[<html><body>
<span class="BookAuthors" data-testid="book-item-contributors"><a class="ContributorLink" href="https://www.goodreads.com/author/show/38550.Brandon_Sanderson"><span class="ContributorLink__name" data-testid="name">Brandon Sanderson</span><span class="ContributorLink__badge">Goodreads Author</span></a></span>
<a class="ContributorLink" href="https://www.goodreads.com/author/show/123.Jane_Doe"><span class="ContributorLink__name" data-testid="name">Jane Doe</span></a>
</body></html>]]

local AUTHOR_PAGE = [[<html><body>
<a class="bookTitle" href="/book/show/68428.Mistborn">Mistborn: The Final Empire</a>
<a class="bookTitle" href="/book/show/68429.The_Well_of_Ascension">The Well of Ascension</a>
</body></html>]]

local RECS_HTML = [[<html><body>
<a href="/book/show/406235.Giovanni_s_Room"><img alt="Giovanni’s Room" class="bookImage" src="https://i.gr-assets.com/images/S/compressed.photo.goodreads.com/books/1223664870l/406235.jpg" /></a>
<a href="/book/show/157993.The_Little_Prince"><img alt="The Little Prince" class="bookImage" src="https://i.gr-assets.com/images/S/compressed.photo.goodreads.com/books/x.jpg" /></a>
<script>
 var newTip = new Tip($('bookCover145338_406235'), "\n\n  <h2><a class=\"readable bookTitle\" href=\"https://www.goodreads.com/book/show/406235.Giovanni_s_Room\">Giovanni’s Room<\/a><\/h2>\n\n      <div>\n        by <a class=\"authorName\" href=\"/author/show/10427\">James Baldwin<\/a>\n      <\/div>\n      <span class=\"minirating\">3.95 avg rating — 12,345 ratings<\/span>\n");
 var newTip = new Tip($('bookCover1_157993'), "<a class=\"bookTitle\" href=\"https://www.goodreads.com/book/show/157993\">The Little Prince<\/a> by <a class=\"authorName\" href=\"/author/show/2\">Antoine de Saint-Exupéry<\/a> <span class=\"minirating\">4.32 avg rating<\/span>");
</script>
<a href="/recommendations?page=2">Next</a>
</body></html>]]

local REVIEWS_HTML = [[<html><body>
<div class="ReviewsList">
<article class="ReviewCard" aria-label="Review by Jason">
  <div data-testid="name" class="ReviewerProfile__name"><a href="https://www.goodreads.com/user/show/1">Jason</a></div>
  <span aria-label="Rating 4 out of 5"></span>
  <section class="ReviewCard__content"><section class="ReviewCard__row"><span class="Formatted">A great <i>book</i> indeed.<br />Loved it.</span></section></section>
</article>
<article class="ReviewCard" aria-label="Review by Ana">
  <div data-testid="name" class="ReviewerProfile__name"><a href="https://www.goodreads.com/user/show/2">Ana</a></div>
  <section class="ReviewCard__content"><section class="ReviewCard__row"><span class="Formatted">Not for me.</span></section></section>
</article>
</div>
<a>More reviews</a>
</body></html>]]

-- One real "My Books" review row: cover (id="cover_"), absolute book URL,
-- average rating column, and the newer data-rating star widget.
local SHELF_HTML = [[<html><body>
<tr id="review_1" class="bookalike review">
  <td class="field cover"><div class="value"><div class="js-tooltipTrigger" data-resource-id="11012"><a href="https://www.goodreads.com/book/show/11012.Dubliners"><img alt="Dubliners" id="cover_review_1" src="https://i.gr-assets.com/images/S/compressed.photo.goodreads.com/books/1756682305l/11012._SY75_.jpg" /></a></div></div></td>
  <td class="field title"><div class="value"><a title="Dubliners" href="https://www.goodreads.com/book/show/11012.Dubliners">Dubliners</a></div></td>
  <td class="field author"><div class="value"><a href="https://www.goodreads.com/author/show/5144.James_Joyce">Joyce, James</a></div></td>
  <td class="field avg_rating"><label>avg rating</label><div class="value">3.83</div></td>
  <td class="field rating"><div class="value"><div class="stars" data-resource-id="11012" data-rating="4.0"><a class="star on" title="really liked it" href="#">4 of 5 stars</a></div></div></td>
</tr>
</body></html>]]

local REVIEW_EDIT = [[<html><body>
<a href="/book/show/23692271">book</a>
<script>{"shelf":{"__typename":"Shelf","name":"currently-reading"}}</script>
<input name="review[rating]" value="4">
</body></html>]]

-- Every write first GETs a normal app page to refresh the CSRF token.
local CSRF_PAGE = [[<html><head><meta name="csrf-token" content="C"></head>
<body><a href="/user/show/999">me</a></body></html>]]

local function client_with(responses)
    local transport, calls = FakeHttp.scripted(responses)
    local http = Http:new{ transport = transport }
    return Api:new(http), http, calls
end

describe("goodreads.api", function()
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
        local client, _, calls = client_with({ { status = 200, body = CSRF_PAGE }, { status = 200 } })
        assert_true(client:set_shelf("42", Constants.SHELF.CURRENTLY_READING))
        assert_true(calls[2].url:find("/shelf/add_to_shelf", 1, true) ~= nil)
        assert_true(calls[2].body:find("book_id=42", 1, true) ~= nil)
        assert_true(calls[2].body:find("name=currently%-reading") ~= nil)
        assert_equal("C", calls[2].headers["X-CSRF-Token"])
    end)

    it("writes progress as a percent only", function()
        local client, _, calls = client_with({ { status = 200, body = CSRF_PAGE }, { status = 200 } })
        assert_true(client:update_progress("42", 67.4))
        assert_true(calls[2].body:find("user_status%5Bpercent%5D=67", 1, true) ~= nil)
        assert_nil(calls[2].body:find("user_status%5Bpage%5D", 1, true))
    end)

    it("sets a rating via the review endpoint", function()
        local client, _, calls = client_with({ { status = 200, body = CSRF_PAGE }, { status = 204 } })
        assert_true(client:set_rating("42", 4))
        assert_true(calls[2].url:find("rating=4", 1, true) ~= nil)
    end)

    it("removes a shelf", function()
        local client, _, calls = client_with({ { status = 200, body = CSRF_PAGE }, { status = 200 } })
        assert_true(client:remove_shelf("42"))
        assert_true(calls[2].url:find("/review/destroy/42", 1, true) ~= nil)
    end)

    it("reads shelf and rating state", function()
        local client = client_with({ { status = 200, body = REVIEW_EDIT } })
        local state = client:get_book_shelves("23692271")
        assert_equal(Constants.SHELF.CURRENTLY_READING, state.shelf)
        assert_equal(4, state.rating)
    end)

    it("reads the annual reading challenge", function()
        local json = '{"daysRemaining":98,"readingGoal":12,"readingProgress":10,"booksRead":"[]"}'
        local client = client_with({ { status = 200, body = json } })
        local challenge = client:get_reading_challenge()
        assert_equal(12, challenge.goal)
        assert_equal(10, challenge.books_read)
    end)

    it("writes the reading goal using the WAF token", function()
        local page = [[<input type='hidden' name='anti-csrftoken-a2z' value='TOK' />]]
        local client, _, calls = client_with({ { status = 200, body = page }, { status = 200 } })
        assert_true(client:set_reading_goal(30))
        assert_true(calls[1].url:find("/readingchallenges/annual", 1, true) ~= nil)
        assert_true(calls[2].url:find("newGoal=30", 1, true) ~= nil)
        assert_equal("TOK", calls[2].headers["anti-csrftoken-a2z"])
    end)

    it("rejects an invalid reading goal before any request", function()
        local client, _, calls = client_with({ { status = 200 } })
        local ok, err = client:set_reading_goal(0)
        assert_false(ok)
        assert_equal(Constants.ERROR.INVALID_REQUEST, err)
        assert_equal(0, #calls)
    end)

    it("reads per-year reading stats", function()
        local html = [[<span class="left year">2026</span> <span class="count">10</span>]]
        local client, http = client_with({ { status = 200, body = html } })
        http.user_id = "999"
        local years = client:get_reading_stats()
        assert_equal(1, #years)
        assert_equal(2026, years[1].year)
        assert_equal(10, years[1].books)
    end)

    it("parses the average rating from a book page", function()
        local client = client_with({ { status = 200, body = BOOK_HTML_RATED } })
        local book = client:get_book("1")
        assert_equal(4.25, book.rating)
        assert_equal(1234, book.ratings_count)
        assert_equal(56, book.reviews_count)
        assert_equal("http://img/dune.jpg", book.cover_url)
        assert_equal("<i>A</i> novel", book.description)
        assert_equal("Penguin", book.publisher)
        assert_equal("1965", book.published)
    end)

    it("parses author search results", function()
        local client = client_with({ { status = 200, body = AUTHORS_SEARCH } })
        local authors = client:search_authors("brandon")
        assert_equal(2, #authors)
        assert_equal("38550", authors[1].goodreads_id)
        assert_equal("Brandon Sanderson", authors[1].name)
        assert_equal("123", authors[2].goodreads_id)
    end)

    it("parses books by an author", function()
        local client = client_with({ { status = 200, body = AUTHOR_PAGE } })
        local books = client:get_author_books("38550")
        assert_equal(2, #books)
        assert_equal("68428", books[1].goodreads_id)
        assert_equal("Mistborn: The Final Empire", books[1].title)
        assert_equal("68429", books[2].goodreads_id)
    end)

    it("parses recommendations with author, rating and paging", function()
        local client = client_with({ { status = 200, body = RECS_HTML } })
        local books, more = client:get_recommendations(1)
        assert_equal(2, #books)
        assert_equal("406235", books[1].goodreads_id)
        assert_equal("Giovanni’s Room", books[1].title)
        assert_equal("James Baldwin", books[1].author)
        assert_equal(3.95, books[1].avg_rating)
        assert_equal("157993", books[2].goodreads_id)
        assert_equal("The Little Prince", books[2].title)
        assert_equal("Antoine de Saint-Exupéry", books[2].author)
        assert_equal(4.32, books[2].avg_rating)
        assert_true(more)
    end)

    it("parses community reviews", function()
        local client = client_with({ { status = 200, body = REVIEWS_HTML } })
        local reviews, has_more = client:get_reviews("662", 1)
        assert_equal(2, #reviews)
        assert_equal("Jason", reviews[1].name)
        assert_equal(4, reviews[1].rating)
        assert_equal("A great book indeed.\nLoved it.", reviews[1].text)
        assert_equal("Ana", reviews[2].name)
        assert_nil(reviews[2].rating)
        assert_equal("Not for me.", reviews[2].text)
        assert_true(has_more)
    end)

    it("captures covers and ratings from a real shelf page", function()
        local client = client_with({ { status = 200, body = SHELF_HTML } })
        local books, has_more = client:get_shelf_books({ slug = "read", custom = false }, 1)
        assert_equal(1, #books)
        assert_equal("11012", books[1].goodreads_id)
        assert_equal("Dubliners", books[1].title)
        assert_equal("Joyce, James", books[1].author)
        assert_equal(4, books[1].rating)
        assert_equal(3.83, books[1].avg_rating)
        assert_equal("https://i.gr-assets.com/images/S/compressed.photo.goodreads.com/books/1756682305l/11012._SY75_.jpg",
            books[1].cover_url)
        assert_false(has_more)
    end)
end)
