--[[--
Sync orchestration: the sync engine, queue flushing, toasts and the timer.

Mixed into the plugin as methods (`self` is the plugin instance).

@module koplugin.goodreads.sync.controller
--]]

local Auth = require("goodreadskosync.auth.manager")
local Constants = require("goodreadskosync.constants")
local Engine = require("goodreadskosync.sync.engine")
local Logging = require("goodreadskosync.logging")
local Mappings = require("goodreadskosync.mappings")
local Progress = require("goodreadskosync.sync.progress")
local Queue = require("goodreadskosync.sync.queue")
local Shelves = require("goodreadskosync.sync.shelves")
local ShelfCache = require("goodreadskosync.sync.shelf_cache")
local State = require("goodreadskosync.sync.state")
local Tasks = require("goodreadskosync.tasks")
local UIManager = require("ui/uimanager")
local Util = require("goodreadskosync.util")
local Widgets = require("goodreadskosync.ui.widgets")
local _ = require("gettext")

local diag = Logging.diag
local shortTitle = Util.shortTitle

local Controller = {}


function Controller:syncNow()
    self:runWhenOnline(function() self:_syncNow() end)
end

-- Background task helpers live in goodreadskosync/tasks.lua and are reused.
function Controller:runInBackground(text, task)
    return Tasks.run(text, task)
end

function Controller:runInBackgroundNoTrap(task)
    return Tasks.runSilent(task)
end

-- Run `fn` in a Trapper coroutine so runInBackground can fork a subprocess.
function Controller:runAsync(fn)
    Tasks.runAsync(fn)
end

-- Gather the local inputs (fast, in-process) for a sync.
function Controller:syncInputs(opts)
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

function Controller:_mappedPage(local_key)
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
function Controller:_syncCore(inputs)
    local provider = self:getProvider()
    if not provider then
        return { ok = false, error = Constants.ERROR.PROVIDER_UNAVAILABLE }
    end
    if not self:isBookSyncEnabled(inputs.local_key) then
        return { ok = true, skipped = true }
    end

    diag("_syncCore: gid=", tostring(inputs.gid), " pct=", tostring(inputs.percent),
        " unit=", tostring(inputs.sync_unit), " force=", tostring(inputs.force_remote),
        " status=", tostring(inputs.status))

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

    diag("_syncCore: remote_shelf=", tostring(remote_shelf),
        " state.shelf=", tostring(state.shelf),
        " override=", tostring(state.override_shelf))

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

    for _, result in ipairs(results) do
        diag("_syncCore: result type=", tostring(result.action and result.action.type),
            " ok=", tostring(result.ok), " error=", tostring(result.error))
    end
    State.set(inputs.local_key, new_state)
    -- Flush the queue and fold its result into the summary, so an automatic
    -- open/reconnect sync that sends a queued item still shows a toast.
    local flush = self:processQueueCore()

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
    if flush and (flush.sent or 0) > 0 then
        summary.changed = true
    end
    return summary
end

function Controller:_syncNow()
    diag("event: syncNow")
    if self._sync_busy then
        -- A background sync is already running; fold this into a follow-up.
        self._sync_queued = true
        Widgets.notify(_("Syncing…"), 2)
        return
    end
    if not self:hasDocument() then
        self:_syncPending()
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

-- "Sync now" with no book open: flush the queue, then push any linked book
-- whose local progress advanced beyond what was last synced.
function Controller:_syncPending()
    self._sync_busy = true
    self:runAsync(function()
        local completed, summary = self:runInBackground(
            _("Syncing with Goodreads…"),
            function() return self:_syncPendingCore() end)
        self._sync_busy = false
        if completed == false then
            self._sync_queued = false
            return
        end
        if not summary or not summary.ok then
            Widgets.message(_("Sync failed."))
        elseif summary.changed then
            Widgets.message(_("Progress synced to Goodreads."))
        else
            Widgets.message(_("Nothing to sync."))
        end
        if self._sync_queued then
            self._sync_queued = false
            self:syncSilently()
        end
    end)
end

