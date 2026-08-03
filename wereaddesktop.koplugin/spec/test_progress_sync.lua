--[[--
Unit test for progressuploader.lua with fully mocked surroundings:
stubbed weread.lib.protocol / weread.lib.content, an in-memory settings
object, a recording fake client and a scheduler that runs tasks
immediately. The real weread.lib.position_mapper is used so position
mapping and same-position dedup are exercised for real.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_progress_sync.lua
--]]--

package.path = package.path .. ";./?.lua"

-- Stub protocol: payload constructors tag their output so the test can
-- tell enter-read reports from read reports.
local protocol_stub = {
    is_success_response = function(result, field)
        if type(result) ~= "table" then return false end
        local value = result[field or "succ"]
        return value == true or tonumber(value) == 1
    end,
    is_mp_book = function() return false end,
    e = function(v) return tonumber(v) or 0 end,
    web_app_id = function() return "wb_test" end,
    reader_url = function(book_id) return "https://weread.qq.com/web/reader/" .. tostring(book_id) end,
    make_enter_read_payload = function(opts)
        local p = { __kind = "enter" }
        for k, v in pairs(opts) do p[k] = v end
        return p
    end,
    make_read_payload = function(opts)
        local p = { __kind = "read" }
        for k, v in pairs(opts) do p[k] = v end
        return p
    end,
}
package.preload["weread.lib.protocol"] = function() return protocol_stub end

-- Stub content: catalog cache load and reader-state refresh are recorded.
-- (Declared before the method bodies: a local is not in scope inside its
-- own table constructor, so self-referencing closures need this order.)
local content_stub = {
    load_catalog_cache_calls = 0,
    ensure_reader_state_calls = 0,
}
function content_stub.load_catalog_cache()
    content_stub.load_catalog_cache_calls = content_stub.load_catalog_cache_calls + 1
    return nil
end
function content_stub.ensure_reader_state()
    content_stub.ensure_reader_state_calls = content_stub.ensure_reader_state_calls + 1
    return true
end
package.preload["weread.lib.content"] = function() return content_stub end

-- weread.lib.logger pcall(require "logger") fails here and goes silent;
-- weread.lib.position_mapper has no dependencies. Both load for real.

local ProgressUploader = require("progressuploader")

local failures = 0
local function check(label, cond)
    if cond then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

-- Scheduler that executes every scheduled task immediately and
-- synchronously (so retry chains run to completion inside one call).
local immediate_scheduler = {
    scheduleIn = function(_, _delay, fn) fn() end,
}

local TEST_USER_VID = "test-user"

local function stamp_test_pending_owner(book)
    if type(book) == "table" and book.pending_upload_user_vid == nil
        and (type(book.pending_upload_position) == "table"
            or (tonumber(book.pending_upload_elapsed) or 0) > 0
            or (tonumber(book.pending_replay_elapsed) or 0) > 0) then
        book.pending_upload_user_vid = TEST_USER_VID
    end
end

local function make_settings(books)
    return {
        data = {
            account = { user_vid = TEST_USER_VID },
            books = books,
        },
        cache_dir = "/cache",
        saves = 0,
        flushes = 0,
        get = function(self, key, default)
            local value = self.data[key]
            if value == nil then return default end
            if key == "books" and self.auto_owner ~= false then
                for _, book in pairs(value) do
                    stamp_test_pending_owner(book)
                end
            end
            return value
        end,
        set = function(self, key, value) self.data[key] = value end,
        flush = function(self) self.flushes = self.flushes + 1 end,
        get_book = function(self, book_id)
            local shelf = self.data.books or {}
            local book = shelf[tostring(book_id)]
            if self.auto_owner ~= false then
                stamp_test_pending_owner(book)
            end
            return book
        end,
        save_book = function(self, book_id, book)
            self.saves = self.saves + 1
            local shelf = self.data.books or {}
            shelf[tostring(book_id)] = book
            self.data.books = shelf
            return true
        end,
        remove_book = function(self, book_id)
            local shelf = self.data.books or {}
            if shelf[tostring(book_id)] == nil then
                return false
            end
            shelf[tostring(book_id)] = nil
            self.data.books = shelf
            return true
        end,
    }
end

