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

local function make_settings(books)
    return {
        data = { books = books },
        cache_dir = "/cache",
        flushes = 0,
        get = function(self, key, default)
            local value = self.data[key]
            if value == nil then return default end
            return value
        end,
        set = function(self, key, value) self.data[key] = value end,
        flush = function(self) self.flushes = self.flushes + 1 end,
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
            return { succ = 1 }
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
--    reported, capped at 60 seconds because larger values are silently
--    ignored even when the endpoint responds with succ=1.
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
    check("one report never exceeds the server's 60s limit",
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
    -- First read report rejected (the enter-read result is ignored by
    -- design), accepted after the ensure_reader_state session refresh.
    local rejected_once = false
    local uploader, _, client = make_uploader{
        responder = function(payload)
            if payload.__kind == "read" and not rejected_once then
                rejected_once = true
                return { errcode = -2012 }
            end
            return { succ = 1 }
        end,
    }
    local before = content_stub.ensure_reader_state_calls
    uploader:onReaderReady(BOOK_PATH)
    check("rejected read triggers reader-state refresh",
        content_stub.ensure_reader_state_calls == before + 1)
    check("refreshed retry is accepted, no scheduled retry needed",
        uploader.uploading == false and uploader.dirty == false)

    -- Hard failure: every read rejected -> RETRY_LIMIT retry chain runs.
    local uploader2, _, client2, state2 = make_uploader{
        responder = function() return { errcode = -1 } end,
    }
    local before2 = content_stub.ensure_reader_state_calls
    uploader2:onReaderReady(BOOK_PATH) -- document_open fails 3 attempts x 2 sends
    check("failed upload retries RETRY_LIMIT+1 times with refresh each",
        #client2.calls == 1 + 3 * 2 -- 1 enter + 3 attempts x 2 read sends
        and content_stub.ensure_reader_state_calls == before2 + 3)
    check("uploading flag cleared after final failure", uploader2.uploading == false)
    check("position stays dirty after failure", uploader2.dirty == true)

    -- Recover: accept again, record a new position, the next heartbeat
    -- uploads and fires on_uploaded.
    local _, _, _, _, uploaded = nil, nil, nil, nil, nil
    client2.responder = function() return { succ = 1 } end
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
        return { succ = 1 }
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
        #client.calls == baseline + 3 and uploader.book_id == nil)
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

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
