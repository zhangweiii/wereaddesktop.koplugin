--[[--
Real-account offline reading-time check.

The browser reader must be closed before this runs. The script records the
weekly/overall totals, waits offline for DURATION_SECONDS, persists the queue,
starts the same explicit paced replay used by Settings, and polls the totals
until the credited delta covers the queued reading time. It restores the exact
server position and the local sync fields before exiting.

Run from the KOReader emulator directory:

    KO_EMU_DIR=$PWD \
    PLUGIN_DIR=/absolute/path/to/wereaddesktop.koplugin \
    DURATION_SECONDS=90 \
    ./luajit /absolute/path/to/e2e_offline_read_time.lua <book_id>
--]]--

local EMU = os.getenv("KO_EMU_DIR") or "."
local PLUGIN_DIR = os.getenv("PLUGIN_DIR") or "plugins/wereaddesktop.koplugin"
local BOOK_ID = tostring(assert(arg and arg[1],
    "usage: e2e_offline_read_time.lua <book_id>"))
local DURATION_SECONDS = math.max(61,
    math.floor(tonumber(os.getenv("DURATION_SECONDS")) or 90))

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;"
    .. package.path
package.cpath = "common/?.so;" .. package.cpath
require("ffi/loadlib")

package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return EMU end,
        getSettingsDir = function() return EMU .. "/settings" end,
    }
end
package.preload["device"] = function() return { model = "emu" } end
package.preload["version"] = function()
    return { getShortVersion = function() return "e2e" end }
end

local Settings = require("weread.lib.settings")
local Client = require("weread.lib.client")
local WeRead = require("weread.lib.protocol")
local ProgressUploader = require("progressuploader")
local socket = require("socket")

local function deepcopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[deepcopy(key, seen)] = deepcopy(item, seen)
    end
    return copy
end

local settings = Settings:new()
local client = Client:new(settings)
local books = settings:get("books", {})
local book = books[BOOK_ID]
assert(type(book) == "table" and type(book.cached_file) == "string",
    "book not usable: " .. BOOK_ID)
assert(book.pending_upload_position == nil,
    "book already has pending progress; refusing to mix test data")

local original_position = {
    progress = tonumber(book.progress) or 0,
    chapter_uid = book.chapter_uid,
    chapter_idx = tonumber(book.chapter_idx) or 0,
    chapter_offset = tonumber(book.chapter_offset) or 0,
    summary = book.summary or "",
}
local sync_fields = {
    "progress", "chapter_uid", "chapter_idx", "chapter_offset", "summary",
    "last_upload_at", "pending_upload_position", "pending_upload_reason",
    "pending_upload_elapsed", "pending_upload_started_at",
    "pending_replay_elapsed", "pending_replay_started_at",
    "pending_upload_updated_at",
}
local original_fields = {}
for _, key in ipairs(sync_fields) do
    original_fields[key] = {
        present = book[key] ~= nil,
        value = deepcopy(book[key]),
    }
end

local function read_totals()
    local weekly = client:get_read_stats("weekly")
    local overall = client:get_read_stats("overall")
    assert(type(weekly) == "table" and tonumber(weekly.totalReadTime),
        "weekly stats unavailable")
    assert(type(overall) == "table" and tonumber(overall.totalReadTime),
        "overall stats unavailable")
    return tonumber(weekly.totalReadTime), tonumber(overall.totalReadTime)
end

local function restore_local_fields()
    local current_books = settings:get("books", {})
    local current = current_books[BOOK_ID]
    if type(current) ~= "table" then return false end
    for _, key in ipairs(sync_fields) do
        local saved = original_fields[key]
        current[key] = saved.present and deepcopy(saved.value) or nil
    end
    settings:set("books", current_books)
    settings:flush()
    return true
end

local baseline_weekly, baseline_overall = read_totals()
print(string.format("BASELINE weekly=%d overall=%d duration=%d",
    baseline_weekly, baseline_overall, DURATION_SECONDS))