function Controller:_syncPendingCore()
    local provider = self:getProvider()
    if not provider then return { ok = false, error = Constants.ERROR.PROVIDER_UNAVAILABLE } end
    -- Flush anything already queued (progress, notes, shelves, ratings).
    self:processQueueCore()

    local sent, failed, changed = 0, 0, false
    for key, mapping in pairs(Mappings.all()) do
        local gid = mapping.goodreads_id
        local lk = mapping.local_key or key
        if gid and lk and self:isBookSyncEnabled(lk) then
            local state = State.get(lk)
            local local_pct = tonumber(state.last_local_percent)
            local cloud_pct = tonumber(state.last_successful_percent) or 0
            -- Respect sticky shelves: never push progress for a finished book
            -- (unless configured) or a Did Not Finish book.
            local shelf = state.shelf
            local dnf = shelf == Constants.SHELF.DID_NOT_FINISH
            local read_sticky = shelf == Constants.SHELF.READ
                and not self:getSetting("update_progress_after_finished")
                and local_pct and local_pct < 100
            if local_pct and local_pct > 0 and local_pct ~= cloud_pct
                and not dnf and not read_sticky then
                local ok, err = provider:update_progress(gid, local_pct, "percent")
                if ok then
                    state.last_successful_percent = local_pct
                    state.last_cloud_percent = local_pct
                    State.set(lk, state)
                    sent = sent + 1
                    changed = true
                else
                    Queue.enqueue({
                        operation = "progress",
                        book_id = gid,
                        local_key = lk,
                        payload = { type = "progress", percent = local_pct,
                            value = local_pct, unit = "percent" },
                    })
                    failed = failed + 1
                    diag("syncPending: failed book=", tostring(gid),
                        " error=", tostring(err))
                end
            end
        end
    end
    diag("syncPending: sent=", tostring(sent), " failed=", tostring(failed))
    return { ok = true, changed = changed, sent = sent, failed = failed }
end



