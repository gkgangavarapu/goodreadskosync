--[[--
Retry scheduler (inspired by ShelfSync).

@module koplugin.goodreads.sync.scheduler
--]]

local UIManager = require("ui/uimanager")

local Scheduler = {
    retries = {},
}

function Scheduler:clear()
    for fn in pairs(self.retries) do
        UIManager:unschedule(fn)
        self.retries[fn] = nil
    end
end

-- callback(success, fail); retries with exponential backoff up to `limit`.
function Scheduler:withRetries(limit, time_exponent, callback, success_callback, fail_callback)
    time_exponent = time_exponent or 2
    local scheduled_job
    local tries = 0

    local success = function()
        self.retries[callback] = nil
        if success_callback then success_callback() end
    end

    local fail = function()
        tries = tries + 1
        if tries < limit then
            UIManager:scheduleIn(2 ^ (time_exponent + tries), scheduled_job)
        elseif fail_callback then
            fail_callback()
        end
    end

    scheduled_job = function()
        callback(success, fail)
    end

    local cancel = function()
        UIManager:unschedule(scheduled_job)
    end

    UIManager:nextTick(scheduled_job)
    return cancel
end

return Scheduler