-- Fake client: records every report_read payload; `responder(payload)`
-- decides the result (default: accepted).
local function make_client(responder)
    return {
        calls = {},
        responder = responder,
        report_read = function(self, payload, _referer)
            table.insert(self.calls, payload)
            if self.responder then
                return self.responder(payload, #self.calls)
            end
            return { succ = 1, synckey = 1000 + #self.calls }
        end,
    }
end

local BOOK_PATH = "/cache/12345/book.epub"
local function make_book()
    return {
        book_id = "12345",
        title = "Test Book",
        cached_file = BOOK_PATH,
        chapters = {
            { chapterUid = 1, chapterIdx = 1, wordCount = 1000 },
            { chapterUid = 2, chapterIdx = 2, wordCount = 1000 },
            { chapterUid = 3, chapterIdx = 3, wordCount = 1000 },
        },
        progress = 0,
        summary = "Test Book",
    }
end

-- Shared fake clock per scenario.
local clock
local function now() return clock.t end

local function make_uploader(opts)
    opts = opts or {}
    clock = { t = 100000 }
    local books = { ["12345"] = make_book() }
    local settings = make_settings(books)
    local client = make_client(opts.responder)
    local state = { fraction = opts.fraction or 0.5, online = true }
    local uploaded = {}
    local uploader = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = immediate_scheduler,
        get_fraction = function() return state.fraction end,
        is_online = function() return state.online end,
        now = now,
        -- No timer in tests: heartbeats are driven by hand via tick().
        heartbeat_interval = false,
        on_uploaded = function(book_id, position)
            table.insert(uploaded, { book_id = book_id, percent = position.percent })
        end,
    }
    return uploader, settings, client, state, uploaded, books
end

-- Drive one heartbeat tick by hand (the production timer is disabled in
-- these tests via heartbeat_interval = false).
local function tick(uploader)
    uploader:_heartbeat(uploader.generation)
end

local function count_kind(client, kind)
    local n = 0
    for _, call in ipairs(client.calls) do
        if call.__kind == kind then n = n + 1 end
    end
    return n
end

----------------------------------------------------------------
-- 1. onReaderReady: detects the book, fires the document_open report.
----------------------------------------------------------------
do
    local uploader, settings, client = make_uploader()
    local book_id = uploader:onReaderReady(BOOK_PATH)
    check("onReaderReady detects the WeRead book", book_id == "12345")
    check("document_open sends enter-read + read report", #client.calls == 2)
    check("first report is enter-read", client.calls[1] and client.calls[1].__kind == "enter")
    check("second report is read", client.calls[2] and client.calls[2].__kind == "read")
    check("read report carries the book id",
        client.calls[2] and tostring(client.calls[2].book_id) == "12345")
    check("read report carries the mapped progress (50%)",
        client.calls[2] and client.calls[2].progress == 50)
    check("successful upload persists the position", settings.flushes > 0
        and tonumber(settings.data.books["12345"].progress) == 50)
end

-- A successful heartbeat persists the pre-send pending state and the final
-- uploaded state, without an extra clear pass for the same book.
do
    local uploader, settings = make_uploader()
    uploader:onReaderReady(BOOK_PATH)
    local saves_before = settings.saves
    local flushes_before = settings.flushes
    clock.t = clock.t + 30
    tick(uploader)
    check("heartbeat coalesces the post-upload book persistence",
        settings.saves - saves_before == 2
        and settings.flushes - flushes_before == 2)
end

-- Non-WeRead path: no detection, no report.
do
    local uploader, _, client = make_uploader()
    check("onReaderReady ignores non-WeRead files",
        uploader:onReaderReady("/elsewhere/local.epub") == nil)
    check("no report for non-WeRead files", #client.calls == 0)
end

----------------------------------------------------------------
-- 2. onPageUpdate only records the position; the heartbeat timer is
--    what uploads. WeRead's rt is the active reading time not yet
--    reported, capped at the server's 60-second accounting limit.
----------------------------------------------------------------
do
    local uploader, _, client, state = make_uploader()
    uploader:onReaderReady(BOOK_PATH)
    local baseline = #client.calls -- 2 (enter + read)

    -- Heartbeat with no page turn still uploads (reading-time credit);
    -- rt is the elapsed active time since this document session opened.
    clock.t = clock.t + 45
    tick(uploader)
    check("heartbeat uploads even without a page turn",
        #client.calls == baseline + 1)
    check("first heartbeat reports the unreported active time (45s)",
        client.calls[#client.calls].elapsed_seconds == 45)

    -- Page turns never trigger network traffic themselves.
    state.fraction = 0.7
    uploader:onPageUpdate(0.7)
    check("page turn does not upload by itself", #client.calls == baseline + 1)
    check("page turn position is recorded dirty",
        uploader.last_position and uploader.last_position.percent == 70
        and uploader.dirty == true)

    -- The next heartbeat reports the turned-to position.
    clock.t = clock.t + 45
    tick(uploader)
    check("heartbeat reports the turned-to position",
        #client.calls == baseline + 2
        and client.calls[#client.calls].progress == 70
        and client.calls[#client.calls].elapsed_seconds == 45)

    -- A long offline/busy gap is drained in server-safe chunks. Only the
    -- sent chunk becomes accounted, leaving the rest for later reports.
    clock.t = clock.t + 300
    tick(uploader)
    check("one report never exceeds the server's 60s accounting limit",
        client.calls[#client.calls].elapsed_seconds == 60)
    check("only successfully sent active time is marked reported",
        uploader.last_reported_rt == 150)
    tick(uploader)
    check("backlogged active time is drained in another 60s chunk",
        client.calls[#client.calls].elapsed_seconds == 60
        and uploader.last_reported_rt == 210)

    -- Device sleep does not count as reading. A heartbeat that happens
    -- while suspended is harmless and carries no new reading seconds.
    local uploader2, _, client2 = make_uploader()
    uploader2:onReaderReady(BOOK_PATH)
    clock.t = clock.t + 30
    tick(uploader2)
    uploader2:onSuspend()
    clock.t = clock.t + 600
    tick(uploader2)
    check("suspend time is excluded from the next rt",
        client2.calls[#client2.calls].elapsed_seconds == 0)
    uploader2:onResume()
    clock.t = clock.t + 30
    tick(uploader2)
    check("active-time delta continues after resume",
        client2.calls[#client2.calls].elapsed_seconds == 30)
end

----------------------------------------------------------------
-- 3. onCloseDocument: final upload of the dirty position, state reset.
----------------------------------------------------------------
do
    local uploader, _, client, state = make_uploader()
    uploader:onReaderReady(BOOK_PATH)
    local baseline = #client.calls

    -- Move without a heartbeat in between: dirty, not yet uploaded.
    state.fraction = 0.9
    uploader:onPageUpdate(0.9)
    check("page turn without heartbeat stays unsent", #client.calls == baseline)

    uploader:onCloseDocument(0.9)
    check("document_close uploads the dirty position",
        #client.calls == baseline + 1
        and client.calls[#client.calls].progress == 90)
    check("state is reset after close",
        uploader.book_id == nil and uploader.last_position == nil)

    -- Clean close (no page turn since the last upload) must still report
    -- the tail reading time. Otherwise every short session, and the final
    -- partial heartbeat interval of longer sessions, is silently lost.
    local uploader2, _, client2 = make_uploader()
    uploader2:onReaderReady(BOOK_PATH)
    local baseline2 = #client2.calls
    clock.t = clock.t + 30
    uploader2:onCloseDocument(0.5)
    check("clean close uploads final reading time",
        #client2.calls == baseline2 + 1
        and client2.calls[#client2.calls].elapsed_seconds == 30)

    -- A close after a heartbeat reports only the active tail since that
    -- heartbeat, so each accepted rt contributes exactly once.
    local uploader3, _, client3 = make_uploader()
    uploader3:onReaderReady(BOOK_PATH)
    clock.t = clock.t + 45
    tick(uploader3)
    clock.t = clock.t + 30
    uploader3:onCloseDocument(0.5)
    check("close reports only the unreported active tail",
        client3.calls[#client3.calls].elapsed_seconds == 30)
end

----------------------------------------------------------------
-- 4. Failure handling: session-refresh retry inside _send, then the
--    scheduled retry chain; success clears dirty and fires on_uploaded.
----------------------------------------------------------------
do
    -- Enter-read success does not need a synckey; only the following read
    -- report carries the acknowledgement used to drain local state.
    local uploader, _, client = make_uploader{
        responder = function(payload)
            if payload.__kind == "enter" then
                return { succ = 1 }
            end
            return { succ = 1, synckey = 2000 }
        end,
    }
    uploader:onReaderReady(BOOK_PATH)
    check("succ-only enter proceeds directly to the read report",
        #client.calls == 2
        and client.calls[1].__kind == "enter"
        and client.calls[2].__kind == "read"
        and uploader.dirty == false)

    -- First read report rejected, accepted after refreshing and
    -- re-establishing the enter-read session.
    local rejected_once = false
    local uploader, _, client = make_uploader{
        responder = function(payload)
            if payload.__kind == "read" and not rejected_once then
                rejected_once = true
                return { errcode = -2012 }
            end
            return { succ = 1, synckey = 2001 }
        end,
    }
    local before = content_stub.ensure_reader_state_calls
    uploader:onReaderReady(BOOK_PATH)
    check("rejected read triggers reader-state refresh",
        content_stub.ensure_reader_state_calls == before + 1)
    check("refreshed retry is accepted, no scheduled retry needed",
        uploader.uploading == false and uploader.dirty == false)

    local enter_rejected = false
    local uploader_enter, _, client_enter = make_uploader{
        responder = function(payload)
            if payload.__kind == "enter" and not enter_rejected then
                enter_rejected = true
                return { errcode = -2012 }
            end
            return { succ = 1, synckey = 2002 }
        end,
    }
    local before_enter = content_stub.ensure_reader_state_calls
    uploader_enter:onReaderReady(BOOK_PATH)
    check("rejected enter refreshes state before sending read time",
        content_stub.ensure_reader_state_calls == before_enter + 1
        and client_enter.calls[1].__kind == "enter"
        and client_enter.calls[2].__kind == "enter"
        and client_enter.calls[3].__kind == "read")
    check("read time is sent only after enter succeeds",
        uploader_enter.dirty == false and uploader_enter.entered == true)

    -- Hard failure: every read rejected -> RETRY_LIMIT retry chain runs.
    local uploader2, _, client2, state2 = make_uploader{
        responder = function() return { errcode = -1 } end,
    }
    local before2 = content_stub.ensure_reader_state_calls
    uploader2:onReaderReady(BOOK_PATH) -- document_open fails 3 attempts x 2 enters
    check("failed upload retries RETRY_LIMIT+1 times with refresh each",
        #client2.calls == 3 * 2
        and content_stub.ensure_reader_state_calls == before2 + 3)
    check("uploading flag cleared after final failure", uploader2.uploading == false)
    check("position stays dirty after failure", uploader2.dirty == true)

    -- Recover: accept again, record a new position, the next heartbeat
    -- uploads and fires on_uploaded.
    local _, _, _, _, uploaded = nil, nil, nil, nil, nil
    client2.responder = function() return { succ = 1, synckey = 2002 } end
    clock.t = clock.t + 45
    state2.fraction = 0.6
    uploader2.on_uploaded = function(book_id, position)
        uploader2._hook = { book_id = book_id, percent = position.percent }
    end
    uploader2:onPageUpdate(0.6)
    tick(uploader2)
    check("upload recovers after failures",
        uploader2.dirty == false and uploader2.last_uploaded ~= nil)
    check("on_uploaded hook fires with book and position",
        type(uploader2._hook) == "table"
        and tostring(uploader2._hook.book_id) == "12345"
        and uploader2._hook.percent == 60)
end

-- A restored offline backlog remains manual, but it must not force later
-- online reading time into that backlog. Heartbeats report only the new online
-- session delta and leave the restored amount unchanged.
do
    local _, settings, client, state = make_uploader{ fraction = 0.9 }
    local book = settings.data.books["12345"]
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.9, percent = 90,
        chapter_uid = 3, chapter_idx = 3, chapter_offset = 800,
        summary = "Test Book",
    }
    book.pending_upload_elapsed = 90
    book.pending_upload_started_at = clock.t - 90
    book.pending_upload_updated_at = clock.t
    local active = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = immediate_scheduler,
        get_fraction = function() return state.fraction end,
        is_online = function() return state.online end,
        now = now,
        heartbeat_interval = false,
    }
    active:onReaderReady(BOOK_PATH)
    check("restored backlog open reports progress with rt=0",
        client.calls[#client.calls].elapsed_seconds == 0)
    clock.t = clock.t + 30
    tick(active)
    check("later online heartbeat reports only new session time",
        client.calls[#client.calls].elapsed_seconds == 30)
    check("online heartbeat does not consume the manual offline backlog",
        settings.data.books["12345"].pending_upload_elapsed == 90)
end

-- A live-device failure returned succ=1 without synckey for every read
-- report. Such a response did not credit the cloud account, so it must be
-- treated as unconfirmed and must never clear the durable pending queue.
do
    local uploader, settings = make_uploader{
        responder = function(payload)
            if payload.__kind == "enter" then
                return { succ = 1 }
            end
            return { succ = 1 }
        end,
    }
    local before = content_stub.ensure_reader_state_calls
    uploader:onReaderReady(BOOK_PATH)
    local book = settings.data.books["12345"]
    check("succ without synckey triggers reader-state refresh",
        content_stub.ensure_reader_state_calls == before + 3)
    check("succ without synckey keeps durable pending progress",
        type(book.pending_upload_position) == "table"
        and uploader.dirty == true)
end

do
    local uploader, settings = make_uploader{
        responder = function(payload)
            if payload.__kind == "enter" then
                return { succ = 1 }
            end
            return { succ = 0, synckey = 9999 }
        end,
    }
    uploader:onReaderReady(BOOK_PATH)
    check("rejected response with synckey keeps durable pending progress",
        type(settings.data.books["12345"].pending_upload_position) == "table")
end

----------------------------------------------------------------
-- 5. Offline: uploads deferred while offline, sent on close.
----------------------------------------------------------------
do
    local uploader, _, client, state = make_uploader()
    state.online = false
    uploader:onReaderReady(BOOK_PATH)
    check("offline document_open sends nothing", #client.calls == 0)

    state.fraction = 0.4
    uploader:onPageUpdate(0.4)
    check("offline page turn records but does not send",
        #client.calls == 0 and uploader.dirty == true)

    tick(uploader)
    check("offline heartbeat sends nothing, stays dirty",
        #client.calls == 0 and uploader.dirty == true)

    state.online = true
    uploader:onCloseDocument(0.4)
    check("back online: close flushes the pending position",
        #client.calls > 0 and client.calls[#client.calls].progress == 40)
end

----------------------------------------------------------------
-- 5b. Durable pending upload: a new uploader instance restores the
-- position and active-time backlog without counting the current session twice.
----------------------------------------------------------------
do
    local uploader, settings, client, state = make_uploader()
    uploader:onReaderReady(BOOK_PATH)
    state.online = false
    state.fraction = 0.8
    clock.t = clock.t + 10
    uploader:onPageUpdate(0.8)
    local pending = settings.data.books["12345"].pending_upload_position
    check("offline page turn persists pending position",
        type(pending) == "table" and pending.percent == 80)
    check("offline page turn persists active-time backlog",
        tonumber(settings.data.books["12345"].pending_upload_elapsed) == 10)

    state.online = true
    clock.t = clock.t + 600
    local recovered = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = immediate_scheduler,
        get_fraction = function() return state.fraction end,
        is_online = function() return state.online end,
        now = now,
        heartbeat_interval = false,
    }
    recovered:onReaderReady(BOOK_PATH)
    local report = client.calls[#client.calls]
    check("new reader instance restores pending progress",
        report and report.progress == 80)
    check("reopened book syncs position without consuming offline time",
        report and report.elapsed_seconds == 0)
    check("restored backlog uses its actual send time",
        report and report.now == 100610)
    check("reopened book keeps offline time for the manual action",
        settings.data.books["12345"].pending_upload_elapsed == 10
        and type(settings.data.books["12345"].pending_upload_position) == "table")
    check("manual action resumes the restored backlog",
        recovered:retryPending("12345", { include_pending_time = true }))
    check("successful manual recovery clears pending upload",
        settings.data.books["12345"].pending_upload_position == nil
        and settings.data.books["12345"].pending_upload_elapsed == nil)
end

-- A durable local position is newer than the reader's current page by
-- definition. It must be pushed before any cloud pull can jump backward and
-- replace it.
do
    local uploader, settings, client, state = make_uploader{ fraction = 0.4 }
    local book = settings.data.books["12345"]
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.8, percent = 80,
        chapter_uid = 3, chapter_idx = 3, chapter_offset = 400,
        summary = "Test Book",
    }
    book.pending_upload_elapsed = 10
    book.pending_upload_updated_at = clock.t
    local pulls = 0
    client.get_web_progress = function(_, book_id)
        pulls = pulls + 1
        return { bookId = book_id, progress = 60 }
    end
    local jumped = false
    uploader.on_sync_to = function()
        jumped = true
        state.fraction = 0.6
        return true
    end
    uploader:onReaderReady(BOOK_PATH)
    check("durable pending progress is uploaded before cloud pull",
        pulls == 0 and jumped == false
        and client.calls[#client.calls].progress == 80)
end

-- Reconnection may happen after the document was closed. A headless uploader
-- must be able to resume the durable queue without a reader position getter.
do
    local _, settings, client, state = make_uploader()
    local book = settings.data.books["12345"]
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.7, percent = 70,
        chapter_uid = 3, chapter_idx = 3, chapter_offset = 100,
        summary = "Test Book",
    }
    book.pending_upload_elapsed = 15
    book.pending_upload_updated_at = clock.t
    local background = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = immediate_scheduler,
        is_online = function() return state.online end,
        now = now,
        heartbeat_interval = false,
    }
    check("headless pending retry API exists",
        type(background.retryPending) == "function")
    if type(background.retryPending) == "function" then
        check("headless manual-time retry starts",
            background:retryPending("12345",
                { include_pending_time = true }) == true)
        check("headless pending retry clears only confirmed queue",
            settings.data.books["12345"].pending_upload_position == nil)
    end
end

-- The server only credits one 60-second chunk per real minute. A closed-book
-- backlog must therefore stay durable and schedule later chunks instead of
-- draining them back-to-back behind misleading succ=1 responses.
do
    local queue = {}
    local queued_scheduler = {
        scheduleIn = function(_, delay, fn)
            table.insert(queue, { delay = delay, fn = fn })
        end,
    }
    local function run_next()
        local task = table.remove(queue, 1)
        if task then task.fn() end
    end

    clock = { t = 100000 }
    local book = make_book()
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.7, percent = 70,
        chapter_uid = 3, chapter_idx = 3, chapter_offset = 100,
        summary = "Test Book",
    }
    book.pending_upload_elapsed = 125
    book.pending_upload_started_at = clock.t - 125
    book.pending_upload_updated_at = clock.t
    local settings = make_settings({ ["12345"] = book })
    local client = make_client()
    local state = { online = true }
    local background = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = queued_scheduler,
        is_online = function() return state.online end,
        now = now,
        heartbeat_interval = false,
    }

    check("paced backlog retry starts", background:retryPending("12345",
        { include_pending_time = true }))
    run_next() -- first chunk's 0.1s network task
    local first = client.calls[#client.calls]
    check("first backlog chunk is sent immediately with current time",
        first and first.__kind == "read" and first.elapsed_seconds == 60
        and first.now == clock.t)
    check("remaining backlog stays durable while pacing",
        settings.data.books["12345"].pending_upload_elapsed == 65
        and type(settings.data.books["12345"].pending_upload_position) == "table")
    check("next backlog chunk waits for the server accounting window",
        queue[1] and queue[1].delay == 61)

    clock.t = clock.t + 61
    run_next() -- paced continuation queues its 0.1s network task
    run_next() -- second chunk
    local second = client.calls[#client.calls]
    check("second backlog chunk uses its actual later send time",
        second and second.__kind == "read" and second.elapsed_seconds == 60
        and second.now == clock.t)
    check("final partial chunk is paced too",
        settings.data.books["12345"].pending_upload_elapsed == 5
        and queue[1] and queue[1].delay == 61)

    clock.t = clock.t + 61
    run_next()
    run_next()
    local final = client.calls[#client.calls]
    check("paced backlog eventually drains completely",
        final and final.elapsed_seconds == 5
        and settings.data.books["12345"].pending_upload_position == nil
        and background.book_id == nil)
end

-- Reconnection automatically sends the latest position with rt=0 while
-- preserving offline reading time for the explicit Settings action.
do
    local _, settings, client, state = make_uploader()
    local book = settings.data.books["12345"]
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.9, percent = 90,
        chapter_uid = 3, chapter_idx = 3, chapter_offset = 800,
        summary = "Test Book",
    }
    book.pending_upload_elapsed = 90
    book.pending_upload_started_at = clock.t - 90
    book.pending_upload_updated_at = clock.t
    local background = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = immediate_scheduler,
        is_online = function() return state.online end,
        now = now,
        heartbeat_interval = false,
    }
    check("automatic reconnect progress-only retry starts",
        background:retryPending("12345", { progress_only = true }))
    local report = client.calls[#client.calls]
    check("automatic reconnect sends latest position without reading time",
        report and report.progress == 90 and report.elapsed_seconds == 0)
    check("automatic reconnect preserves offline time for manual upload",
        settings.data.books["12345"].pending_upload_elapsed == 90
        and type(settings.data.books["12345"].pending_upload_position) == "table")
end

----------------------------------------------------------------
-- 6. Pull direction: on open, a newer cloud position jumps the reader
--    forward before the initial upload; a stale one never clobbers it.
----------------------------------------------------------------
do
    -- Cloud ahead (80% vs local 50%): jump, then upload the NEW position.
    local uploader, _, client, state = make_uploader()
    client.get_web_progress = function(_, book_id)
        return { bookId = book_id, progress = 80 }
    end
    local synced_to = nil
    uploader.on_sync_to = function(fraction)
        synced_to = fraction
        state.fraction = fraction -- the real callback jumps the reader
        return true
    end
    uploader:onReaderReady(BOOK_PATH)
    check("cloud-ahead open jumps to the cloud fraction",
        type(synced_to) == "number" and math.abs(synced_to - 0.8) < 0.001)
    check("initial upload after jump carries the new position, not the stale one",
        client.calls[#client.calls]
        and client.calls[#client.calls].progress == 80)

    -- Cloud behind (20% vs local 50%): no jump, local pushes forward.
    local uploader2, _, client2 = make_uploader()
    client2.get_web_progress = function(_, book_id)
        return { bookId = book_id, progress = 20 }
    end
    local jumped2 = false
    uploader2.on_sync_to = function() jumped2 = true return true end
    uploader2:onReaderReady(BOOK_PATH)
    check("cloud-behind open does not jump", jumped2 == false)
    check("cloud-behind open uploads the local position",
        client2.calls[#client2.calls]
        and client2.calls[#client2.calls].progress == 50)

    -- Cloud within the threshold (50.2% vs 50%): no jump.
    local uploader3, _, client3 = make_uploader()
    client3.get_web_progress = function(_, book_id)
        return { bookId = book_id, progress = 50, chapterOffset = 6,
            chapterUid = 2, updateTime = 1 }
    end
    -- chapter walk: (1000+6)/3000 = 33.5% -> behind, stays put
    local jumped3 = false
    uploader3.on_sync_to = function() jumped3 = true return true end
    uploader3:onReaderReady(BOOK_PATH)
    check("cloud within threshold does not jump", jumped3 == false)

    -- Pull failure: both endpoints error -> no jump, upload proceeds.
    local uploader4, _, client4 = make_uploader()
    client4.get_progress = function() error("gateway down") end
    client4.get_web_progress = function() return nil, "http 500" end
    local jumped4 = false
    uploader4.on_sync_to = function() jumped4 = true return true end
    uploader4:onReaderReady(BOOK_PATH)
    check("failed pull does not jump", jumped4 == false)
    check("failed pull still uploads the local position",
        client4.calls[#client4.calls]
        and client4.calls[#client4.calls].progress == 50)

    -- Chapter coordinates: cloud at chapter 3 offset 500/1000 -> 83.3%.
    local uploader5, _, client5, state5 = make_uploader()
    client5.get_progress = function(_, book_id)
        return { bookId = book_id, progress = 50, chapterUid = 3,
            chapterOffset = 500, updateTime = 100 }
    end
    local synced5 = nil
    uploader5.on_sync_to = function(fraction)
        synced5 = fraction
        state5.fraction = fraction
        return true
    end
    uploader5:onReaderReady(BOOK_PATH)
    check("chapter-uid cloud position maps to whole-book fraction",
        type(synced5) == "number" and math.abs(synced5 - 2500 / 3000) < 0.001)
    check("upload after chapter-based jump uses the new position",
        client5.calls[#client5.calls]
        and client5.calls[#client5.calls].progress == 83)

    -- A failed jump callback must not claim that the reader moved.
    local uploader6 = make_uploader()
    uploader6.client.get_web_progress = function(_, book_id)
        return { bookId = book_id, progress = 80 }
    end
    uploader6.on_sync_to = function() error("jump failed") end
    uploader6:onReaderReady(BOOK_PATH)
    check("failed cloud jump is not marked as applied",
        uploader6._pulled_ahead == false)
end

----------------------------------------------------------------
-- 7. Queued scheduler (like the real UIManager): the close upload's task
--    and retry chain keep the session alive after onCloseDocument returns.
----------------------------------------------------------------
do
    local queue = {}
    local queued_scheduler = {
        scheduleIn = function(_, delay, fn)
            table.insert(queue, { delay = delay, fn = fn })
        end,
    }
    local function run_next()
        local task = table.remove(queue, 1)
        if task then task.fn() end
    end

    clock = { t = 100000 }
    local books = { ["12345"] = make_book() }
    local settings = make_settings(books)
    local client = make_client()
    local state = { fraction = 0.5, online = true }
    local uploader = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = queued_scheduler,
        get_fraction = function() return state.fraction end,
        is_online = function() return state.online end,
        now = now,
        heartbeat_interval = false, -- keep the queue deterministic
    }
    uploader:onReaderReady(BOOK_PATH)
    while #queue > 0 do run_next() end -- document_open chain
    local baseline = #client.calls

    -- Read for 50s without a heartbeat firing, then close.
    clock.t = clock.t + 50
    state.fraction = 0.55
    uploader:onPageUpdate(0.55)
    uploader:onCloseDocument(0.55)
    check("close: upload task survives past onCloseDocument return",
        #queue > 0 and #client.calls == baseline)
    while #queue > 0 do run_next() end
    check("close: final reading time is uploaded",
        #client.calls == baseline + 1
        and client.calls[#client.calls].__kind == "read")
    check("close: state is reset after the deferred reset runs",
        uploader.book_id == nil and uploader.last_position == nil)
end

----------------------------------------------------------------
-- 8. A failed close upload must retain the frozen session until its
--    delayed retry succeeds; retry waiting time is not reading time.
----------------------------------------------------------------
do
    local queue = {}
    local queued_scheduler = {
        scheduleIn = function(_, delay, fn)
            table.insert(queue, { delay = delay, fn = fn })
        end,
    }
    local function run_next()
        local task = table.remove(queue, 1)
        if task then task.fn() end
    end

    clock = { t = 100000 }
    local books = { ["12345"] = make_book() }
    local settings = make_settings(books)
    local client = make_client()
    local state = { fraction = 0.5, online = true }
    local uploader = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = queued_scheduler,
        get_fraction = function() return state.fraction end,
        is_online = function() return state.online end,
        now = now,
        heartbeat_interval = false,
    }
    uploader:onReaderReady(BOOK_PATH)
    while #queue > 0 do run_next() end
    local baseline = #client.calls

    local rejected = 0
    client.responder = function(payload)
        if payload.__kind == "read" and rejected < 2 then
            rejected = rejected + 1
            return { errcode = -1 }
        end
        return { succ = 1, synckey = 2003 }
    end
    clock.t = clock.t + 50
    uploader:onCloseDocument(0.5)
    run_next() -- first close attempt: both direct + refreshed sends fail
    check("close retry: session remains alive after first failure",
        uploader.book_id == "12345" and uploader.closing == true
        and #queue == 1)

    clock.t = clock.t + 30 -- retry delay must not count as reading
    while #queue > 0 do run_next() end
    check("close retry: delayed retry succeeds before state reset",
        #client.calls == baseline + 4 and uploader.book_id == nil)
    check("close retry: reports only time read before document close",
        client.calls[#client.calls].elapsed_seconds == 50)
end

----------------------------------------------------------------
-- 9. Heartbeat timer: armed on open, re-arms each tick, stops when the
--    document closes. Uses a queued scheduler to observe the task flow.
----------------------------------------------------------------
do
    local queue = {}
    local queued_scheduler = {
        scheduleIn = function(_, delay, fn)
            table.insert(queue, { delay = delay, fn = fn })
        end,
    }
    local function run_next()
        local task = table.remove(queue, 1)
        if task then task.fn() end
    end

    clock = { t = 100000 }
    local books = { ["12345"] = make_book() }
    local settings = make_settings(books)
    local client = make_client()
    local state = { fraction = 0.5, online = true }
    local uploader = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = queued_scheduler,
        get_fraction = function() return state.fraction end,
        is_online = function() return state.online end,
        now = now,
    }
    uploader:onReaderReady(BOOK_PATH)
    check("heartbeat timer is armed on open", #queue == 2) -- open report + heartbeat
    check("heartbeat timer uses official 30s cadence",
        queue[2] and queue[2].delay == 30)
    run_next() -- open report task (queues its 0.1s send)
    run_next() -- heartbeat tick fires early in FIFO order: skipped (upload busy), re-arms
    run_next() -- the open report send
    local baseline = #client.calls
    check("open report sent", baseline == 2)

    clock.t = clock.t + 30
    run_next() -- heartbeat tick: queues its send, re-arms
    run_next() -- heartbeat send
    check("heartbeat uploads on the timer",
        #client.calls == baseline + 1
        and client.calls[#client.calls].elapsed_seconds == 30)
    check("heartbeat re-armed for the next tick", #queue == 1)

    uploader:onCloseDocument(0.5)
    while #queue > 0 do run_next() end
    check("heartbeat timer stops after close", #queue == 0)
    check("no further uploads after close", #client.calls == baseline + 1)
end

----------------------------------------------------------------
-- 9. Chapter-coordinate mapping: with a document TOC aligned to the
--    chapter catalog, positions are mapped per chapter (the official
--    chapterUid/chapterOffset units) instead of the whole-book
--    word-count walk, and cloud positions jump by TOC page.
----------------------------------------------------------------
local function make_toc_uploader(opts)
    opts = opts or {}
    clock = { t = 100000 }
    local books = { ["12345"] = make_book() }
    local settings = make_settings(books)
    local client = make_client(opts.responder)
    -- Chapter 1: pages 1-100, chapter 2: 101-200, chapter 3: 201-300.
    local state = { page = opts.page or 150, online = true }
    local uploader = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = immediate_scheduler,
        get_fraction = function() return 0.5 end,
        get_page = function() return state.page end,
        get_page_count = function() return 300 end,
        get_toc = function()
            return { { page = 1 }, { page = 101 }, { page = 201 } }
        end,
        is_online = function() return state.online end,
        now = now,
        heartbeat_interval = false,
    }
    return uploader, settings, client, state
end

do
    -- Page 150: chapter 2 spans pages 101-200, intra = 49/100 -> offset
    -- 490 of 1000 words; percent = (1000+490)/3000 = 49%.
    local uploader, _, client = make_toc_uploader()
    uploader:onReaderReady(BOOK_PATH)
    local report = client.calls[#client.calls]
    check("toc mapping picks the chapter containing the page",
        report and tostring(report.chapter_uid) == "2")
    check("toc mapping scales intra-chapter pages by the word count",
        report and report.chapter_offset == 490)
    check("toc mapping percent is the word-based whole-book percent",
        report and report.progress == 49)

    -- Cloud ahead in a later chapter: jump by TOC page, then upload the
    -- new chapter coordinates.
    local uploader2, _, client2, state2 = make_toc_uploader()
    client2.get_progress = function(_, book_id)
        return { bookId = book_id, progress = 50, chapterUid = 3,
            chapterOffset = 500, updateTime = 100 }
    end
    local jumped_page = nil
    uploader2.on_sync_to_page = function(page)
        jumped_page = page
        state2.page = page -- the real callback turns the page
        return true
    end
    uploader2:onReaderReady(BOOK_PATH)
    check("cloud chapter position jumps to TOC page + offset share",
        jumped_page == 251) -- 201 + 500/1000 * 100 pages
    local report2 = client2.calls[#client2.calls]
    check("upload after the page jump uses the new chapter coordinates",
        report2 and tostring(report2.chapter_uid) == "3"
        and report2.chapter_offset == 500 and report2.progress == 83)

    -- Same chapter, cloud only 60 chars ahead (<= 100): no jump.
    local uploader3, _, client3 = make_toc_uploader()
    client3.get_progress = function(_, book_id)
        return { bookId = book_id, progress = 50, chapterUid = 2,
            chapterOffset = 550, updateTime = 100 }
    end
    local jumped3 = false
    uploader3.on_sync_to_page = function() jumped3 = true return true end
    uploader3:onReaderReady(BOOK_PATH)
    check("small same-chapter cloud lead does not jump", jumped3 == false)

    -- Same chapter, cloud 210 chars ahead: jump within the chapter.
    local uploader4, _, client4, state4 = make_toc_uploader()
    client4.get_progress = function(_, book_id)
        return { bookId = book_id, progress = 50, chapterUid = 2,
            chapterOffset = 700, updateTime = 100 }
    end
    local jumped4 = nil
    uploader4.on_sync_to_page = function(page)
        jumped4 = page
        state4.page = page
        return true
    end
    uploader4:onReaderReady(BOOK_PATH)
    check("same-chapter cloud lead jumps within the chapter",
        jumped4 == 171) -- 101 + 700/1000 * 100

    -- Cloud behind (chapter 1): no jump, local position is uploaded.
    local uploader5, _, client5 = make_toc_uploader()
    client5.get_progress = function(_, book_id)
        return { bookId = book_id, progress = 10, chapterUid = 1,
            chapterOffset = 0, updateTime = 100 }
    end
    local jumped5 = false
    uploader5.on_sync_to_page = function() jumped5 = true return true end
    uploader5:onReaderReady(BOOK_PATH)
    check("cloud-behind chapter position does not jump", jumped5 == false)
    check("cloud-behind upload keeps the local chapter position",
        client5.calls[#client5.calls]
        and tostring(client5.calls[#client5.calls].chapter_uid) == "2")
end

-- A close upload may already be queued when replay starts. Its in-memory
-- backlog must cross the same boundary or its later rt=0 completion could
-- write the snapshot back into the live bucket.
do
    collectgarbage("collect")
    clock = { t = 100000 }
    local book = make_book()
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.7, percent = 70,
        chapter_uid = 3, chapter_idx = 3, chapter_offset = 100,
        summary = "Test Book",
    }
    book.pending_upload_elapsed = 125
    local settings = make_settings({ ["12345"] = book })
    local client = make_client()
    local queue = {}
    local scheduler = {
        scheduleIn = function(_, delay, fn)
            table.insert(queue, { delay = delay, fn = fn })
        end,
    }
    local function run_next()
        local task = table.remove(queue, 1)
        if task then task.fn() end
    end
    local live = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = scheduler,
        get_fraction = function() return 0.7 end,
        is_online = function() return true end,
        now = now,
        heartbeat_interval = false,
    }
    live:onReaderReady(BOOK_PATH)
    run_next()
    run_next() -- finish the document-open progress-only report
    clock.t = clock.t + 30
    live:onCloseDocument(0.7) -- queues, but does not run, the close report
    local token = ProgressUploader.beginTimeReplay(settings)
    run_next()
    check("queued close becomes progress-only after replay starts",
        client.calls[#client.calls].elapsed_seconds == 0)
    check("queued close cannot recreate the moved live backlog",
        settings.data.books["12345"].pending_upload_elapsed == nil
        and settings.data.books["12345"].pending_replay_elapsed == 155)
    ProgressUploader.endTimeReplay(token, clock.t)
end

----------------------------------------------------------------
-- 10. Manual replay and live reading share one coordinator. The replay owns
--     only the backlog present when it starts; time read while it runs is
--     persisted separately for a later pass, and live progress uses rt=0.
----------------------------------------------------------------
do
    local has_coordinator = type(ProgressUploader.beginTimeReplay) == "function"
        and type(ProgressUploader.endTimeReplay) == "function"
    check("time replay coordinator API exists", has_coordinator)
    if has_coordinator then
        collectgarbage("collect")
        clock = { t = 100000 }
        local book = make_book()
        book.pending_upload_position = {
            book_id = "12345", fraction = 0.7, percent = 70,
            chapter_uid = 3, chapter_idx = 3, chapter_offset = 100,
            summary = "Test Book",
        }
        book.pending_upload_elapsed = 125
        book.pending_upload_started_at = clock.t - 125
        book.pending_upload_updated_at = clock.t
        local settings = make_settings({ ["12345"] = book })
        local live_client = make_client()
        local live_state = { fraction = 0.7, online = true }
        local live = ProgressUploader:new{
            settings = settings,
            client = live_client,
            scheduler = immediate_scheduler,
            get_fraction = function() return live_state.fraction end,
            is_online = function() return live_state.online end,
            now = now,
            heartbeat_interval = false,
        }
        live:onReaderReady(BOOK_PATH)

        local token, ids = ProgressUploader.beginTimeReplay(settings)
        check("manual replay snapshots the existing backlog",
            token ~= nil and ids and ids[1] == "12345"
            and settings.data.books["12345"].pending_replay_elapsed == 125
            and settings.data.books["12345"].pending_upload_elapsed == nil)

        local queue = {}
        local queued_scheduler = {
            scheduleIn = function(_, delay, fn)
                table.insert(queue, { delay = delay, fn = fn })
            end,
        }
        local function run_next()
            local task = table.remove(queue, 1)
            if task then task.fn() end
        end
        local manual_client = make_client()
        local manual = ProgressUploader:new{
            settings = settings,
            client = manual_client,
            scheduler = queued_scheduler,
            is_online = function() return true end,
            now = now,
            heartbeat_interval = false,
            time_bucket = "replay",
            on_finished = function()
                ProgressUploader.endTimeReplay(token, clock.t)
            end,
        }
        check("coordinated manual replay starts",
            manual:retryPending("12345", { include_pending_time = true }))
        run_next() -- first 60-second replay report

        clock.t = clock.t + 30
        live_state.fraction = 0.8
        live:onPageUpdate(0.8)
        tick(live)
        check("live reading sends progress-only while replay is active",
            live_client.calls[#live_client.calls].elapsed_seconds == 0
            and live_client.calls[#live_client.calls].progress == 80)
        check("time read during replay is isolated from its snapshot",
            settings.data.books["12345"].pending_replay_elapsed == 65
            and settings.data.books["12345"].pending_upload_elapsed == 30)

        clock.t = clock.t + 31
        run_next()
        run_next() -- second 60-second replay report
        check("manual replay uses the latest live position",
            manual_client.calls[#manual_client.calls].progress == 80)
        clock.t = clock.t + 61
        run_next()
        run_next() -- final 5-second replay report; callback ends coordination

        local replay_total = 0
        for _, call in ipairs(manual_client.calls) do
            if call.__kind == "read" then
                replay_total = replay_total + (tonumber(call.elapsed_seconds) or 0)
            end
        end
        local after = settings.data.books["12345"]
        check("manual replay reports the original backlog exactly once",
            replay_total == 125 and after.pending_replay_elapsed == nil)
        check("reading accumulated during replay remains queued",
            after.pending_upload_elapsed == 122
            and type(after.pending_upload_position) == "table")
        check("a following replay must wait for the accounting window",
            ProgressUploader.timeReplayStartDelay(clock.t) == 61)

        clock.t = clock.t + 30
        tick(live)
        check("live time waits through the final accounting window",
            live_client.calls[#live_client.calls].elapsed_seconds == 0)
        clock.t = clock.t + 32
        tick(live)
        check("new live time resumes after the replay cooldown",
            live_client.calls[#live_client.calls].elapsed_seconds == 60
            and settings.data.books["12345"].pending_upload_elapsed >= 122)
    end
end

-- A successful network response is followed by durable-state persistence.
-- That bookkeeping runs in the scheduler callback too, so an unexpected
-- storage error must not escape the UI event loop or strand the headless
-- replay worker without firing on_finished.
do
    collectgarbage("collect")
    clock = { t = 200000 }
    local book = make_book()
    book.pclts = "seed"
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.5, percent = 50,
        chapter_uid = 2, chapter_idx = 2, chapter_offset = 0,
        summary = "Test Book",
    }
    book.pending_replay_elapsed = 60
    book.pending_replay_started_at = clock.t - 60
    local settings = make_settings({ ["12345"] = book })
    local original_save_book = settings.save_book
    local save_calls = 0
    settings.save_book = function(self, book_id, value)
        save_calls = save_calls + 1
        if save_calls == 2 then
            error("simulated persistence failure")
        end
        return original_save_book(self, book_id, value)
    end
    local queue = {}
    local scheduler = {
        scheduleIn = function(_, delay, fn)
            table.insert(queue, { delay = delay, fn = fn })
        end,
    }
    local finished = false
    local uploader = ProgressUploader:new{
        settings = settings,
        client = make_client(),
        scheduler = scheduler,
        is_online = function() return true end,
        now = now,
        heartbeat_interval = false,
        time_bucket = "replay",
        on_finished = function() finished = true end,
    }
    check("replay persistence failure schedules an upload task",
        uploader:retryPending("12345", { include_pending_time = true })
        and #queue == 1)
    local task_ok = pcall(queue[1].fn)
    check("replay persistence failure stays inside the scheduler task", task_ok)
    check("replay persistence failure still finishes the worker", finished)
end

-- Cancellation invalidates already scheduled work, keeps the replay bucket,
-- and still notifies the owner so its standby guard can be released.
do
    clock = { t = 210000 }
    local book = make_book()
    book.pclts = "seed"
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.5, percent = 50,
        chapter_uid = 2, chapter_idx = 2, chapter_offset = 0,
        summary = "Test Book",
    }
    book.pending_replay_elapsed = 60
    local settings = make_settings({ ["12345"] = book })
    local queue = {}
    local scheduler = {
        scheduleIn = function(_, delay, fn)
            table.insert(queue, { delay = delay, fn = fn })
        end,
    }
    local cancelled = false
    local uploader = ProgressUploader:new{
        settings = settings,
        client = make_client(),
        scheduler = scheduler,
        is_online = function() return true end,
        now = now,
        heartbeat_interval = false,
        time_bucket = "replay",
        on_finished = function() cancelled = true end,
    }
    uploader:retryPending("12345", { include_pending_time = true })
    check("replay cancellation API exists", type(uploader.cancel) == "function")
    check("replay cancellation releases the worker", uploader:cancel("test_cancel")
        and cancelled and not uploader.uploading)
    check("replay cancellation keeps the durable time bucket",
        settings.data.books["12345"].pending_replay_elapsed == 60)
    local stale_ok = pcall(queue[1].fn)
    check("replay cancellation ignores the stale scheduled task", stale_ok)
end

-- Account isolation is enforced again inside delayed callbacks. Enumerating a
-- queue under account A is not enough: credentials may switch before the
-- scheduled network request runs.
do
    clock = { t = 220000 }
    local book = make_book()
    local settings = make_settings({ ["12345"] = book })
    local client = make_client()
    local queue = {}
    local uploader = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function(_, delay, fn)
                queue[#queue + 1] = { delay = delay, fn = fn }
            end,
        },
        get_fraction = function() return 0.5 end,
        is_online = function() return true end,
        now = now,
        heartbeat_interval = false,
    }
    uploader:onReaderReady(BOOK_PATH)
    queue[1].fn() -- captures/persists under A, then schedules the send
    settings.data.account.user_vid = "other-user"
    queue[2].fn()
    check("account switch before delayed send performs no network request",
        #client.calls == 0)
    check("account switch keeps the queue bound to its original owner",
        settings.data.books["12345"].pending_upload_user_vid == TEST_USER_VID
        and type(settings.data.books["12345"].pending_upload_position) == "table")
end

-- Opening the same local book under B must not rewrite A's durable pending
-- payload while B uploads its own live position.
do
    clock = { t = 230000 }
    local book = make_book()
    book.pending_upload_user_vid = "account-a"
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.7, percent = 70,
        chapter_uid = 3, chapter_idx = 3, chapter_offset = 100,
        summary = "Account A",
    }
    book.pending_upload_elapsed = 45
    local settings = make_settings({ ["12345"] = book })
    settings.auto_owner = false
    settings.data.account.user_vid = "account-b"
    local client = make_client()
    local uploader = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = immediate_scheduler,
        get_fraction = function() return 0.2 end,
        is_online = function() return true end,
        now = now,
        heartbeat_interval = false,
    }
    uploader:onReaderReady(BOOK_PATH)
    local after = settings.data.books["12345"]
    check("foreign pending payload is not overwritten by current reading",
        after.pending_upload_user_vid == "account-a"
        and after.pending_upload_position.percent == 70
        and after.pending_upload_elapsed == 45)
end

-- Legacy queues without an owner are quarantined instead of being claimed by
-- whichever account happens to log in first after the upgrade.
do
    clock = { t = 240000 }
    local book = make_book()
    book.pending_upload_position = {
        book_id = "12345", fraction = 0.6, percent = 60,
        chapter_uid = 2, chapter_idx = 2, chapter_offset = 100,
        summary = "Unknown owner",
    }
    book.pending_upload_elapsed = 30
    local settings = make_settings({ ["12345"] = book })
    settings.auto_owner = false
    local client = make_client()
    local uploader = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = immediate_scheduler,
        is_online = function() return true end,
        now = now,
        heartbeat_interval = false,
    }
    check("unowned durable queue is not resumed",
        uploader:retryPending("12345", { include_pending_time = true }) == false
        and #client.calls == 0)
    check("unowned durable queue remains unchanged",
        book.pending_upload_user_vid == nil
        and book.pending_upload_position.percent == 60
        and book.pending_upload_elapsed == 30)
end

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
