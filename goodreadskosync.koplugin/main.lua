--[[--
goodreadskosync - Goodreads KO Sync for KOReader.

This is the plugin entry point. It wires the identification resolver and the
sync engine to KOReader's reader lifecycle and menu. It contains no provider
specifics and no OPF parsing: those live in their own modules.

@module koplugin.goodreads.main
--]]

local AccountUI = require("goodreadskosync.ui.account")
local Auth = require("goodreadskosync.auth.manager")
local Constants = require("goodreadskosync.constants")
local Credentials = require("goodreadskosync.auth.credentials")
local Engine = require("goodreadskosync.sync.engine")
local IdentifyUI = require("goodreadskosync.ui.identify")
local InfoMessage = require("ui/widget/infomessage")
local LibraryUI = require("goodreadskosync.ui.library")
local Logging = require("goodreadskosync.logging")
local Mappings = require("goodreadskosync.mappings")
local Metadata = require("goodreadskosync.metadata")
local Progress = require("goodreadskosync.sync.progress")
local PageMapper = require("goodreadskosync.sync.pagemapper")
local Queue = require("goodreadskosync.sync.queue")
local Resolver = require("goodreadskosync.resolver.resolver")
local SearchUI = require("goodreadskosync.ui.search")
local SettingsUI = require("goodreadskosync.ui.settings")
local Shelves = require("goodreadskosync.sync.shelves")
local ShelfCache = require("goodreadskosync.sync.shelf_cache")
local Presets = require("goodreadskosync.sync.presets")
local State = require("goodreadskosync.sync.state")
local StatusUI = require("goodreadskosync.ui.status")
local Storage = require("goodreadskosync.storage")
local SupportUI = require("goodreadskosync.ui.support")
local Update = require("goodreadskosync.update")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Widgets = require("goodreadskosync.ui.widgets")
local throttle = require("goodreadskosync.sync.throttle")
local _ = require("gettext")

local DEFAULT_SETTINGS = {
    -- Defaults mirror the "fastest" preset. applyPreset() overwrites the
    -- preset-controlled keys whenever the user picks a preset.
    auto_shelf = true,
    auto_progress = true,
    sync_on_open = true,
    sync_on_close = true,
    sync_interval = 900,
    track_mode = "time",
    track_percent_step = 5,
    mark_started_immediately = true,
    remember_password = false,
    auto_link = true,
    update_progress_after_finished = false,
    auto_update_check = true,
    conflict_policy = Constants.CONFLICT_POLICY.PREFER_LOCAL,
    completion_behavior = Constants.COMPLETION_BEHAVIOR.EXPLICIT_ONLY,
    sync_preset = "medium",
}

local Goodreads = WidgetContainer:extend{
    name = "goodreadskosync",
    is_doc_only = false,
}

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

function Goodreads:init()
    self.settings_store = Storage.open(Constants.STORAGE.SETTINGS)
    self.book_store = Storage.open(Constants.STORAGE.BOOK_SETTINGS)
    self._provider = nil
    self._pending_online = {}
    self._sync_busy = false
    self._sync_queued = false
    self._timer = function() self:onSyncTimer() end
    self.page_mapper = PageMapper:new{ ui = self.ui }
    self._page_update = throttle(30, function(...) self:_onProgressChanged(...) end)
    -- A previous successful self-update left a backup; the new code is now
    -- running, so it is safe to remove. Guarded so it can never break loading.
    if self.path then pcall(Update.cleanupBackup, self.path) end
    -- New installs (or upgrades from a version without presets) start on the
    -- default preset, which writes every sync setting.
    if self.settings_store:get("sync_preset") == nil then
        self:applyPreset(Presets.DEFAULT)
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:scheduleTimer()
end

function Goodreads:getSetting(key)
    local value = self.settings_store:get(key)
    if value == nil then return DEFAULT_SETTINGS[key] end
    return value
end

function Goodreads:setSetting(key, value)
    self.settings_store:set(key, value)
    self.settings_store:flush()
    if key == "sync_interval" then self:scheduleTimer() end
end

-- Apply a sync preset: it writes every setting the preset controls, so a
-- single choice defines all sync behaviour.
function Goodreads:applyPreset(id)
    local def = Presets.get(id)
    if not def then return end
    for key, value in pairs(def) do
        self:setSetting(key, value)
    end
    self:setSetting("sync_preset", id)
end

-- Per-book settings (sidecar-style, keyed by local book key).
function Goodreads:bookSetting(local_key, key, default)
    if not local_key then return default end
    local books = self.book_store:get("books", {})
    local entry = books[local_key]
    if not entry or entry[key] == nil then return default end
    return entry[key]
end

function Goodreads:setBookSetting(local_key, key, value)
    if not local_key then return end
    local books = self.book_store:get("books", {})
    books[local_key] = books[local_key] or {}
    books[local_key][key] = value
    self.book_store:set("books", books)
    self.book_store:flush()
end

function Goodreads:isBookSyncEnabled(local_key)
    return self:bookSetting(local_key, "sync", true) ~= false
end

function Goodreads:syncSettings()
    return {
        auto_shelf = self:getSetting("auto_shelf"),
        auto_progress = self:getSetting("auto_progress"),
        completion_behavior = self:getSetting("completion_behavior"),
        conflict_policy = self:getSetting("conflict_policy"),
    }
end

--------------------------------------------------------------------------------
-- Providers
--------------------------------------------------------------------------------

function Goodreads:getProviderList()
    return Auth.discover()
end

function Goodreads:getSelectedProviderId()
    return Auth.get_selected_id()
end

function Goodreads:getProvider()
    if self._provider then return self._provider end
    local provider = Auth.get_provider()
    self._provider = provider
    return provider
end

function Goodreads:selectProvider(id)
    Auth.set_selected_id(id)
    self._provider = nil
    Widgets.message(_("Provider changed."))
end

--------------------------------------------------------------------------------
-- Connectivity
--------------------------------------------------------------------------------

function Goodreads:isOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and type(NetworkMgr.isConnected) == "function" then
        return NetworkMgr:isConnected()
    end
    return true
end

-- Run `callback` now if online; otherwise ask KOReader to bring Wi-Fi up (which
-- may prompt) and run the action automatically once the connection is back.
-- We run the action ourselves on NetworkConnected rather than trusting a single
-- KOReader callback, so the action is never silently dropped.
function Goodreads:runWhenOnline(callback)
    if self:isOnline() then
        callback()
        return true
    end
    self._pending_online = self._pending_online or {}
    table.insert(self._pending_online, callback)

    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        local deferred = true
        if type(NetworkMgr.willRerunWhenOnline) == "function" then
            -- No-op callback: we run the real action on NetworkConnected.
            deferred = NetworkMgr:willRerunWhenOnline(function() end)
        elseif type(NetworkMgr.beforeWifiAction) == "function" then
            NetworkMgr:beforeWifiAction()
        end
        -- If it turned out we were online after all, run the action now.
        if deferred == false and self:isOnline() then
            self:_runPendingOnline()
        end
    end
    return false
end

-- Run (and clear) the actions deferred until the network is back.
function Goodreads:_runPendingOnline()
    if not self:isOnline() then return end
    local pending = self._pending_online
    if not pending or #pending == 0 then return end
    self._pending_online = {}
    for _, callback in ipairs(pending) do
        pcall(callback)
    end
end

--------------------------------------------------------------------------------
-- Current document helpers
--------------------------------------------------------------------------------

function Goodreads:hasDocument()
    return self.ui and self.ui.document ~= nil
end

function Goodreads:currentMetadata()
    return Metadata.fromDocument(self.ui)
end

function Goodreads:currentIdentity()
    local metadata, filename = self:currentMetadata()
    return Resolver.identify(metadata, filename), metadata, filename
end

function Goodreads:currentPercent()
    return Progress.toWhole(Progress.fromReader(self.ui))
end

function Goodreads:currentStatus()
    return Progress.isComplete(self.ui) and "complete" or "reading"
end

function Goodreads:currentMapping()
    local identity = self:currentIdentity()
    return Mappings.get(identity.local_key), identity
end

--------------------------------------------------------------------------------
-- Identification
--------------------------------------------------------------------------------

function Goodreads:identifyCurrent(opts)
    opts = opts or {}
    if not self:hasDocument() then
        Widgets.message(_("Open a book first."))
        return nil
    end
    -- A confirmed mapping needs no network; only a search does.
    local identity = self:currentIdentity()
    if not opts.ignore_mapping and Mappings.get(identity.local_key) then
        return self:_identifyCurrent(opts)
    end
    return self:runWhenOnline(function() return self:_identifyCurrent(opts) end)
end

