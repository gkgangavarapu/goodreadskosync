local Constants = require("goodreadskosync.constants")
local SupportReminder = require("goodreadskosync.support_reminder")

-- A realistic wall-clock base: the module treats last_at == 0 as "never
-- reminded", and os.time() is never 0 in practice.
local BASE = 1700000000
local MIN_GAP = Constants.SUPPORT_REMINDER_MIN_GAP
local INTERVAL = Constants.SUPPORT_REMINDER_INTERVAL
local SYNCS = Constants.SUPPORT_REMINDER_SYNCS

-- Run `n` syncs `step` apart from `start`; returns how many were due and the
-- final state.
local function run(state, start, n, step)
    local due_count, now = 0, start
    for _ = 1, n do
        local due
        due, state = SupportReminder.evaluate(state, now)
        if due then due_count = due_count + 1 end
        now = now + (step or 0)
    end
    return due_count, state
end

describe("support_reminder.evaluate", function()
    it("does not remind on the very first sync", function()
        local due, state = SupportReminder.evaluate(nil, BASE)
        assert_false(due)
        assert_equal(1, state.syncs)
        assert_equal(BASE, state.last_at)   -- the clock starts here
    end)

    it("does not remind before the minimum gap", function()
        local _, state = SupportReminder.evaluate(nil, BASE)
        local due = SupportReminder.evaluate(state, BASE + MIN_GAP - 1)
        assert_false(due)
    end)

    it("reminds after the interval, for a light user", function()
        local _, state = SupportReminder.evaluate(nil, BASE)
        local due, next_state = SupportReminder.evaluate(state, BASE + INTERVAL)
        assert_true(due)
        assert_equal(BASE + INTERVAL, next_state.last_at)
    end)

    it("reminds after the sync count, for a heavy user", function()
        -- Eight syncs per minimum gap: the count is reached well before the
        -- interval, so only the count can trigger it.
        local step = math.floor(MIN_GAP / 8)
        local _, state = SupportReminder.evaluate(nil, BASE)
        local due_count = 0
        for i = 2, SYNCS - 1 do
            local due
            due, state = SupportReminder.evaluate(state, BASE + (i - 1) * step)
            if due then due_count = due_count + 1 end
        end
        assert_equal(0, due_count)          -- SYNCS-1 syncs in: not yet
        local due = SupportReminder.evaluate(state, BASE + (SYNCS - 1) * step)
        assert_true(due)                    -- the SYNCS-th sync triggers it
    end)

    it("never reminds twice within the minimum gap", function()
        local _, state = SupportReminder.evaluate(nil, BASE)
        local due
        due, state = SupportReminder.evaluate(state, BASE + INTERVAL)
        assert_true(due)
        -- A burst of syncs straight after must not remind again.
        local due_count = run(state, BASE + INTERVAL + 60, 50, 60)
        assert_equal(0, due_count)
    end)

    it("counts syncs even when it does not remind", function()
        local _, state = SupportReminder.evaluate(nil, BASE)
        local _, state2 = SupportReminder.evaluate(state, BASE + 300)
        assert_equal(2, state2.syncs)
        assert_equal(BASE, state2.last_at)  -- unchanged
        assert_equal(0, state2.syncs_at_last)
    end)

    it("records the sync count at the reminder", function()
        local _, state = SupportReminder.evaluate(nil, BASE)
        local due
        due, state = SupportReminder.evaluate(state, BASE + INTERVAL)
        assert_true(due)
        assert_equal(2, state.syncs_at_last)
    end)

    it("resets the counter after reminding", function()
        local _, state = SupportReminder.evaluate(nil, BASE)
        local due
        due, state = SupportReminder.evaluate(state, BASE + INTERVAL)
        assert_true(due)
        -- A few syncs later, still inside the minimum gap: nothing.
        local due_count = run(state, BASE + INTERVAL + MIN_GAP, SYNCS - 2, 300)
        assert_equal(0, due_count)
    end)
end)