-- Short, specific toast for a successful automatic sync.
function Controller:_syncToast(summary)
    local parts = {}
    if summary.pushed_shelf then
        parts[#parts + 1] = Shelves.VERB[summary.pushed_shelf] or summary.pushed_shelf
    end
    if summary.percent
        and not (summary.pushed_shelf == Constants.SHELF.READ and summary.percent >= 100) then
        parts[#parts + 1] = string.format(_("Progress %d%%"), summary.percent)
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
function Controller:_syncFailToast(err, title)
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
function Controller:_titleForBookId(book_id)
    if not book_id then return nil end
    for _, mapping in pairs(Mappings.all()) do
        if tostring(mapping.goodreads_id) == tostring(book_id) then
            return mapping.title
        end
    end
    return nil
end


-- Automatic sync (on open, periodic, resume) with light feedback.
function Controller:syncSilently(opts)
    opts = opts or {}
    diag("syncSilently: force=", tostring(opts.force_remote),
        " doc=", tostring(self:hasDocument()), " online=", tostring(self:isOnline()))
    if not self:hasDocument() then
        diag("syncSilently: no document -> skip")
        return
    end
    local mapping = self:currentMapping()
    if not mapping or not mapping.goodreads_id then
        diag("syncSilently: no mapping -> skip")
        return
    end
    -- Automatic syncs never turn Wi-Fi on: they run when already online and
    -- otherwise defer to the offline queue (flushed on reconnect/close).
    if not self:isOnline() then
        diag("syncSilently: offline -> defer")
        return
    end
    -- One sync at a time: overlapping triggers otherwise push the same progress
    -- more than once. Coalesce them into a single follow-up run.
    if self._sync_busy then
        diag("syncSilently: busy -> coalesced")
        self._sync_queued = true
        return
    end
    local inputs = self:syncInputs(opts)
    if not inputs then
        diag("syncSilently: no inputs -> skip")
        return
    end
    self._sync_busy = true
    self:runAsync(function()
        local completed, summary = self:runInBackground(nil, function()
            return self:_syncCore(inputs)
        end)
        self._sync_busy = false
        if completed == false or not summary then
            diag("syncSilently: completed=", tostring(completed), " -> abort")
            self._sync_queued = false
            return
        end
        diag("syncSilently: ok=", tostring(summary.ok),
            " changed=", tostring(summary.changed),
            " pct=", tostring(summary.percent),
            " error=", tostring(summary.error))
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

function Controller:_reportSyncSummary(summary)
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
function Controller:processQueueCore()
    local provider = self:getProvider()
    if not provider then return { sent = 0, failed = 0, permanent = 0, ids = {} } end
    local sent, failed, permanent = 0, 0, 0
    local ids, seen = {}, {}
    local sent_info = {}
    local due = Queue.due()
    diag("processQueue: due=", tostring(#due))
    for _, op in ipairs(due) do
        local ok, err
        local drop = false
        local percent
        diag("processQueue: op=", tostring(op.operation), " book=",
            tostring(op.book_id), " pct=", tostring(op.payload and op.payload.percent),
            " key=", tostring(op.local_key))
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
        elseif op.operation == "note" then
            ok, err = provider:update_progress(op.book_id,
                op.payload.value or op.payload.percent, op.payload.unit, op.payload.note)
        end
        if drop then
            diag("processQueue: drop stale progress book=", tostring(op.book_id))
            Queue.remove(op.id)
        elseif ok then
            diag("processQueue: sent op=", tostring(op.operation),
                " book=", tostring(op.book_id))
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
            sent_info[#sent_info + 1] = {
                book_id = op.book_id,
                operation = op.operation,
                percent = percent,
            }
            local key = tostring(op.book_id)
            if not seen[key] then
                seen[key] = true
                ids[#ids + 1] = op.book_id
            end
        elseif err == Constants.ERROR.AUTH_REQUIRED then
            diag("processQueue: auth required -> stop")
            -- Stop retrying until the user logs in again; leave it queued.
            break
        else
            diag("processQueue: failed op=", tostring(op.operation),
                " book=", tostring(op.book_id), " error=", tostring(err))
            if err == Constants.ERROR.NOT_FOUND then
                -- The client already re-asserted the shelf and retried; a
                -- remaining 404 is permanent, so drop it instead of looping.
                Queue.remove(op.id)
                permanent = permanent + 1
            else
                local _, became_failed = Queue.markFailure(op.id, err)
                failed = failed + 1
                if became_failed then permanent = permanent + 1 end
            end
        end
    end
    diag("processQueue: done sent=", tostring(sent), " failed=",
        tostring(failed), " permanent=", tostring(permanent))
    return { sent = sent, failed = failed, permanent = permanent, ids = ids,
        sent_info = sent_info }
end

-- Short, specific toast naming the books whose offline changes were sent and
-- what changed (progress %, shelf, rating, note).
function Controller:_flushToast(sent)
    if not sent or #sent == 0 then
        return _("Synced to Goodreads")
    end
    local labels, seen = {}, {}
    -- NOTE: index loop, not `for _, item`: the loop variable `_` would shadow
    -- the module-level gettext `_` used below.
    for i = 1, #sent do
        local item = sent[i]
        local id = tostring(item.book_id)
        if not seen[id] then
            seen[id] = true
            local action
            if item.operation == "progress" and item.percent then
                action = string.format(_("Progress %d%%"), item.percent)
            elseif item.operation == "shelf" then
                action = _("Shelf updated")
            elseif item.operation == "rating" then
                action = _("Rating updated")
            elseif item.operation == "note" then
                action = _("Note posted")
            else
                action = _("Synced")
            end
            local t = shortTitle(self:_titleForBookId(item.book_id))
            labels[#labels + 1] = t and string.format("%s · %s", t, action) or action
        end
    end
    local shown = {}
    for i = 1, math.min(#labels, 2) do shown[#shown + 1] = labels[i] end
    local label = table.concat(shown, ", ")
    local more = #labels - #shown
    if more > 0 then
        label = string.format(_("%s +%d more"), label, more)
    end
    return label
end

-- Throttled notice when queued changes can no longer be retried automatically.
function Controller:_notifyQueuedFailure(count)
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

function Controller:processQueue()
    if not self:isOnline() then return end
    self:runAsync(function()
        local completed, res = self:runInBackground(nil, function()
            return self:processQueueCore()
        end)
        if completed == false or type(res) ~= "table" then return end
        if res.sent and res.sent > 0 then
            Widgets.notify(self:_flushToast(res.sent_info), 2)
        end
        if res.permanent and res.permanent > 0 then
            self:_notifyQueuedFailure(res.permanent)
        end
    end)
end

function Controller:onSyncTimer()
    if self:isOnline() and self:getSetting("auto_progress") then
        self:syncSilently()
    end
    self:scheduleTimer()
end

function Controller:scheduleTimer()
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
return Controller