function Goodreads:_identifyCurrent(opts)
    opts = opts or {}
    if not self:hasDocument() then
        Widgets.message(_("Open a book first."))
        return nil
    end
    local metadata, filename = self:currentMetadata()
    local identity = Resolver.identify(metadata, filename)
    local provider = self:getProvider()

    -- Resolve off the UI thread (search is the slow part); handle the result
    -- back on the UI thread.
    self:runAsync(function()
        local completed, result = self:runInBackground(nil, function()
            return Resolver.resolve({
                metadata = metadata,
                filename = filename,
                provider = provider,
                mappings = Mappings,
                ignore_mapping = opts.ignore_mapping,
                no_cache = opts.no_cache,
                query = opts.query,
            })
        end)
        if completed == false then return end
        self:_handleResolution(result, identity, metadata, filename, opts.choose)
    end)
    return nil
end

-- Decide what to do with a resolution result. By default we link the
-- highest-probability match automatically and show a small toast; the user can
-- always change it from the menu. With `choose`, always present the candidate
-- list instead of auto-linking.
function Goodreads:_handleResolution(result, identity, metadata, filename, choose)
    if not result then
        Widgets.notify(_("Search failed · try again"))
        return
    end

    local has_candidates = result.candidates and #result.candidates > 0

    if choose then
        if has_candidates then
            IdentifyUI.showCandidates(identity, result.candidates, function(candidate)
                self:confirmMapping(result, candidate)
            end)
        else
            self:showUnidentified(identity, metadata, filename)
        end
        return
    end

    if result.status == "auto" then
        self:linkCandidate(result, result.selected)
    elseif result.status == "mapped" then
        Widgets.notify(_("Already linked"))
    elseif (result.status == "confirm" or result.status == "manual")
        and has_candidates then
        if self:getSetting("auto_link") then
            self:linkCandidate(result, result.candidates[1])
        else
            IdentifyUI.showCandidates(identity, result.candidates, function(candidate)
                self:confirmMapping(result, candidate)
            end)
        end
    elseif result.status == "error" then
        Widgets.notify(_("No network · will retry"))
    else
        -- Nothing was found (or no confident match): offer to link it manually,
        -- with a short instruction and an input, unless the user snoozed it.
        if self:isIdentifySnoozed(identity.local_key) then
            return
        end
        self:showUnidentified(identity, metadata, filename)
    end
end

-- Whether the user asked to be reminded later about linking this book.
function Goodreads:isIdentifySnoozed(local_key)
    if not local_key then return false end
    local until_at = self:bookSetting(local_key, "identify_snooze_until")
    return type(until_at) == "number" and until_at > os.time()
end

function Goodreads:snoozeIdentify(identity)
    if identity and identity.local_key then
        self:setBookSetting(identity.local_key, "identify_snooze_until", os.time() + 60 * 60)
    end
    Widgets.notify(_("Will ask again in an hour"), 3)
end

-- Link a chosen candidate and notify quietly.
function Goodreads:linkCandidate(result, candidate)
    if not candidate then return end
    local record = Resolver.buildMapping(result.local_key, result.identity, candidate)
    Mappings.put(result.local_key, record)
    if candidate.pages then
        self:setBookSetting(result.local_key, "pages", candidate.pages)
    end
    Widgets.notify(string.format(_("Linked to Goodreads: %s"),
        candidate.title or _("this book")))
    -- Newly linked book: sync at once so it appears on Goodreads right away.
    -- When enabled, also start it as Currently Reading for an immediate effect.
    self:syncSilently({
        force_remote = true,
        start_reading = self:getSetting("mark_started_immediately") ~= false,
    })
end

function Goodreads:showUnidentified(identity, metadata, filename)
    local id = identity or {}
    IdentifyUI.showUnidentified(identity, {
        find = function() self:searchManual(metadata, filename, nil) end,
        enter_isbn = function()
            SearchUI.prompt(_("Enter ISBN"), id.isbn13, function(value)
                self:searchManual(metadata, filename, value)
            end)
        end,
        enter_goodreads_id = function()
            SearchUI.prompt(_("Enter Goodreads ID"), id.goodreads_id,
                function(value) self:useGoodreadsId(identity, value) end,
                _("Use"))
        end,
        search_manual = function() self:searchManual(metadata, filename, nil) end,
        snooze = function() self:snoozeIdentify(identity) end,
        cancel = function() end,
    })
end

function Goodreads:searchManual(metadata, filename, query)
    self:runWhenOnline(function() self:_searchManual(metadata, filename, query) end)
end

function Goodreads:_searchManual(metadata, filename, query)
    local provider = self:getProvider()
    if not provider then
        Widgets.message(_("No provider available."))
        return
    end
    local result = Resolver.resolve({
        metadata = metadata,
        filename = filename,
        provider = provider,
        ignore_mapping = true,
        no_cache = true,
        query = query,
    })
    local identity = result.identity
    if result.candidates and #result.candidates > 0 then
        IdentifyUI.showCandidates(identity, result.candidates, function(candidate)
            self:confirmMapping(result, candidate)
        end)
    else
        Widgets.message(_("No matches found."))
    end
end

function Goodreads:confirmMapping(result, candidate)
    self:linkCandidate(result, candidate)
end

function Goodreads:useGoodreadsId(identity, value)
    if not identity then return end
    if not value or not value:match("^%d+$") then
        Widgets.message(_("Invalid Goodreads ID."))
        return
    end
    local record = {
        local_key = identity.local_key,
        goodreads_id = value,
        isbn13 = identity.isbn13,
        isbn10 = identity.isbn10,
        asin = identity.asin,
        title = identity.title,
        author = identity.primary_author,
        authors = identity.authors,
        confirmed = true,
    }
    Mappings.put(identity.local_key, record)
    Widgets.message(_("Book identified."))
end

function Goodreads:forgetMapping()
    local identity = self:currentIdentity()
    if Mappings.forget(identity.local_key) then
        State.set(identity.local_key, State.default(identity.local_key))
        Widgets.message(_("Mapping forgotten."))
    else
        Widgets.message(_("No mapping to forget."))
    end
end

-- Rating is only ever submitted on explicit user action.
function Goodreads:rateCurrentBook()
    local mapping = self:currentMapping()
    if not mapping or not mapping.goodreads_id then
        Widgets.notify(_("Not linked yet"))
        return
    end
    Widgets.starDialog(_("Rate this book on Goodreads"), function(stars)
        self:submitRating(stars)
    end)
end

function Goodreads:submitRating(stars)
    local mapping = self:currentMapping()
    if not mapping or not mapping.goodreads_id then return end
    local provider = self:getProvider()
    self:runAsync(function()
        local completed, ok = self:runInBackground(_("Saving rating…"), function()
            return provider:set_rating(mapping.goodreads_id, stars)
        end)
        if completed == false then return end
        Widgets.notify(ok and string.format(_("Rated %d stars"), stars)
            or _("Rating failed"))
    end)
end

--------------------------------------------------------------------------------
-- Sync
--------------------------------------------------------------------------------

function Goodreads:syncNow()
    self:runWhenOnline(function() self:_syncNow() end)
end

-- Run a network-only task off the UI thread when possible (ShelfSync-style),
-- falling back to a blocking run when not in a coroutine.
-- Returns completed, <task results>.
function Goodreads:runInBackground(text, task)
    local ok, Trapper = pcall(require, "ui/trapper")
    if ok and Trapper and type(Trapper.dismissableRunInSubprocess) == "function" then
        local completed, a, b, c = Trapper:dismissableRunInSubprocess(task, text)
        return completed, a, b, c
    end
    local ok2, a, b, c = pcall(task)
    if not ok2 then
        Logging.warn("background task failed")
        return true, nil
    end
    return true, a, b, c
end

-- Run `fn` in a Trapper coroutine so runInBackground can actually fork a
-- subprocess (and so UI updates after the yield still work). Falls back to a
-- direct call when Trapper is unavailable.
function Goodreads:runAsync(fn)
    local ok, Trapper = pcall(require, "ui/trapper")
    if ok and Trapper and type(Trapper.wrap) == "function" then
        Trapper:wrap(fn)
    else
        fn()
    end
end

-- Gather the local inputs (fast, in-process) for a sync.
function Goodreads:syncInputs(opts)
    opts = opts or {}
    local mapping, identity = self:currentMapping()
    if not mapping or not mapping.goodreads_id then return nil end

    -- Decide percent vs page unit in-process (page mapper reads the document).
    local unit = "percent"
    local page_value = nil
    if (self:getSetting("track_mode") or "time") == "pages" then
        local mapped = self:_mappedPage(identity.local_key)
        if mapped then
            unit = "pages"
            page_value = mapped
        end
    end

    return {
        gid = mapping.goodreads_id,
        local_key = identity.local_key,
        title = mapping.title or identity.title,
        percent = self:currentPercent(),
        page_value = page_value,
        sync_unit = unit,
        status = self:currentStatus(),
        settings = self:syncSettings(),
        force_remote = opts.force_remote and true or false,
        start_reading = opts.start_reading and true or false,
    }
end

function Goodreads:_mappedPage(local_key)
    if not self.ui or not self.ui.document then return nil end
    local document_pages = self.ui.document:getPageCount()
    if not document_pages or document_pages <= 0 then return nil end
    local raw_page = self.ui:getCurrentPage()
    if not raw_page then return nil end
    local remote_pages = self:bookSetting(local_key, "pages")
    if not remote_pages or remote_pages <= 0 then return nil end
    local _, mapped = self.page_mapper:getRemotePagePercent(raw_page, document_pages, remote_pages)
    return mapped