local reports = {}
local raw_report_read = client.report_read
client.report_read = function(self, payload, referer)
    local response = raw_report_read(self, payload, referer)
    if payload and payload.rt ~= nil then
        reports[#reports + 1] = {
            rt = tonumber(payload.rt),
            ct = tonumber(payload.ct),
            accepted = type(response) == "table"
                and response.synckey ~= nil,
            response = response,
        }
        print(string.format("REPORT rt=%s ct=%s accepted=%s synckey=%s",
            tostring(payload.rt), tostring(payload.ct),
            tostring(reports[#reports].accepted),
            tostring(type(response) == "table" and response.synckey)))
    end
    return response
end

local online = false
local fraction = (original_position.progress + 0.5) / 100
-- Respect replay delays: the server acknowledges back-to-back chunks but only
-- credits one accounting window, so an immediate scheduler gives a false pass.
local real_scheduler = {
    scheduleIn = function(_, delay, fn)
        socket.sleep(math.max(0, tonumber(delay) or 0))
        fn()
    end,
}
local sent_accepted = false
local queued_elapsed
local test_error
local replay_token

local ok, err = xpcall(function()
    local offline = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = real_scheduler,
        get_fraction = function() return fraction end,
        is_online = function() return online end,
        heartbeat_interval = false,
    }
    assert(offline:onReaderReady(book.cached_file) == BOOK_ID,
        "offline session did not detect the book")

    for elapsed = 30, DURATION_SECONDS, 30 do
        socket.sleep(math.min(30, DURATION_SECONDS - elapsed + 30))
        print(string.format("OFFLINE elapsed=%d/%d",
            math.min(elapsed, DURATION_SECONDS), DURATION_SECONDS))
    end
    local remainder = DURATION_SECONDS % 30
    if remainder > 0 then
        socket.sleep(remainder)
        print(string.format("OFFLINE elapsed=%d/%d",
            DURATION_SECONDS, DURATION_SECONDS))
    end

    offline:onPageUpdate(fraction)
    offline:onCloseDocument(fraction)
    local queued_book = settings:get("books", {})[BOOK_ID]
    queued_elapsed = math.floor(tonumber(queued_book.pending_upload_elapsed) or 0)
    print("QUEUED elapsed=" .. tostring(queued_elapsed))
    assert(queued_elapsed >= DURATION_SECONDS - 2,
        "offline elapsed time was not persisted")

    online = true
    local replay_ids
    replay_token, replay_ids = ProgressUploader.beginTimeReplay(settings)
    assert(replay_token and replay_ids and replay_ids[1] == BOOK_ID,
        "manual replay coordinator did not snapshot the queued time")
    local reconnect = ProgressUploader:new{
        settings = settings,
        client = client,
        scheduler = real_scheduler,
        is_online = function() return online end,
        heartbeat_interval = false,
        time_bucket = "replay",
        on_finished = function()
            ProgressUploader.endTimeReplay(replay_token, os.time())
        end,
    }
    assert(reconnect:retryPending(BOOK_ID,
        { include_pending_time = true }), "pending retry did not start")
    local accepted_sum = 0
    local accepted_count = 0
    for _, report in ipairs(reports) do
        if report.accepted then
            accepted_sum = accepted_sum + (report.rt or 0)
            accepted_count = accepted_count + 1
            assert((report.rt or 0) <= 60,
                "reconnect sent rt above the server accounting limit")
        end
    end
    assert(accepted_count > 0, "reconnect report was not accepted")
    assert(accepted_sum == queued_elapsed,
        "reconnect did not drain the complete queued rt")
    sent_accepted = true
end, debug.traceback)
if not ok then test_error = err end
if replay_token and ProgressUploader.isTimeReplayActive() then
    ProgressUploader.endTimeReplay(replay_token, os.time())
end

local credited = false
local after_weekly, after_overall = baseline_weekly, baseline_overall
if sent_accepted then
    for _, wait_seconds in ipairs({ 0, 15, 15, 30, 60 }) do
        if wait_seconds > 0 then socket.sleep(wait_seconds) end
        local stats_ok, weekly, overall = pcall(read_totals)
        if stats_ok then
            after_weekly, after_overall = weekly, overall
            local weekly_delta = after_weekly - baseline_weekly
            local overall_delta = after_overall - baseline_overall
            print(string.format(
                "STATS weekly=%d delta=%d overall=%d delta=%d",
                after_weekly, weekly_delta, after_overall, overall_delta))
            if weekly_delta >= queued_elapsed then
                credited = true
                break
            end
        else
            print("STATS retry error=" .. tostring(weekly))
        end
    end
end

local restore_ok, restore_err = pcall(function()
    if sent_accepted then
        local current = settings:get("books", {})[BOOK_ID]
        local response = raw_report_read(client, WeRead.make_read_payload{
            book_id = BOOK_ID,
            chapter_uid = original_position.chapter_uid,
            chapter_idx = original_position.chapter_idx,
            chapter_offset = original_position.chapter_offset,
            progress = original_position.progress,
            summary = original_position.summary,
            elapsed_seconds = 0,
            app_id = current.app_id or WeRead.web_app_id(),
            psvts = current.psvts,
            pclts = current.pclts,
            token = current.token,
        }, current.reader_url or WeRead.reader_url(BOOK_ID))
        assert(type(response) == "table" and response.synckey ~= nil,
            "original server position restore was not accepted")
        print("RESTORE server_position=accepted")
    end
    assert(restore_local_fields(), "local sync fields restore failed")
    print("RESTORE local_fields=ok")
end)

if test_error then print("FAIL " .. tostring(test_error)) end
if not credited then
    print(string.format("FAIL reading time not credited: expected>=%s actual=%s",
        tostring(queued_elapsed), tostring(after_weekly - baseline_weekly)))
end
if not restore_ok then print("FAIL restore: " .. tostring(restore_err)) end
if test_error or not credited or not restore_ok then os.exit(1) end

print(string.format("PASS offline rt=%d credited_delta=%d",
    queued_elapsed, after_weekly - baseline_weekly))
