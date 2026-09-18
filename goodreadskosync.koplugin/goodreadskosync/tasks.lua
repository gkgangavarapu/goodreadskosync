--[[--
Reusable background task helpers.

Runs network-only work off the UI thread. `run` shows a dismissable trap when a
text is given (manual actions); `runSilent` never traps, so automatic syncs
can't be dismissed by a tap. Both serialize results across the fork boundary.

@module koplugin.goodreads.tasks
--]]

local Logging = require("goodreadskosync.logging")
local UIManager = require("ui/uimanager")

local Tasks = {}

-- Run `fn` in a Trapper coroutine so the subprocess helpers can fork and yield.
function Tasks.runAsync(fn)
    local ok, Trapper = pcall(require, "ui/trapper")
    if ok and Trapper and type(Trapper.wrap) == "function" then
        Trapper:wrap(fn)
    else
        fn()
    end
end

-- Returns completed, <task results>. text ~= nil => dismissable progress UI.
function Tasks.run(text, task)
    if text == nil then
        return Tasks.runSilent(task)
    end
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

-- Non-dismissable variant: no trap widget, so a tap/key cannot abort it.
function Tasks.runSilent(task)
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    local ok_buf, buffer = pcall(require, "string.buffer")
    local _coroutine = coroutine.running()
    if not (ok_ffi and ffiutil and ffiutil.runInSubProcess
        and ok_buf and buffer and _coroutine) then
        local ran, a, b, c = pcall(task)
        if not ran then
            Logging.warn("background task failed")
            return true, nil
        end
        return true, a, b, c
    end

    local pid, parent_read_fd = ffiutil.runInSubProcess(function(_, child_write_fd)
        -- selene: allow(incorrect_standard_library_use)
        local results = table.pack(task())
        local ok, str = pcall(buffer.encode, results)
        ffiutil.writeToFD(child_write_fd, ok and str or "", true)
    end, true)
    if not pid then
        local ran, a, b, c = pcall(task)
        if not ran then return true, nil end
        return true, a, b, c
    end

    local completed, ret_values = false, nil
    local check_interval_sec = 0.125
    while true do
        local go_on_func = function() coroutine.resume(_coroutine, true) end
        UIManager:scheduleIn(check_interval_sec, go_on_func)
        coroutine.yield()
        local subprocess_done = ffiutil.isSubProcessDone(pid)
        local stuff_to_read = parent_read_fd
            and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0
        if subprocess_done or stuff_to_read then
            completed = true
            if stuff_to_read then
                local ret_str = ffiutil.readAllFromFD(parent_read_fd)
                local ok, t = pcall(buffer.decode, ret_str)
                if ok and t then ret_values = t end
                if not subprocess_done then
                    local collect_and_clean
                    collect_and_clean = function()
                        if ffiutil.isSubProcessDone(pid) then return end
                        UIManager:scheduleIn(1, collect_and_clean)
                    end
                    UIManager:scheduleIn(1, collect_and_clean)
                end
            elseif parent_read_fd then
                ffiutil.readAllFromFD(parent_read_fd)
            end
            break
        end
    end
    if ret_values then
        return completed, unpack(ret_values, 1, ret_values.n)
    end
    return completed
end

return Tasks
