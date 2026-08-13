-- Regression harness for one-at-a-time background book downloads.
-- Run from the plugin directory:
--     luajit spec/test_book_download_runner.lua

package.path = package.path .. ";./?.lua"

local now = 0
local scheduled = {}
local function schedule_in(_, delay, fn)
    scheduled[#scheduled + 1] = { at = now + delay, fn = fn }
end
local function unschedule(_, fn)
    for i = #scheduled, 1, -1 do
        if scheduled[i].fn == fn then table.remove(scheduled, i) end
    end
end
local function advance(seconds)
    now = now + seconds
    while true do
        local selected
        for i, task in ipairs(scheduled) do
            if task.at <= now then selected = i break end
        end
        if not selected then return end
        table.remove(scheduled, selected).fn()
    end
end

local standby = 0
local ui_manager = {
    scheduleIn = schedule_in,
    unschedule = unschedule,
    preventStandby = function() standby = standby + 1 end,
    allowStandby = function() standby = standby - 1 end,
}
package.preload["ui/uimanager"] = function() return ui_manager end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["weread.lib.content"] = function()
    return { ensure_dir_tree = function() return true end }
end
package.preload["weread.lib.logger"] = function()
    local noop = function() end
    return { warn = noop, info = noop, err = noop }
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

local states = {}
local read_state_override
local function copy(value)
    local out = {}
    for key, item in pairs(value or {}) do out[key] = item end
    return out
end

local saved_books = {
    ["book-1"] = {
        book_id = "book-1",
        progress = 77,
        pending_upload_elapsed = 25,
    },
}
local settings_flushes = 0
local bridge = {
    settings = {
        cache_dir = "/cache",
        get_book = function(_, book_id)
            return copy(saved_books[tostring(book_id)])
        end,
        save_book = function(_, book_id, book)
            saved_books[tostring(book_id)] = copy(book)
        end,
        flush = function()
            settings_flushes = settings_flushes + 1
        end,
    },
    _pending_book = { book_id = "book-1" },
}
function bridge:_getDownloader()
    self.downloader = self.downloader or {}
    return self.downloader
end
function bridge:downloadBook(_book, _chapters, callback, options)
    assert(options.headless == true)
    assert(options.open_on_complete == false)
    options.on_progress("正在下载章节 1/2", 1, 2)
    self.downloader.schedule_step(function()
        options.on_progress("正在下载章节 2/2", 2, 2)
        callback("/cache/book-1/book.epub", nil, {
            failed_count = 0,
            download_record = {
                cached_file = "/cache/book-1/book.epub",
                cached_chapters = {
                    ["1"] = "/cache/book-1/book.epub",
                    ["2"] = "/cache/book-1/book.epub",
                },
                reader_url = "https://weread.qq.com/web/reader/book-1",
                -- A fork-time reading field must never replace the parent's
                -- newer value, even if a child accidentally reports it.
                progress = 1,
            },
        })
    end, 0)
    return true
end

local state_events = {}
local completions = {}
local Runner = require("weread.lib.book_download_runner")
local runner = Runner:new{
    bridge = bridge,
    ui_manager = ui_manager,
    ffi_util = ffi_util,
    clock = function() return now end,
    poll_interval = 0.1,
    read_state = function(path)
        if read_state_override then
            return read_state_override(path)
        end
        return copy(states[path])
    end,
    write_state = function(path, state)
        states[path] = copy(state)
        return true
    end,
    sleep = function(delay) now = now + delay end,
    on_state = function(state)
        state_events[#state_events + 1] = copy(state)
    end,
    on_complete = function(ok, state)
        completions[#completions + 1] = {
            ok = ok,
            status = state.status,
        }
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

local book = { book_id = "book-1", text = "测试书" }
local chapters = { { chapterUid = 1 }, { chapterUid = 2 } }
local started = runner:start(book, chapters, { include_comments = false })
check("start returns before child network work runs",
    started == true and child_tasks[101] ~= nil
    and states["/cache/book-1/download-status.json"].progress == 0)
check("standby is held while the background job is active", standby == 1)
local started_twice, busy_err = runner:start(book, chapters, {})
check("only one book can download at a time",
    started_twice == false and busy_err == "download_in_progress")

child_tasks[101]()
check("child reports chapter progress through shared state",
    states["/cache/book-1/download-status.json"].status == "complete"
    and states["/cache/book-1/download-status.json"].progress == 2)
check("completion waits for parent polling", #completions == 0)
local race_reads = 0
read_state_override = function(path)
    race_reads = race_reads + 1
    if race_reads == 1 then
        return {
            book_id = "book-1",
            status = "running",
            progress = 2,
            total = 2,
        }
    end
    return copy(states[path])
end
child_done[101] = true
advance(0.1)
read_state_override = nil
check("completed child is collected and reported",
    #completions == 1 and completions[1].ok == true
    and completions[1].status == "complete")
check("parent re-reads terminal state after observing child exit",
    race_reads == 2 and states["/cache/book-1/download-status.json"].status
        == "complete")
check("parent merges download fields without reverting live reading state",
    saved_books["book-1"].cached_file == "/cache/book-1/book.epub"
    and saved_books["book-1"].cached_chapters["2"]
        == "/cache/book-1/book.epub"
    and saved_books["book-1"].progress == 77
    and saved_books["book-1"].pending_upload_elapsed == 25
    and settings_flushes == 1)
check("standby is released after completion", standby == 0)

bridge._pending_book = { book_id = "book-2" }
local book2 = { book_id = "book-2", text = "第二本" }
runner:start(book2, chapters, {})
local cancelled = runner:cancel("book-2")
check("cancelling terminates the active child",
    cancelled == true and child_terminated[102] == true)
advance(0.1)
check("cancelled job reports a recoverable terminal state",
    #completions == 2 and completions[2].ok == false
    and completions[2].status == "cancelled" and standby == 0)

bridge._pending_book = { book_id = "book-3" }
runner:start({ book_id = "book-3", text = "第三本" }, chapters, {})
runner:shutdown()
check("plugin shutdown terminates the child and releases standby immediately",
    child_terminated[103] == true and runner:isActive() == false
    and standby == 0)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
