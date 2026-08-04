-- Non-blocking cover download queue.
--
-- KOReader's normal LuaSocket requests block the UI event loop even when
-- started from UIManager:scheduleIn(). Run one bounded request at a time in
-- KOReader's low-priority subprocess facility, poll it from the parent, and
-- retry failures with backoff. The child communicates success through the
-- deterministic cover cache path, so no shared Lua state is written.

local logger = require("logger")
local UIManager = require("ui/uimanager")

local CoverLoader = {}
CoverLoader.__index = CoverLoader

local function safe_call(label, callback, ...)
    if type(callback) ~= "function" then
        return
    end
    local ok, err = pcall(callback, ...)
    if not ok then
        logger.warn("wereaddesktop: cover loader " .. label .. " failed:", err)
    end
end

local function load_ffi_util()
    local ok, ffi_util = pcall(require, "ffi/util")
    if ok then
        return ffi_util
    end
    return nil
end

function CoverLoader:new(options)
    options = options or {}
    return setmetatable({
        bridge = assert(options.bridge, "cover loader bridge is required"),
        ui_manager = options.ui_manager or UIManager,
        ffi_util = options.ffi_util or load_ffi_util(),
        clock = options.clock or os.time,
        poll_interval = options.poll_interval or 0.25,
        worker_timeout = options.worker_timeout or 30,
        request_timeout = options.request_timeout or { 5, 20 },
        retry_delays = options.retry_delays or { 2, 8 },
        max_attempts = options.max_attempts or 3,
        on_cover = options.on_cover,
        on_failure = options.on_failure,
        on_idle = options.on_idle,
        queue = {},
        pending = {},
        active = nil,
        poll_task = nil,
        wake_task = nil,
        idle_notified = true,
    }, self)
end

function CoverLoader:_unschedule(field)
    local task = self[field]
    if task and self.ui_manager.unschedule then
        self.ui_manager:unschedule(task)
    end
    self[field] = nil
end

function CoverLoader:_schedulePoll()
    self:_unschedule("poll_task")
    local task
    task = function()
        if self.poll_task ~= task then
            return
        end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    self.ui_manager:scheduleIn(self.poll_interval, task)
end

function CoverLoader:_scheduleWake(delay)
    self:_unschedule("wake_task")
    local task
    task = function()
        if self.wake_task ~= task then
            return
        end
        self.wake_task = nil
        self:_startNext()
    end
    self.wake_task = task
    self.ui_manager:scheduleIn(math.max(0, delay), task)
end

function CoverLoader:_notifyIdle()
    if self.active or #self.queue > 0 or self.idle_notified then
        return
    end
    self.idle_notified = true
    safe_call("idle callback", self.on_idle)
end

