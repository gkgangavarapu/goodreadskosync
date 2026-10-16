--[[--
When to remind the user that the project can be supported (pure).

The reminder is deliberately rare and always actionable: the caller shows a
prompt whose button opens the support page (a toast cannot be tapped). This
module only decides *whether* to remind, from a small persisted state, so the
policy is unit tested without KOReader.

Policy (all times in seconds, see Constants):
  * never twice within SUPPORT_REMINDER_MIN_GAP;
  * otherwise wait until either SUPPORT_REMINDER_SYNCS successful syncs or
    SUPPORT_REMINDER_INTERVAL has passed since the last reminder;
  * the first successful sync only starts the clock, so a fresh install is never
    asked for money on its first sync.

@module koplugin.goodreads.support_reminder
--]]

local Constants = require("goodreadskosync.constants")

local SupportReminder = {}

-- Evaluate one successful sync. `state` is the persisted state:
--   { last_at = <when last reminded>, syncs = <successful syncs so far>,
--     syncs_at_last = <sync count when last reminded> }
-- Returns due, next_state - persist every field of next_state.
function SupportReminder.evaluate(state, now)
    state = state or {}
    now = now or os.time()

    local last_at = tonumber(state.last_at) or 0
    local syncs = (tonumber(state.syncs) or 0) + 1
    local syncs_at_last = tonumber(state.syncs_at_last) or 0
    local next_state = {
        last_at = last_at,
        syncs = syncs,
        syncs_at_last = syncs_at_last,
    }

    -- First successful sync: start the clock rather than reminding immediately.
    if last_at == 0 then
        next_state.last_at = now
        return false, next_state
    end

    if now - last_at < (Constants.SUPPORT_REMINDER_MIN_GAP or 0) then
        return false, next_state
    end

    local syncs_since = syncs - syncs_at_last
    if syncs_since < (Constants.SUPPORT_REMINDER_SYNCS or 0)
        and (now - last_at) < (Constants.SUPPORT_REMINDER_INTERVAL or 0) then
        return false, next_state
    end

    next_state.last_at = now
    next_state.syncs_at_last = syncs
    return true, next_state
end

return SupportReminder