end

-- Network + persistence only. Safe to run in a subprocess; performs no UI.
function Goodreads:_syncCore(inputs)
    local provider = self:getProvider()
    if not provider then
        return { ok = false, error = Constants.ERROR.PROVIDER_UNAVAILABLE }
    end
    if not self:isBookSyncEnabled(inputs.local_key) then
        return { ok = true, skipped = true }
    end

    local state = State.get(inputs.local_key)
    state.goodreads_id = inputs.gid

    -- Read the remote shelf (best effort) to protect user-chosen shelves. This
    -- is a full HTML page, so only refresh it when forced (open/manual sync) or
    -- when the cache is missing/stale; otherwise reuse it and keep periodic
    -- syncs cheap.
    local now = os.time()
    local remote_shelf = state.remote_shelf
    if provider.get_book_shelves
        and ShelfCache.needsRefresh(state, now, inputs.force_remote,
            Constants.REMOTE_SHELF_TTL) then
        local remote = provider:get_book_shelves(inputs.gid)
        if remote then
            ShelfCache.apply(state, remote, now)
            remote_shelf = remote.shelf
        end
    end

    local settings = inputs.settings
    local percent = inputs.percent or 0
    local user_override
    local already_read = remote_shelf == Constants.SHELF.READ

    -- Detect a shelf the user changed on Goodreads (vs the one we last pushed).
    if remote_shelf and remote_shelf ~= state.last_pushed_shelf then
        if remote_shelf == Constants.SHELF.WANT_TO_READ then
            state.override_shelf = Constants.SHELF.WANT_TO_READ
            state.override_baseline_percent = percent
            state.shelf = Constants.SHELF.WANT_TO_READ
        elseif remote_shelf == Constants.SHELF.READ then
            state.override_shelf = Constants.SHELF.READ
            state.shelf = Constants.SHELF.READ
        elseif remote_shelf == Constants.SHELF.CURRENTLY_READING then
            state.override_shelf = nil
            state.override_baseline_percent = nil
            state.shelf = Constants.SHELF.CURRENTLY_READING
        elseif remote_shelf == Constants.SHELF.DID_NOT_FINISH then
            state.override_shelf = Constants.SHELF.DID_NOT_FINISH
            state.override_baseline_percent = nil
            state.shelf = Constants.SHELF.DID_NOT_FINISH
        end
    end

    -- Explicit KOReader completion always wins, even over a user override.
    if inputs.status == "complete" then
        state.override_shelf = nil
        state.override_baseline_percent = nil
    elseif state.override_shelf == Constants.SHELF.WANT_TO_READ then
        local baseline = state.override_baseline_percent or 0
        if percent - baseline > 1 then
            -- Reading has genuinely resumed: drop the override and let the
            -- engine move it to Currently Reading.
            state.override_shelf = nil
            state.override_baseline_percent = nil
            state.shelf = Constants.SHELF.WANT_TO_READ
        else
            -- Honor Want to Read; do not push progress until reading resumes.
            user_override = Constants.SHELF.WANT_TO_READ
            settings = {
                auto_shelf = settings.auto_shelf,
                auto_progress = false,
                completion_behavior = settings.completion_behavior,
                conflict_policy = settings.conflict_policy,
            }
        end
    elseif state.override_shelf == Constants.SHELF.READ
        or state.shelf == Constants.SHELF.READ then
        -- Sticky Read: never auto-downgrade a finished book, however it got
        -- marked Read (manual, completion, or seen on Goodreads).
        user_override = Constants.SHELF.READ
        if not self:getSetting("update_progress_after_finished") and percent < 100 then
            settings = {
                auto_shelf = settings.auto_shelf,
                auto_progress = false,
                completion_behavior = settings.completion_behavior,
                conflict_policy = settings.conflict_policy,
            }
        end
    elseif state.override_shelf == Constants.SHELF.DID_NOT_FINISH
        or state.shelf == Constants.SHELF.DID_NOT_FINISH then
        -- Sticky Did Not Finish: never auto-move a DNF book.
        user_override = Constants.SHELF.DID_NOT_FINISH
    end

    -- A newly linked book starts as Currently Reading on Goodreads even before
    -- any progress exists, so the addition is immediately visible. Never
    -- overrides a finished book or a user's own shelf choice.
    local shelf_override
    if inputs.start_reading and not remote_shelf
        and inputs.status ~= "complete"
        and not state.override_shelf then
        shelf_override = Constants.SHELF.CURRENTLY_READING
    end

    local function run()
        return Engine.sync({
            provider = provider,
            identity = { goodreads_id = inputs.gid },
            local_key = inputs.local_key,
            state = state,
            percent = inputs.percent,
            page_value = inputs.page_value,
            sync_unit = inputs.sync_unit,
            status = inputs.status,
            settings = settings,
            user_override = user_override,
            shelf_override = shelf_override,
            capabilities = provider:get_capabilities(),
            queue = Queue,
        })
    end

    local results, new_state = run()

    -- On a spurious auth failure, refresh the session and retry once.
    local function auth_failed(rs)
        for _, r in ipairs(rs) do
            if not r.ok and r.error == Constants.ERROR.AUTH_REQUIRED then
                return true
            end
        end
        return false
    end
    if auth_failed(results) then
        if Auth.refresh_session() then
            results, new_state = run()
        end
    end

    -- Keep the remote-shelf cache in step with a shelf we just pushed.
    local pushed_shelf
    local pushed_progress = false
    for _, result in ipairs(results) do
        if result.ok and result.action and result.action.type == "shelf" then
            pushed_shelf = result.action.shelf
            ShelfCache.invalidate(new_state, new_state.shelf, os.time())
        elseif result.ok and result.action and result.action.type == "progress" then
            pushed_progress = true
        end
    end
    -- A just-pushed progress makes any queued progress for this book redundant.
    if pushed_progress then
        Queue.remove("progress:" .. tostring(inputs.gid))
    end

    State.set(inputs.local_key, new_state)
    self:processQueueCore()

    local summary = {
        ok = true,
        auth_expired = false,
        changed = false,
        already_read = already_read,
        percent = inputs.percent,
        title = inputs.title,
        local_key = inputs.local_key,
        completed = inputs.status == "complete",
        pushed_shelf = pushed_shelf,
        started_reading = (shelf_override == Constants.SHELF.CURRENTLY_READING)
            and (pushed_shelf == Constants.SHELF.CURRENTLY_READING) or false,
    }
    for _, result in ipairs(results) do
        if result.ok then
            summary.changed = true
        else
            summary.ok = false
            summary.error = result.error
            if result.error == Constants.ERROR.AUTH_REQUIRED then
                summary.auth_expired = true
            end
        end
    end
    return summary
end

function Goodreads:_syncNow()
    if not self:hasDocument() then
        Widgets.message(_("Open a book first."))
        return
    end
    if self._sync_busy then
        -- A background sync is already running; fold this into a follow-up.
        self._sync_queued = true
        Widgets.notify(_("Syncing…"), 2)
        return
    end
    local inputs = self:syncInputs({ force_remote = true })
    if not inputs then
        self:identifyCurrent({ no_cache = true })
        return
    end
    self._sync_busy = true
    self:runAsync(function()
        local completed, summary = self:runInBackground(
            _("Syncing with Goodreads…"),
            function() return self:_syncCore(inputs) end)
        self._sync_busy = false
        if completed == false then
            self._sync_queued = false
            return
        end
        self:_reportSyncSummary(summary)
        if self._sync_queued then
            self._sync_queued = false
            self:syncSilently()
        end
    end)
end

-- Short book label for toasts (kept brief; never splits a UTF-8 character).
local function shortTitle(title)
    if type(title) ~= "string" or title == "" then return nil end
    if #title <= 28 then return title end
    local cut = 28
    while cut > 1 do
        local b = title:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return title:sub(1, cut) .. "…"
end

local SYNC_SHELF_VERB = {
    [Constants.SHELF.READ] = _("Marked Read"),
    [Constants.SHELF.CURRENTLY_READING] = _("Now reading"),
    [Constants.SHELF.WANT_TO_READ] = _("Want to Read"),
    [Constants.SHELF.DID_NOT_FINISH] = _("Did Not Finish"),
}

