--[[--
Shared constants for the Goodreads KO Sync plugin.

No module here may require an authentication provider or a UI widget, so that
the resolver and sync engine remain usable from unit tests without KOReader.

@module koplugin.goodreads.constants
--]]

local Constants = {
    VERSION = "1.13.0",

    -- Storage schema version. Bump only alongside a migration function.
    SCHEMA_VERSION = 1,

    -- How long a fetched CSRF token is reused (seconds). Goodreads rotates it;
    -- refreshing within a sync run keeps writes fast without going stale.
    CSRF_TTL = 120,

    -- Provider identifiers. The value is also the module basename under
    -- goodreadskosync.koplugin/providers/.
    PROVIDER = {
        MOCK = "mock",
        NATIVE_KINDLE = "native_kindle",
        GOODREADS_WEB = "goodreads_web",
        OFFICIAL_API = "official_api",
    },

    -- Canonical shelf states. Providers must translate these to their own
    -- representation; the rest of the plugin only ever sees these.
    SHELF = {
        WANT_TO_READ = "want_to_read",
        CURRENTLY_READING = "currently_reading",
        READ = "read",
        DID_NOT_FINISH = "did_not_finish",
    },

    -- Normalized error codes returned by every provider and by network.lua.
    ERROR = {
        NETWORK_ERROR = "NETWORK_ERROR",
        AUTH_REQUIRED = "AUTH_REQUIRED",
        INVALID_CREDENTIALS = "INVALID_CREDENTIALS",
        SIGNIN_BLOCKED = "SIGNIN_BLOCKED",
        RATE_LIMITED = "RATE_LIMITED",
        NOT_FOUND = "NOT_FOUND",
        SERVER_ERROR = "SERVER_ERROR",
        INVALID_RESPONSE = "INVALID_RESPONSE",
        PROVIDER_UNAVAILABLE = "PROVIDER_UNAVAILABLE",
        CONFLICT = "CONFLICT",
        INVALID_REQUEST = "INVALID_REQUEST",
        UNSUPPORTED = "UNSUPPORTED",
    },

    -- How a book identity was derived, in decreasing order of authority.
    IDENTIFIER_SOURCE = {
        GOODREADS_ID = "goodreads_id",
        ISBN13 = "isbn13",
        ISBN10 = "isbn10",
        ASIN = "asin",
        FILENAME_ISBN = "filename_isbn",
        FILENAME_ASIN = "filename_asin",
        METADATA = "metadata",
        TITLE_AUTHOR = "title_author",
        TITLE = "title",
        MANUAL = "manual",
        MAPPING = "mapping",
    },

    -- Confidence thresholds for the matcher.
    CONFIDENCE = {
        AUTO = 90,     -- >= this, and an identifier matched: select silently
        CONFIRM = 70,  -- >= this: ask the user to confirm
    },

    -- Exponential retry schedule for the offline queue, in seconds.
    BACKOFF = { 30, 120, 300, 900, 1800 },

    -- Conflict policies for cloud-vs-local progress.
    CONFLICT_POLICY = {
        PREFER_LOCAL = "prefer_local",
        PREFER_CLOUD = "prefer_cloud",
        ASK = "ask",
    },

    -- Completion behavior.
    COMPLETION_BEHAVIOR = {
        EXPLICIT_ONLY = "explicit_only",
        PERCENT_99 = "percent_99",
    },

    -- Default provider discovery order (highest priority first).
    PROVIDER_ORDER = {
        "goodreads_web",
        "native_kindle",
        "official_api",
        "mock",
    },

    -- Storage file names (relative to the plugin settings directory).
    STORAGE = {
        ACCOUNT = "account",
        SESSION = "session",
        CREDENTIALS = "credentials",
        MAPPINGS = "mappings",
        BOOK_SETTINGS = "book_settings",
        SYNC_STATE = "sync_state",
        QUEUE = "queue",
        SEARCH_CACHE = "search_cache",
        SETTINGS = "settings",
    },

    -- How long a remote shelf read is reused before it is fetched again, in
    -- seconds. A fresh read is always taken on document open and manual sync.
    REMOTE_SHELF_TTL = 60 * 60,

    -- Background update check interval, in seconds (about once a day).
    UPDATE_CHECK_INTERVAL = 24 * 60 * 60,

    -- Search cache lifetime, in seconds (7 days).
    SEARCH_CACHE_TTL = 7 * 24 * 60 * 60,

    -- Maximum entries retained in the search cache.
    SEARCH_CACHE_MAX = 200,
}

return Constants