function CoverLoader:_attachBook(entry, book)
    if entry.book_refs[book] then
        return
    end
    entry.book_refs[book] = true
    entry.books[#entry.books + 1] = book
end

function CoverLoader:enqueue(books)
    local added = 0
    for _, book in ipairs(books or {}) do
        local book_id = type(book) == "table" and tostring(book.book_id or "") or ""
        if book_id ~= "" then
            local cached = self.bridge:findCachedCover(book_id)
            if cached then
                book.cover_path = cached
            elseif type(book.cover_url) == "string" and book.cover_url ~= "" then
                local entry = self.pending[book_id]
                if entry then
                    self:_attachBook(entry, book)
                    entry.cover_url = book.cover_url
                else
                    entry = {
                        key = book_id,
                        book_id = book_id,
                        cover_url = book.cover_url,
                        books = {},
                        book_refs = {},
                        attempts = 0,
                        retry_at = 0,
                    }
                    self:_attachBook(entry, book)
                    self.pending[book_id] = entry
                    self.queue[#self.queue + 1] = entry
                    added = added + 1
                end
            end
        end
    end
    if added > 0 then
        self.idle_notified = false
        self:_startNext()
    end
    return added
end

function CoverLoader:_complete(entry, path)
    self.pending[entry.key] = nil
    for _, book in ipairs(entry.books) do
        book.cover_path = path
    end
    safe_call("completion callback", self.on_cover, entry, path)
end

function CoverLoader:_retryOrFail(entry, reason)
    if entry.attempts < self.max_attempts then
        local delay = self.retry_delays[entry.attempts]
            or self.retry_delays[#self.retry_delays]
            or 1
        entry.retry_at = self.clock() + delay
        self.queue[#self.queue + 1] = entry
        logger.warn("wereaddesktop: cover download retry scheduled:",
            "book_id=", entry.book_id,
            "attempt=", entry.attempts,
            "delay=", delay,
            "reason=", reason)
        return
    end
    self.pending[entry.key] = nil
    logger.warn("wereaddesktop: cover download exhausted retries:",
        "book_id=", entry.book_id,
        "attempts=", entry.attempts,
        "reason=", reason)
    safe_call("failure callback", self.on_failure, entry, reason)
end

function CoverLoader:_startEntry(entry)
    entry.attempts = entry.attempts + 1
    local ffi_util = self.ffi_util
    if not ffi_util or type(ffi_util.runInSubProcess) ~= "function"
        or type(ffi_util.isSubProcessDone) ~= "function" then
        self:_retryOrFail(entry, "subprocess_unavailable")
        return false
    end

    local bridge = self.bridge
    local child_book = {
        book_id = entry.book_id,
        cover_url = entry.cover_url,
    }
    local request_timeout = self.request_timeout
    local task = function()
        bridge:ensureCover(child_book, function() end, {
            timeout = request_timeout,
            -- Covers are public resources. A forked worker must never flush
            -- authentication state inherited from the parent process.
            skip_cookie = true,
            persist_response_cookies = false,
        })
    end
    local ok, pid, spawn_err = pcall(ffi_util.runInSubProcess, task)
    if not ok or not pid then
        self:_retryOrFail(entry, tostring(ok and spawn_err or pid))
        return false
    end
    self.active = {
        entry = entry,
        pid = pid,
        started_at = self.clock(),
        failure_reason = nil,
    }
    self:_schedulePoll()
    return true
end

function CoverLoader:_startNext()
    if self.active then
        return
    end
    self:_unschedule("wake_task")
    local now = self.clock()
    local ready_index
    local earliest
    for i, entry in ipairs(self.queue) do
        if (entry.retry_at or 0) <= now then
            ready_index = i
            break
        end
        if not earliest or entry.retry_at < earliest then
            earliest = entry.retry_at
        end
    end
    if not ready_index then
        if earliest then
            self:_scheduleWake(earliest - now)
        else
            self:_notifyIdle()
        end
        return
    end
    local entry = table.remove(self.queue, ready_index)
    local cached = self.bridge:findCachedCover(entry.book_id)
    if cached then
        self:_complete(entry, cached)
        self:_startNext()
        return
    end
    if not self:_startEntry(entry) then
        self:_startNext()
    end
end

function CoverLoader:_poll()
    local active = self.active
    if not active then
        self:_startNext()
        return
    end
    local ffi_util = self.ffi_util
    local ok, done = pcall(ffi_util.isSubProcessDone, active.pid)
    if not ok then
        active.failure_reason = "subprocess_poll_failed"
        if type(ffi_util.terminateSubProcess) == "function" then
            pcall(ffi_util.terminateSubProcess, active.pid)
        end
        done = true
    elseif not done
        and self.clock() - active.started_at >= self.worker_timeout then
        active.failure_reason = "worker_timeout"
        if type(ffi_util.terminateSubProcess) == "function" then
            pcall(ffi_util.terminateSubProcess, active.pid)
        end
        self:_schedulePoll()
        return
    end
    if not done then
        self:_schedulePoll()
        return
    end

    self.active = nil
    local path = self.bridge:findCachedCover(active.entry.book_id)
    if path then
        self:_complete(active.entry, path)
    else
        self:_retryOrFail(active.entry,
            active.failure_reason or "download_failed")
    end
    self:_startNext()
end

function CoverLoader:cancel()
    self:_unschedule("poll_task")
    self:_unschedule("wake_task")
    self.queue = {}
    self.pending = {}
    self.idle_notified = true
    local active = self.active
    self.active = nil
    if not active or not self.ffi_util then
        return
    end
    local ffi_util = self.ffi_util
    if type(ffi_util.terminateSubProcess) == "function" then
        pcall(ffi_util.terminateSubProcess, active.pid)
    end
    -- SIGKILL is asynchronous. Keep polling until waitpid collects the child
    -- so a cancelled cover job cannot remain as a zombie process.
    if type(ffi_util.isSubProcessDone) == "function" then
        local function reap()
            local ok, done = pcall(ffi_util.isSubProcessDone, active.pid)
            if ok and not done then
                self.ui_manager:scheduleIn(self.poll_interval, reap)
            end
        end
        self.ui_manager:scheduleIn(self.poll_interval, reap)
    end
end

return CoverLoader
