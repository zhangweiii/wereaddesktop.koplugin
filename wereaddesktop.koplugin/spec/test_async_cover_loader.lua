-- Regression harness for non-blocking cover downloads and retries.
-- Run from the plugin directory:
--     luajit spec/test_async_cover_loader.lua

package.path = package.path .. ";./?.lua"

local now = 0
local scheduled = {}
local function schedule_in(_, delay, fn)
    scheduled[#scheduled + 1] = { at = now + delay, fn = fn }
end
local function unschedule(_, fn)
    for i = #scheduled, 1, -1 do
        if scheduled[i].fn == fn then
            table.remove(scheduled, i)
        end
    end
end
local function advance(seconds)
    now = now + seconds
    while true do
        local next_index
        local next_at
        for i, task in ipairs(scheduled) do
            if task.at <= now and (not next_at or task.at < next_at) then
                next_index = i
                next_at = task.at
            end
        end
        if not next_index then
            return
        end
        local task = table.remove(scheduled, next_index)
        task.fn()
    end
end

local ui_manager = {
    scheduleIn = schedule_in,
    unschedule = unschedule,
}
package.preload["logger"] = function()
    local noop = function() end
    return { warn = noop, info = noop, err = noop, dbg = noop }
end
package.preload["ui/uimanager"] = function()
    return ui_manager
end

local child_tasks = {}
local child_done = {}
local child_terminated = {}
local next_pid = 100
local ffi_util = {
    runInSubProcess = function(task)
        next_pid = next_pid + 1
        child_tasks[next_pid] = task
        child_done[next_pid] = false
        return next_pid
    end,
    isSubProcessDone = function(pid)
        return child_done[pid] == true
    end,
    terminateSubProcess = function(pid)
        child_terminated[pid] = true
        child_done[pid] = true
    end,
}

local attempts = {}
local covers = {}
local bridge = {
    findCachedCover = function(_, book_id)
        return covers[tostring(book_id)]
    end,
    ensureCover = function(_, book, callback, request_options)
        local id = tostring(book.book_id)
        attempts[id] = (attempts[id] or 0) + 1
        assert(request_options.timeout[1] == 5)
        assert(request_options.timeout[2] == 20)
        assert(request_options.skip_cookie == true)
        assert(request_options.persist_response_cookies == false)
        if id ~= "retry" or attempts[id] >= 3 then
            covers[id] = "/covers/" .. id .. ".jpg"
        end
        callback(covers[id])
    end,
}

local completed = {}
local failed = {}
local idle_count = 0
local CoverLoader = require("weread.lib.cover_loader")
local loader = CoverLoader:new{
    bridge = bridge,
    ui_manager = ui_manager,
    ffi_util = ffi_util,
    clock = function() return now end,
    poll_interval = 0.1,
    retry_delays = { 2, 4 },
    on_cover = function(entry, path)
        completed[#completed + 1] = entry.book_id .. "=" .. path
    end,
    on_failure = function(entry)
        failed[#failed + 1] = entry.book_id
    end,
    on_idle = function()
        idle_count = idle_count + 1
    end,
}

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local first = { book_id = "first", cover_url = "https://cdn/first.jpg" }
local retry = { book_id = "retry", cover_url = "https://cdn/retry.jpg" }
loader:enqueue{ first, retry }

check("enqueue returns without running network work",
    attempts.first == nil and attempts.retry == nil)
check("only one background child starts at a time",
    child_tasks[101] ~= nil and child_tasks[102] == nil)

child_tasks[101]()
child_done[101] = true
advance(0.1)
check("a completed cover is applied immediately",
    first.cover_path == "/covers/first.jpg"
        and completed[1] == "first=/covers/first.jpg")
check("the next cover starts after the previous child is collected",
    child_tasks[102] ~= nil)

child_tasks[102]() -- retry: first failure
child_done[102] = true
advance(0.1)
check("a failed cover waits before retrying", child_tasks[103] == nil)
advance(2)
check("the first retry runs in a new child", child_tasks[103] ~= nil)

child_tasks[103]() -- retry: second failure
child_done[103] = true
advance(0.1)
advance(4)
check("the second retry runs in a new child", child_tasks[104] ~= nil)

child_tasks[104]() -- retry: success
child_done[104] = true
advance(0.1)
check("retry success is applied without a terminal failure",
    retry.cover_path == "/covers/retry.jpg"
        and #failed == 0 and attempts.retry == 3)
check("idle fires after the queue and retries finish", idle_count == 1)

local cancelled = { book_id = "cancelled", cover_url = "https://cdn/cancelled.jpg" }
loader:enqueue{ cancelled }
loader:cancel()
check("cancel terminates the active child", child_terminated[105] == true)
check("cancelled child never runs network work", attempts.cancelled == nil)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