-- Short, specific toast for a successful automatic sync.
function Goodreads:_syncToast(summary)
    local parts = {}
    if summary.pushed_shelf then
        parts[#parts + 1] = SYNC_SHELF_VERB[summary.pushed_shelf] or summary.pushed_shelf
    end
    if summary.percent
        and not (summary.pushed_shelf == Constants.SHELF.READ and summary.percent >= 100) then
        parts[#parts + 1] = string.format("%d%%", summary.percent)
    end
    if #parts == 0 then parts[#parts + 1] = _("Synced") end
    local title = shortTitle(summary.title)
    local body = table.concat(parts, " · ")
    if title then
        return string.format("%s · %s", title, body)
    end
    return body
end

-- Short, specific toast for a failed automatic sync.
function Goodreads:_syncFailToast(err, title)
    local reason
    if err == Constants.ERROR.NETWORK_ERROR then
        reason = _("no network")
    elseif err == Constants.ERROR.SERVER_ERROR
        or err == Constants.ERROR.INVALID_RESPONSE then
        reason = _("Goodreads error")
    elseif err == Constants.ERROR.AUTH_REQUIRED then
        reason = _("session expired")
    else
        reason = _("sync failed")
    end
    local short = shortTitle(title)
    if short then
        return string.format("%s · %s", short, reason)
    end
    return reason
end

-- Best-effort title for a Goodreads book id, from the saved mappings.
function Goodreads:_titleForBookId(book_id)
    if not book_id then return nil end
    for _, mapping in pairs(Mappings.all()) do
        if tostring(mapping.goodreads_id) == tostring(book_id) then
            return mapping.title
        end
    end
    return nil
end


-- Automatic sync (on open, periodic, resume) with light feedback.
function Goodreads:syncSilently(opts)
    opts = opts or {}
    if not self:hasDocument() then return end
    local mapping = self:currentMapping()
    if not mapping or not mapping.goodreads_id then return end
    -- Automatic syncs never turn Wi-Fi on: they run when already online and
    -- otherwise defer to the offline queue (flushed on reconnect/close).
    if not self:isOnline() then return end
    -- One sync at a time: overlapping triggers otherwise push the same progress
    -- more than once. Coalesce them into a single follow-up run.
    if self._sync_busy then
        self._sync_queued = true
        return
    end
    local inputs = self:syncInputs(opts)
    if not inputs then return end
    self._sync_busy = true
    self:runAsync(function()
        local completed, summary = self:runInBackground(nil, function()
            return self:_syncCore(inputs)
        end)
        self._sync_busy = false
        if completed == false or not summary then
            self._sync_queued = false
            return
        end
        if summary.auth_expired then
            self:promptLoginOnOpen()
        elseif summary.changed then
            Widgets.notify(self:_syncToast(summary), 2)
        elseif summary.already_read then
            local t = shortTitle(summary.title)
            Widgets.notify(t and string.format(_("%s · already Read"), t)
                or _("Already Read · nothing to sync"), 4)
        elseif not summary.ok then
            -- Don't fail silently, but don't nag either.
            local now = os.time()
            if not self._last_fail_notify or now - self._last_fail_notify > 300 then
                self._last_fail_notify = now
                self:setSetting("last_sync_error", summary.error or Constants.ERROR.SERVER_ERROR)
                self:setSetting("last_sync_error_at", now)
                Widgets.notify(self:_syncFailToast(summary.error, summary.title), 3)
            end
        end
        if summary.ok then self:maybePromptRating(summary) end
        if self._sync_queued then
            self._sync_queued = false
            self:syncSilently()
        end
    end)
end

function Goodreads:_reportSyncSummary(summary)
    if not summary then
        Widgets.message(_("Sync failed · will retry"))
        return
    end
    if summary.auth_expired then
        Widgets.confirm(_("Goodreads login has expired. Sign in again?"),
            function() self:login() end, _("Sign in"))
        return
    end
    if summary.ok then
        if summary.changed then
            Widgets.message(self:_syncToast(summary), 5)
        elseif summary.already_read then
            local t = shortTitle(summary.title)
            Widgets.message(t and string.format(_("%s · already Read"), t)
                or _("Already Read · nothing to sync"), 4)
        else
            local t = shortTitle(summary.title)
            Widgets.message(t and string.format(_("%s · already up to date"), t)
                or _("Already up to date"), 4)
        end
        self:maybePromptRating(summary)
    else
        self:setSetting("last_sync_error", summary.error or Constants.ERROR.SERVER_ERROR)
        self:setSetting("last_sync_error_at", os.time())
        Widgets.message(self:_syncFailToast(summary.error, summary.title), 6)
    end
end

-- Retry queued operations (network only; safe in a subprocess).
-- Returns a single result table so nothing is lost across the subprocess
-- boundary: { sent, failed, permanent, ids }.
function Goodreads:processQueueCore()
    local provider = self:getProvider()
    if not provider then return { sent = 0, failed = 0, permanent = 0, ids = {} } end
    local sent, failed, permanent = 0, 0, 0
    local ids, seen = {}, {}
    for _, op in ipairs(Queue.due()) do
        local ok, err
        local drop = false
        local percent
        if op.operation == "shelf" then
            ok, err = provider:set_shelf(op.book_id, op.payload.shelf)
        elseif op.operation == "progress" then
            percent = tonumber(op.payload and op.payload.percent) or 0
            -- Skip a stale progress op if the percent is already accounted for;
            -- this keeps the flush and the event engine from sending it twice.
            if op.local_key and not Progress.shouldSync(State.get(op.local_key), percent) then
                drop = true
            else
                ok, err = provider:update_progress(op.book_id,
                    op.payload.value or op.payload.percent, op.payload.unit)
            end
        elseif op.operation == "rating" then
            ok, err = provider:set_rating(op.book_id, op.payload.rating)
        end
        if drop then
            Queue.remove(op.id)
        elseif ok then
            Queue.remove(op.id)
            if op.operation == "progress" and op.local_key then
                State.patch(op.local_key, {
                    last_successful_percent = percent,
                    last_cloud_percent = percent,
                    last_successful_page = (op.payload and op.payload.unit == "pages")
                        and op.payload.value or nil,
                })
            end
            sent = sent + 1
            local key = tostring(op.book_id)
            if not seen[key] then
                seen[key] = true
                ids[#ids + 1] = op.book_id
            end
        elseif err == Constants.ERROR.AUTH_REQUIRED then
            -- Stop retrying until the user logs in again; leave it queued.
            break
        else
            local _, became_failed = Queue.markFailure(op.id, err)
            failed = failed + 1
            if became_failed then permanent = permanent + 1 end
        end
    end
    return { sent = sent, failed = failed, permanent = permanent, ids = ids }
end

-- Short, specific toast naming the books whose offline changes were sent.
function Goodreads:_flushToast(ids)
    local names = {}
    for _, id in ipairs(ids or {}) do
        local t = shortTitle(self:_titleForBookId(id))
        if t then names[#names + 1] = t end
    end
    if #names == 0 then
        return _("Synced to Goodreads")
    end
    local shown = {}
    for i = 1, math.min(#names, 2) do shown[#shown + 1] = names[i] end
    local label = table.concat(shown, ", ")
    local more = #names - #shown
    if more > 0 then
        label = string.format(_("%s +%d more"), label, more)
    end
    return label
end

-- Throttled notice when queued changes can no longer be retried automatically.
function Goodreads:_notifyQueuedFailure(count)
    local now = os.time()
    if self._last_queue_fail_notify and now - self._last_queue_fail_notify < 300 then
        return
    end
    self._last_queue_fail_notify = now
    local text = (count == 1)
        and _("1 change couldn't sync · see Waiting to sync")
        or string.format(_("%d changes couldn't sync · see Waiting to sync"), count or 0)
    Widgets.notify(text, 4)
end

function Goodreads:processQueue()
    if not self:isOnline() then return end
    self:runAsync(function()
        local completed, res = self:runInBackground(nil, function()
            return self:processQueueCore()
        end)
        if completed == false or type(res) ~= "table" then return end
        if res.sent and res.sent > 0 then
            Widgets.notify(self:_flushToast(res.ids), 2)
        end
        if res.permanent and res.permanent > 0 then
            self:_notifyQueuedFailure(res.permanent)
        end
    end)
end

function Goodreads:onSyncTimer()
    if self:isOnline() and self:getSetting("auto_progress") then
        self:syncSilently()
    end
    self:scheduleTimer()
end

function Goodreads:scheduleTimer()
    if self._timer and self._timer_scheduled then
        UIManager:unschedule(self._timer)
        self._timer_scheduled = false
    end
    local interval = tonumber(self:getSetting("sync_interval")) or 0
    if interval > 0 and self._timer then
        UIManager:scheduleIn(interval, self._timer)
        self._timer_scheduled = true
    end
end

--------------------------------------------------------------------------------
-- Status / account / diagnostics UI
--------------------------------------------------------------------------------

function Goodreads:showStatus()
    local mapping, identity = self:currentMapping()
    local state = State.get(identity.local_key)
    StatusUI.show({
        title = identity.title,
        author = identity.primary_author,
        goodreads_title = mapping and mapping.title,
        percent = self:currentPercent(),
        cloud_percent = state.last_successful_percent,
        shelf = state.shelf,
        rating = state.rating,
        last_sync = state.last_sync_at,
        status_text = mapping and _("Linked") or _("Not linked"),
    }, {
        sync_now = function() self:syncNow() end,
        rate = function() self:rateCurrentBook() end,
        change_book = function()
            self:identifyCurrent({ ignore_mapping = true, no_cache = true })
        end,
    })
end

-- One-time friendly onboarding.
function Goodreads:maybeOnboard()
    if self:getSetting("onboarded") then return end
    self:setSetting("onboarded", true)
    Widgets.notify(_("Ready · sign in from Account"), 6)
end

-- After a book is finished, mention rating once per book (toast only).
function Goodreads:maybePromptRating(summary)
    if not summary or not summary.completed or not summary.local_key then return end
    if self:bookSetting(summary.local_key, "rating_prompted") then return end
    self:setBookSetting(summary.local_key, "rating_prompted", true)
    local t = shortTitle(summary.title)
    Widgets.notify(t and string.format(_("%s · finished, rate it"), t)
        or _("Finished · rate it"), 4)
end

function Goodreads:showAccount()
    local provider = self:getProvider()
    local session = Auth.get_session()
    local account
    if provider then account = provider:get_account() end
    AccountUI.show({
        provider = provider and provider:get_display_name() or _("none"),
        account = account,
        state = session.state,
        user_id = session.user_id,
        has_saved = Credentials.has(),
    }, {
        login = function() self:login() end,
        login_saved = function() self:loginWithSaved() end,
        logout = function() self:logout() end,
        forget_credentials = function() self:forgetCredentials() end,
        test = function() self:testConnection() end,
        change_provider = function() self:showProviderChooser() end,
    })
end

function Goodreads:login()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local saved = Credentials.load()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Log in to Goodreads"),
        fields = {
            { text = saved and saved.email or "", hint = _("Email") },
            { text = saved and saved.password or "", hint = _("Password"), text_type = "password" },
        },
        buttons = { {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Log in"),
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    self:performLogin(fields[1], fields[2])
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Goodreads:loginWithSaved()
    local saved = Credentials.load()
    if not saved then
        self:login()
        return
    end
    self:performLogin(saved.email, saved.password)
end

function Goodreads:forgetCredentials()
    Credentials.clear()
    Widgets.message(_("Saved password forgotten."))
end

function Goodreads:performLogin(email, password)
    self:runWhenOnline(function() self:_performLogin(email, password) end)
end

function Goodreads:_performLogin(email, password)
    local attempts = 3

    local function finish(ok, account, result)
        if ok and self:getSetting("remember_password") then
            Credentials.save(email, password)
        end
        self:handleLoginResult(ok, account, result)

        if ok then
            -- Logged in: make the current book reflect it right away.
            self:syncSilently({ force_remote = true })
        end

        -- Offer to remember the password (single login entry; no separate
        -- "log in with saved password" option).
        if ok and not self:getSetting("remember_password") and not Credentials.has() then
            Widgets.confirm(
                _("Save your password so you don't have to type it again?\n\nIt is stored on this device in plain text."),
                function()
                    self:setSetting("remember_password", true)
                    Credentials.save(email, password)
                    Widgets.message(_("Password saved."))
                end,
                _("Save password"))
        end
    end

    local function is_transient(result)
        if type(result) ~= "table" then return false end
        return result.error == Constants.ERROR.NETWORK_ERROR
            or result.error == Constants.ERROR.SERVER_ERROR
            or result.error == Constants.ERROR.INVALID_RESPONSE
    end

    -- Login is a multi-request round-trip and is genuinely hit or
    -- miss; retry transient failures a few times, showing progress. Each
    -- attempt runs off the UI thread and uses KOReader's own dismissable
    -- progress widget, which stays visible until the attempt completes.
    local function attempt(n)
        self:runAsync(function()
            local status = string.format(
                _("Signing in to Goodreads… (attempt %d of %d)"), n, attempts)
            local completed, ok, account, result = self:runInBackground(status, function()
                return Auth.login(email, password, { attempts = 1 })
            end)
            if completed == false then return end

            -- Success, or a challenge the user must handle: stop retrying.
            if ok or (result and (result.needs_challenge or result.needs_otp)) then
                finish(ok, account, result)
                return
            end

            if is_transient(result) and n < attempts then
                local wait = 2 * n
                Logging.trace("login: attempt", n, "failed",
                    tostring(result and result.error), "- retrying in", wait, "s")
                Widgets.message(string.format(
                    _("Attempt %d of %d failed. Retrying in %d s…"), n, attempts, wait),
                    math.max(wait, 3))
                UIManager:scheduleIn(wait, function() attempt(n + 1) end)
            else
                finish(false, account, result)
            end
        end)
    end

    attempt(1)
end

-- Submit an OTP off the UI thread, prompting for Wi-Fi if needed.
function Goodreads:submitOtp(otp)
    self:runWhenOnline(function()
        self:runAsync(function()
            local completed, ok, account, result = self:runInBackground(
                _("Verifying code…"),
                function() return Auth.submit_otp(otp) end)
            if completed == false then return end
            self:handleLoginResult(ok, account, result)
        end)
    end)
end

-- Submit a challenge answer off the UI thread, prompting for Wi-Fi if needed.
function Goodreads:submitChallenge(answer)
    self:runWhenOnline(function()
        self:runAsync(function()
            local completed, ok, account, result = self:runInBackground(
                _("Submitting…"),
                function() return Auth.submit_challenge(answer) end)
            if completed == false then return end
            self:handleLoginResult(ok, account, result)
        end)
    end)
end

function Goodreads:promptOtp()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Enter the verification code"),
        buttons = { {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Submit"),
                callback = function()
                    local otp = dialog:getInputText()
                    UIManager:close(dialog)
                    self:submitOtp(otp)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Goodreads:handleLoginResult(ok, account, result)
    if ok then
        Widgets.message(string.format(_("Login successful — signed in as %s."),
            account and (account.username or account.id) or _("unknown")), 5)
        return
    end
    if result and result.needs_challenge then
        self:showChallenge(result)
    elseif result and result.needs_otp then
        self:promptOtp()
    else
        self:reportLoginFailure(result)
    end
end

-- Fetch and display the challenge image, then ask the user to type it.
function Goodreads:showChallenge(result)
    local ctx = result and result.ctx
    local challenge = result and result.challenge
    if not ctx or not challenge or not challenge.image_url then
        self:reportLoginFailure({ error = Constants.ERROR.SIGNIN_BLOCKED, stage = "challenge" })
        return
    end

    local Http = require("goodreadskosync.goodreads.http")
    local http = ctx.http
    -- Resolve relative image URLs against the page the challenge came from,
    -- not the provider base.
    local base = ctx.challenge_url or http.base_url
    local url = Http.absolute(base, challenge.image_url)
    local resp = http:get(url, { follow = true, detect_auth = false })
    if resp.error or not resp.body or resp.body == "" then
        Widgets.message(_("Could not load the verification image."), 5)
        return
    end

    local ext = url:match("%.png") and "png" or "jpg"
    local path = Storage.getBaseDir() .. "/challenge." .. ext
    local file = io.open(path, "wb")
    if file then
        file:write(resp.body)
        file:close()
    end

    local ImageViewer = require("ui/widget/imageviewer")
    local viewer
    viewer = ImageViewer:new{
        image = path,
        caption = _("Type these characters, then tap to continue"),
    }
    local orig_onClose = viewer.onClose
    local chained = false
    viewer.onClose = function(this)
        orig_onClose(this)
        if not chained then
            chained = true
            self:promptChallenge()
        end
    end
    UIManager:show(viewer)
end

function Goodreads:promptChallenge()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Enter the characters shown"),
        input = "",
        buttons = { {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Submit"),
                callback = function()
                    local answer = dialog:getInputText()
                    UIManager:close(dialog)
                    self:submitChallenge(answer)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Goodreads:reportLoginFailure(result)
    local error = result and result.error
    local stage = result and result.stage
    Logging.warn("login failed: stage=", tostring(stage), "error=", tostring(error))
    if error == Constants.ERROR.SIGNIN_BLOCKED then
        Widgets.message(_("Login failed: Goodreads is asking for a check that can't be completed here. Please try again later, or on another network."), 10)
    elseif error == Constants.ERROR.INVALID_CREDENTIALS then
        Widgets.message(_("Login failed: check your email and password."), 8)
    elseif error == Constants.ERROR.NETWORK_ERROR then
        Widgets.message(_("Login failed: no network connection. Check Wi-Fi and try again."), 8)
    elseif error == Constants.ERROR.SERVER_ERROR
        or error == Constants.ERROR.INVALID_RESPONSE then
        Widgets.message(_("Login failed: Goodreads didn't respond properly. Please try again in a little while."), 10)
    else
        Widgets.message(string.format(
            _("Login failed (%s: %s). Please try again in a little while."),
            tostring(stage or "?"), tostring(error or "?")), 10)
    end
end

function Goodreads:logout()
    Auth.logout()
    self._provider = nil
    if not self:getSetting("remember_password") then
        Credentials.clear()
    end
    Widgets.message(_("Logged out."))
end

function Goodreads:testConnection()
    self:runWhenOnline(function() self:_testConnection() end)
end

function Goodreads:_testConnection()
    self:runAsync(function()
        local completed, ok, err = self:runInBackground(
            _("Testing Goodreads connection…"),
            function() return Auth.validate_session() end)
        if completed == false then return end
        if ok then
            Widgets.message(_("Connection OK."))
        elseif err == Constants.ERROR.AUTH_REQUIRED then
            Widgets.message(_("Goodreads login has expired. Please log in again."), 6)
        elseif err == Constants.ERROR.SIGNIN_BLOCKED then
            Widgets.message(_("Connection blocked by a Goodreads sign-in check."), 6)
        else
            Widgets.message(_("Connection failed."), 5)
        end
    end)
end

function Goodreads:showProviderChooser()
    local dialog
    local buttons = {}
    for _i, entry in ipairs(self:getProviderList()) do
        local id = entry.id
        buttons[#buttons + 1] = { {
            text = string.format("%s%s", entry.name,
                entry.available and "" or _(" (unavailable)")),
            enabled = entry.available,
            callback = function()
                UIManager:close(dialog)
                self:selectProvider(id)
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    } }
    dialog = require("ui/widget/buttondialog"):new{
        title = _("Choose provider"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Goodreads:showDiagnostics()
    local provider = self:getProvider()
    local available = false
    if provider then available = provider:is_available() end
    local session = Auth.get_session()
    local last = Auth.get_last_login()
    local lines = {
        Logging.diagnosticSummary({
            plugin_version = Constants.VERSION,
            provider = provider and provider:get_id() or "none",
            provider_available = tostring(available),
            queue_size = Queue.size(),
            mappings_count = Mappings.count(),
        }),
        string.format("session_state=%s", tostring(session.state)),
    }
    if last then
        lines[#lines + 1] = string.format("last_login_ok=%s stage=%s error=%s",
            tostring(last.ok), tostring(last.stage), tostring(last.error))
    end
    local last_error = self:getSetting("last_sync_error")
    if last_error then
        lines[#lines + 1] = string.format("last_sync_error=%s", tostring(last_error))
    end
    lines[#lines + 1] = "login_log=" .. Storage.getBaseDir() .. "/login.log"
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
        timeout = 20,
    })
end

function Goodreads:showQueue()
    local pending = Queue.due()
    local failed = Queue.failed()
    local lines = { _("Waiting to sync"), "" }
    local failed_label = _("failed")
    for _, op in ipairs(pending) do
        lines[#lines + 1] = string.format("• %s", op.operation)
    end
    for _, op in ipairs(failed) do
        lines[#lines + 1] = string.format("• %s - %s", op.operation,
            op.last_error or failed_label)
    end
    if #pending == 0 and #failed == 0 then
        lines[#lines + 1] = _("Nothing is waiting.")
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    if #pending > 0 then
        buttons[#buttons + 1] = { {
            text = _("Sync now"),
            callback = function()
                UIManager:close(dialog)
                self:syncNow()
            end,
        } }
    end
    if #failed > 0 then
        buttons[#buttons + 1] = { {
            text = _("Clear failed syncs"),
            callback = function()
                UIManager:close(dialog)
                Queue.clearFailed()
                Widgets.notify(_("Failed syncs cleared."))
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    } }
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        buttons = buttons,
        width_factor = 0.9,
    }
    UIManager:show(dialog)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Goodreads:onReaderReady()
    if self.page_mapper then self.page_mapper:cachePageMap() end
    self:registerHighlight()
    self:maybeCheckForUpdates()

    if not self:getSetting("sync_on_open") then return end
    UIManager:nextTick(function()
        if not self:hasDocument() then return end
        if not Auth.is_authenticated() then
            self:maybeOnboard()
            -- Only ask to sign in when we actually know the session expired.
            if Auth.session_expired() then
                self:promptLoginOnOpen()
            end
            return
        end
        local mapping = self:currentMapping()
        if mapping and mapping.goodreads_id then
            self:syncSilently({ force_remote = true })
        else
            local identity = self:currentIdentity()
            if self:isIdentifySnoozed(identity.local_key) then
                return
            end
            if self:isOnline() then
                -- Link automatically to the best match and show a small toast.
                self:identifyCurrent()
            elseif self:getSetting("auto_link") then
                -- Offline: defer linking (onNetworkConnected/onResume will do
                -- it) and let the user know it will happen.
                local t = shortTitle(identity.title)
                Widgets.notify(t and string.format(_("%s · will link when online"), t)
                    or _("Offline · will link when online"), 3)
            end
        end
    end)
end

function Goodreads:onUpdatePos()
    if self.page_mapper then self.page_mapper:cachePageMap() end
end

-- Track-by-percent / track-by-pages: throttled progress checks on page turns.
function Goodreads:onPageUpdate(_)
    if not self:getSetting("auto_progress") then return end
    if (self:getSetting("track_mode") or "time") == "time" then return end
    if not Auth.is_authenticated() then return end
    local mapping, identity = self:currentMapping()
    if not mapping or not mapping.goodreads_id then return end
    self._page_update(identity.local_key)
end

function Goodreads:_onProgressChanged(local_key)
    local mapping = Mappings.get(local_key)
    if not mapping then return end
    local percent = self:currentPercent()
    if not percent then return end
    local state = State.get(local_key)
    local mode = self:getSetting("track_mode") or "time"
    local should = false
    if mode == "percent" then
        local step = tonumber(self:getSetting("track_percent_step")) or 1
        local last = state.last_successful_percent or 0
        should = math.abs(percent - last) >= step
    elseif mode == "pages" then
        local step = tonumber(self:getSetting("track_page_step")) or 5
        local mapped = self:_mappedPage(local_key)
        local last = state.last_successful_page or 0
        should = mapped and math.abs(mapped - last) >= step
    end
    if should then self:syncSilently() end
end

-- "Add note to Goodreads" entry in the highlight dialog.
function Goodreads:registerHighlight()
    if not self.ui or not self.ui.highlight
        or type(self.ui.highlight.addToHighlightDialog) ~= "function" then
        return
    end
    self.ui.highlight:removeFromHighlightDialog("goodreads_note")
    self.ui.highlight:addToHighlightDialog("goodreads_note", function(this)
        return {
            text = _("Goodreads KO Sync: Add note"),
            enabled_func = function()
                return self:hasDocument() and self:currentMapping() ~= nil
            end,
            callback = function()
                local selected = this.selected_text
                self:promptNote(selected and selected.text or "")
                this:onClose()
            end,
        }
    end)
end

function Goodreads:unregisterHighlight()
    if self.ui and self.ui.highlight
        and type(self.ui.highlight.removeFromHighlightDialog) == "function" then
        self.ui.highlight:removeFromHighlightDialog("goodreads_note")
    end
end

function Goodreads:promptNote(text)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Add a note to Goodreads"),
        input = text or "",
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Post"),
                callback = function()
                    local note = dialog:getInputText()
                    UIManager:close(dialog)
                    self:postNote(note)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Goodreads:postNote(note)
    if not note or note == "" then return end
    local mapping = self:currentMapping()
    if not mapping or not mapping.goodreads_id then return end
    local percent = self:currentPercent() or 0
    local provider = self:getProvider()
    self:runAsync(function()
        local completed, ok = self:runInBackground(_("Posting note…"), function()
            return provider:update_progress(mapping.goodreads_id, percent, "percent", note)
        end)
        if completed == false then return end
        Widgets.notify(ok and _("Note posted") or _("Note failed"))
    end)
end

-- Turn a GitHub release body into short plain text for the update prompt.
function Goodreads:formatReleaseNotes(text)
    if type(text) ~= "string" or text == "" then return nil end
    text = text:gsub("\r\n", "\n")
    text = text:gsub("^#+%s*", "")
    text = text:gsub("\n#+%s*", "\n")
    text = text:gsub("%*%*", "")
    text = text:gsub("`", "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    if #text > 600 then text = text:sub(1, 600) .. "…" end
    return text
end

function Goodreads:checkForUpdates(manual)
    self:runWhenOnline(function()
        self:runAsync(function()
            local completed, info, err = self:runInBackground(
                manual and _("Checking for updates…") or nil,
                function()
                    local ok, a, b = pcall(Update.check)
                    if not ok then return nil, tostring(a) end
                    return a, b
                end)
            if completed == false then return end
            if not info then
                Logging.trace("update: check failed", tostring(err))
                if manual then
                    Widgets.notify(string.format(
                        _("Couldn't check for updates (%s)."), tostring(err or "?")), 5)
                end
                return
            end
            self:setSetting("update_last_check", os.time())
            if not Update.is_newer(info.version, Constants.VERSION) then
                if manual then Widgets.notify(_("You're up to date.")) end
                return
            end
            local msg = string.format(_("Goodreads KO Sync %s is available."), info.version)
            local notes = self:formatReleaseNotes(info.notes)
            if notes then msg = msg .. "\n\n" .. notes end
            msg = msg .. "\n\n" .. _("Download and install now? KOReader will need a restart.")
            Widgets.confirm(
                msg,
                function() self:installUpdate(info) end,
                _("Update"))
        end)
    end)
end

function Goodreads:installUpdate(info)
    local plugin_dir = self.path
    if not plugin_dir or not Update.isWritable(plugin_dir) then
        Widgets.message(_("This install location is read-only; please update manually."), 6)
        return
    end
    self:runAsync(function()
        local completed, ok, err = self:runInBackground(
            _("Downloading update…"),
            function()
                local ran, res, reason = pcall(Update.install, info, plugin_dir)
                if not ran then return false, tostring(res) end
                return res, reason
            end)
        if completed == false then return end
        if ok then
            UIManager:askForRestart(_("Goodreads KO Sync updated. Restart KOReader to apply."))
        else
            Widgets.message(string.format(_("Update failed: %s"), tostring(err)), 6)
        end
    end)
end

-- Daily, silent background check (only asks if a newer version exists).
function Goodreads:maybeCheckForUpdates()
    if not self:getSetting("auto_update_check") then return end
    local last = tonumber(self:getSetting("update_last_check")) or 0
    if os.time() - last < Constants.UPDATE_CHECK_INTERVAL then return end
    if not self:isOnline() then return end
    UIManager:scheduleIn(30, function() self:checkForUpdates(false) end)
end

-- Friendly nudge when a book is opened while signed out (once per session,
-- toast only — signing in stays a manual action from the menu).
function Goodreads:promptLoginOnOpen()
    if self._login_prompted then return end
    self._login_prompted = true
        Widgets.notify(_("Session expired · sign in from Account"), 6)
end

-- Build a progress payload that preserves the chosen unit (percent or pages).
function Goodreads:progressPayload(local_key)
    local percent = self:currentPercent()
    if percent == nil then return nil end
    local payload = { type = "progress", percent = percent, value = percent, unit = "percent" }
    if (self:getSetting("track_mode") or "time") == "pages" then
        local mapped = self:_mappedPage(local_key)
        if mapped then
            payload.value = mapped
            payload.unit = "pages"
        end
    end
    return payload
end

function Goodreads:onCloseDocument()
    -- Capture progress before the document is torn down, then queue a final sync.
    if not self:getSetting("sync_on_close") then return end
    if not self:hasDocument() then return end
    local mapping, identity = self:currentMapping()
    if not mapping or not mapping.goodreads_id then return end
    local payload = self:progressPayload(identity.local_key)
    if not payload then return end
    -- Only queue progress Goodreads doesn't already have (avoids re-pushing the
    -- same percent, e.g. 4%, again on close).
    if Progress.shouldSync(State.get(identity.local_key), payload.percent) then
        Queue.enqueue({
            operation = "progress",
            book_id = mapping.goodreads_id,
            local_key = identity.local_key,
            payload = payload,
        })
    end
    if self:currentStatus() == "complete" then
        Queue.enqueue({
            operation = "shelf",
            book_id = mapping.goodreads_id,
            payload = { type = "shelf", shelf = Constants.SHELF.READ },
        })
    end
    State.patch(identity.local_key, { last_local_percent = payload.percent })

    if not self:isOnline() then
        local t = shortTitle(mapping.title or identity.title)
        if t then
            Widgets.notify(string.format(_("%s · %d%% saved offline"), t, payload.percent), 3)
        else
            Widgets.notify(_("Saved offline · will sync when connected"), 3)
        end
    end

    -- Flush the queue now so the final progress isn't delayed until the next
    -- timer tick or resume.
    self:processQueue()
end

function Goodreads:onSuspend()
    if self:hasDocument() then
        local mapping, identity = self:currentMapping()
        if mapping and mapping.goodreads_id then
            local payload = self:progressPayload(identity.local_key)
            if payload and Progress.shouldSync(State.get(identity.local_key), payload.percent) then
                Queue.enqueue({
                    operation = "progress",
                    book_id = mapping.goodreads_id,
                    local_key = identity.local_key,
                    payload = payload,
                })
            end
        end
    end
end

function Goodreads:onResume()
    self:maybeIdentifyOnReconnect()
    -- One flush path only: an engine run also flushes the queue, so a separate
    -- processQueue() here would send the same pending progress twice.
    local mapping = self:currentMapping()
    if self:hasDocument() and mapping and mapping.goodreads_id and self:isOnline() then
        self:syncSilently()
    else
        self:processQueue()
    end
    self:_runPendingOnline()
end

-- Flush the queue, link if needed, and push the open book's progress as soon
-- as connectivity returns, so nothing read offline waits for a checkpoint.
function Goodreads:onNetworkConnected()
    self:maybeIdentifyOnReconnect()
    local mapping = self:currentMapping()
    if self:hasDocument() and mapping and mapping.goodreads_id and self:isOnline() then
        self:syncSilently()
    else
        self:processQueue()
    end
    self:_runPendingOnline()
end

-- Deferred linking: when connectivity returns, identify/link the currently
-- open book if it is still unmapped. Only when Auto-link is on, so we never
-- pop a candidate dialog out of nowhere while reading.
function Goodreads:maybeIdentifyOnReconnect()
    if not self:hasDocument() then return end
    if not self:isOnline() then return end
    if not Auth.is_authenticated() then return end
    if not self:getSetting("auto_link") then return end
    local mapping = self:currentMapping()
    if mapping and mapping.goodreads_id then return end
    local identity = self:currentIdentity()
    if self:isIdentifySnoozed(identity.local_key) then return end
    self:identifyCurrent({ no_cache = true })
end

-- React when KOReader book status/metadata changes (e.g. the file-manager
-- book-info dialog). The event name differs across KOReader versions.
function Goodreads:onInvalidateMetadataCache(file)
    self:_onBookMetadataChanged(file)
end

function Goodreads:onDocSettingsItemsChanged(file, doc_settings)
    self:_onBookMetadataChanged(file, doc_settings)
end

function Goodreads:_onBookMetadataChanged(file, _doc_settings)
    if not file or not self:hasDocument() then return end
    if self.ui.document.file ~= file then return end
    self:syncSilently()
end

-- Set the Goodreads shelf for the current book (manual action). Local state is
-- updated optimistically so the chooser reflects the choice immediately.
function Goodreads:setShelf(shelf)
    if not Shelves.isValid(shelf) then return end
    local mapping, identity = self:currentMapping()
    if not mapping or not mapping.goodreads_id then
        Widgets.notify(_("Not linked yet"))
        return
    end
    local local_key = identity.local_key
    local previous = State.get(local_key)

    local patch = {
        shelf = shelf,
        last_pushed_shelf = shelf,
        remote_shelf = shelf,
        remote_shelf_at = os.time(),
    }
    if shelf == Constants.SHELF.WANT_TO_READ then
        -- Keep Want to Read until reading genuinely resumes: only move to
        -- Currently Reading once progress passes where it was when set (>1%).
        patch.override_shelf = Constants.SHELF.WANT_TO_READ
        patch.override_baseline_percent = self:currentPercent() or 0
    elseif shelf == Constants.SHELF.READ then
        patch.override_shelf = Constants.SHELF.READ
        patch.override_baseline_percent = nil
    elseif shelf == Constants.SHELF.DID_NOT_FINISH then
        -- Sticky: a Did Not Finish book stays put until changed manually.
        patch.override_shelf = Constants.SHELF.DID_NOT_FINISH
        patch.override_baseline_percent = nil
    else
        patch.override_shelf = nil
        patch.override_baseline_percent = nil
    end
    State.patch(local_key, patch)

    local provider = self:getProvider()
    self:runAsync(function()
        local completed, ok = self:runInBackground(_("Updating Goodreads…"), function()
            return provider:set_shelf(mapping.goodreads_id, shelf)
        end)
        if completed == false then return end
        local t = shortTitle(mapping.title)
        if ok then
            local verb = SYNC_SHELF_VERB[shelf] or _(Shelves.label(shelf))
            Widgets.notify(t and string.format("%s · %s", t, verb) or verb)
        else
            State.set(local_key, previous)
            Widgets.notify(t and string.format(_("%s · update failed"), t)
                or _("Update failed"))
        end
    end)
end

-- End of book: mark Read when the user opted into automatic completion.
function Goodreads:onEndOfBook()
    if not self:getSetting("auto_shelf") then return end
    if self:getSetting("completion_behavior")
        ~= Constants.COMPLETION_BEHAVIOR.PERCENT_99 then
        return
    end
    if not Auth.is_authenticated() then return end
    local mapping = self:currentMapping()
    if not mapping or not mapping.goodreads_id then return end
    Queue.enqueue({
        operation = "shelf",
        book_id = mapping.goodreads_id,
        payload = { type = "shelf", shelf = Constants.SHELF.READ },
    })
    self:processQueue()
end

function Goodreads:onFlushSettings()
    if self.settings_store then self.settings_store:flush() end
end

function Goodreads:onCloseWidget()
    if self._timer then
        UIManager:unschedule(self._timer)
        self._timer = nil
    end
    self._timer_scheduled = false
    self._provider = nil
    self:unregisterHighlight()
end

--------------------------------------------------------------------------------
-- Menu
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Shelves browser (opened from the plugin menu)
--------------------------------------------------------------------------------

function Goodreads:showLibrary()
    local ok, err = pcall(LibraryUI.show, self)
    if not ok then
        Logging.error("library: show failed:", tostring(err))
        Logging.trace("library: show failed:", tostring(err))
        Widgets.message(_("Couldn't open the shelves."), 4)
    end
end

-- Persistent cache of the shelves loaded from Goodreads, so the browser opens
-- instantly and does not re-fetch until the user asks to refresh.
local function library_store()
    return Storage.open("library_cache")
end

-- Read-only view of the cached library (never does network I/O). Falls back to
-- the plugin's own linked books.
function Goodreads:cachedLibraryData()
    if self._library_cache then return self._library_cache end
    local ok, cached = pcall(function() return library_store():get("data") end)
    if ok and type(cached) == "table" and type(cached.shelves) == "table"
        and #cached.shelves > 0 then
        self._library_cache = cached
        return cached
    end
    return self:localLibraryData()
end

-- Fetch the library from the provider and cache it.
-- { shelves = {slug,name,custom,count,books}, full = bool }
function Goodreads:libraryData()
    local provider = self:getProvider()
    if provider and provider.get_library then
        local shelves = provider:get_library()
        if type(shelves) == "table" and #shelves > 0 then
            local data = { shelves = shelves, full = true, saved_at = os.time() }
            self:persistLibrary(data)
            return data
        end
    end
    return self:localLibraryData()
end

-- Persist a library structure (shelves plus any loaded books) to disk.
function Goodreads:persistLibrary(data)
    if type(data) ~= "table" or not data.full then return end
    self._library_cache = data
    pcall(function()
        local s = library_store()
        s:set("data", data)
        s:flush()
    end)
end

-- The four default shelves built only from our own linked books. Never does
-- any network I/O, so it always succeeds and can be used as a fallback.
function Goodreads:localLibraryData()
    local shelves = {
        { slug = "currently-reading", name = _("Currently Reading"), books = {} },
        { slug = "read", name = _("Read"), books = {} },
        { slug = "to-read", name = _("Want to Read"), books = {} },
        { slug = "did-not-finish", name = _("Did Not Finish"), books = {} },
    }
    local by_slug = {}
    for i = 1, #shelves do by_slug[shelves[i].slug] = shelves[i] end
    local slug_for = {
        [Constants.SHELF.CURRENTLY_READING] = "currently-reading",
        [Constants.SHELF.READ] = "read",
        [Constants.SHELF.WANT_TO_READ] = "to-read",
        [Constants.SHELF.DID_NOT_FINISH] = "did-not-finish",
    }
    for local_key, mapping in pairs(Mappings.all()) do
        if mapping.goodreads_id then
            local canonical = State.get(local_key).shelf or Constants.SHELF.WANT_TO_READ
            local slug = slug_for[canonical] or "to-read"
            local s = by_slug[slug]
            s.books[#s.books + 1] = {
                goodreads_id = tostring(mapping.goodreads_id),
                title = mapping.title or local_key,
            }
        end
    end
    return { shelves = shelves, full = false }
end

-- One page of books for a single shelf (used by the shelves browser), cached.
function Goodreads:loadShelf(shelf)
    local provider = self:getProvider()
    if not provider or not provider.get_shelf_books then return nil end
    local books = provider:get_shelf_books(shelf, 1)
    if type(books) == "table" and self._library_cache then
        shelf.books = books
        self:persistLibrary(self._library_cache)
    end
    return books
end

-- Pin our entry into the "Tools" list so it isn't buried under "More tools".
-- Mirrors how well-known plugins inject into KOReader's menu order tables.
local function injectIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }
    local function contains(tbl, target)
        if type(tbl) ~= "table" then return false end
        for _, val in pairs(tbl) do
            if val == target then
                return true
            elseif type(val) == "table" and contains(val, target) then
                return true
            end
        end
        return false
    end
    for _, path in ipairs(menu_orders) do
        local ok, order = pcall(require, path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            if not contains(order, "goodreads") then
                table.insert(order.tools, 3, "goodreads")
            end
        end
    end
end

function Goodreads:addToMainMenu(menu_items)
    injectIntoToolsMenu()
    menu_items.goodreads = {
        text_func = function()
            if Auth.is_authenticated() then
                return _("Goodreads KO Sync")
            end
            return _("Goodreads KO Sync — sign in")
        end,
        sorting_hint = "tools",
        sub_item_table_func = function() return self:buildMenu() end,
    }
end

-- Account submenu, rebuilt each time it is opened so it reflects the current
-- sign-in state (Log in when signed out, Log out when signed in).
function Goodreads:accountMenuItems()
    local items = {}
    if Auth.is_authenticated() then
        items[#items + 1] = {
            text = _("Log out"),
            callback = function()
                Widgets.confirm(_("Sign out of Goodreads?"),
                    function() self:logout() end, _("Sign out"))
            end,
        }
    else
        items[#items + 1] = {
            text = _("Log in"),
            callback = function() self:login() end,
        }
    end
    items[#items + 1] = {
        text = _("Account status"),
        callback = function() self:showAccount() end,
    }
    items[#items + 1] = {
        text = _("Test connection"),
        callback = function() self:testConnection() end,
    }
    items[#items + 1] = {
        text = _("Forget saved password"),
        callback = function() self:forgetCredentials() end,
    }
    return items
end

-- Shelf chooser for the current book. The checked state is read fresh so the
-- radio updates as soon as the user picks one.
function Goodreads:setStatusMenuItems()
    local local_key = self:currentIdentity().local_key
    local options = {
        { Constants.SHELF.WANT_TO_READ, _("Want to Read") },
        { Constants.SHELF.CURRENTLY_READING, _("Currently Reading") },
        { Constants.SHELF.READ, _("Read") },
        { Constants.SHELF.DID_NOT_FINISH, _("Did Not Finish") },
    }
    local items = {}
    for i = 1, #options do
        local shelf = options[i][1]
        items[#items + 1] = {
            text = options[i][2],
            radio = true,
            checked_func = function() return State.get(local_key).shelf == shelf end,
            callback = function() self:setShelf(shelf) end,
        }
    end
    return items
end

function Goodreads:buildMenu()
    return {
        {
            text = _("Sync now"),
            enabled_func = function() return self:hasDocument() end,
            callback = function() self:syncNow() end,
        },
        {
            text = _("Set status on Goodreads"),
            enabled_func = function() return self:hasDocument() end,
            sub_item_table_func = function() return self:setStatusMenuItems() end,
        },
        {
            text = _("Browse shelves"),
            callback = function() LibraryUI.show(self) end,
        },
        {
            text = _("Support this project"),
            callback = function() SupportUI.show() end,
        },
        {
            text = _("Account"),
            sub_item_table_func = function() return self:accountMenuItems() end,
        },
        {
            text = _("This book"),
            sub_item_table = {
                {
                    text = _("Find on Goodreads"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function() self:identifyCurrent({ no_cache = true }) end,
                },
                {
                    text = _("Change linked book"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function()
                        self:identifyCurrent({ ignore_mapping = true, no_cache = true, choose = true })
                    end,
                },
                {
                    text = _("Rate this book"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function() self:rateCurrentBook() end,
                },
                {
                    text = _("Forget link"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function()
                        Widgets.confirm(_("Forget the Goodreads link for this book?"),
                            function() self:forgetMapping() end, _("Forget"))
                    end,
                },
                {
                    text = _("Sync this book automatically"),
                    enabled_func = function() return self:hasDocument() end,
                    checked_func = function()
                        local identity = self:currentIdentity()
                        return self:isBookSyncEnabled(identity.local_key)
                    end,
                    callback = function()
                        local identity = self:currentIdentity()
                        self:setBookSetting(identity.local_key, "sync",
                            not self:isBookSyncEnabled(identity.local_key))
                    end,
                },
                {
                    text = _("Book status"),
                    enabled_func = function() return self:hasDocument() end,
                    callback = function() self:showStatus() end,
                },
            },
        },
        {
            text = _("Settings"),
            sub_item_table_func = function() return SettingsUI.build(self) end,
        },
        {
            text = _("More"),
            sub_item_table = {
                { text = _("Sync status"), callback = function() self:showDiagnostics() end },
                { text = _("Waiting to sync"), callback = function() self:showQueue() end },
                { text = _("Check for updates"), callback = function() self:checkForUpdates(true) end },
                {
                    text_func = function()
                        return string.format(_("Version: %s"), Constants.VERSION)
                    end,
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Goodreads KO Sync v%s\n%s"),
                                Constants.VERSION, Update.PAGE_URL),
                            timeout = 10,
                        })
                    end,
                },
                {
                    text = _("Clear failed syncs"),
                    callback = function()
                        Queue.clearFailed()
                        Widgets.message(_("Failed syncs cleared."))
                    end,
                },
            },
        },
    }
end

-- Exposed for tests/diagnostics without instantiating KOReader.
Goodreads.DEFAULT_SETTINGS = DEFAULT_SETTINGS

return Goodreads
