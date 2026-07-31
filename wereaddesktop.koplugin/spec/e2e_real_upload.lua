--[[--
Manual end-to-end check: report reading progress to the real WeRead
account through the real settings / client / protocol stack, then
report the original position back so the account is left unchanged.

Run from the KOReader emulator directory (paths are relative to it):

    KO_EMU_DIR=$PWD DRY_RUN=1 ./luajit plugins/wereaddesktop.koplugin/spec/e2e_real_upload.lua <book_id>   # inspect only, no network writes
    KO_EMU_DIR=$PWD ./luajit plugins/wereaddesktop.koplugin/spec/e2e_real_upload.lua <book_id>            # real upload + restore

Back up settings/weread.lua and the book's cache/*.json before the real
run and restore them afterwards (the uploader persists its position).
--]]--

local EMU = os.getenv("KO_EMU_DIR") or "."
local DRY_RUN = os.getenv("DRY_RUN") == "1"

package.path = "common/?.lua;frontend/?.lua;plugins/wereaddesktop.koplugin/?.lua;"
    .. package.path
package.cpath = "common/?.so;" .. package.cpath

-- Same bootstrap as KOReader's setupkoenv.lua: provides ffi.load
-- overrides and the 'loadlib' helper used by ffi/* modules.
require("ffi/loadlib")

-- Point the plugin's settings at the real emulator data directory.
package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return EMU end,
        getSettingsDir = function() return EMU .. "/settings" end,
    }
end
-- socketutil (frontend) wants these two; keep them minimal.
package.preload["device"] = function() return { model = "emu" } end
package.preload["version"] = function()
    return { getShortVersion = function() return "e2e" end }
end

local Settings = require("weread.lib.settings")
local Client = require("weread.lib.client")
local WeRead = require("weread.lib.protocol")
local ProgressUploader = require("progressuploader")

local book_id = assert(arg and arg[1], "usage: e2e_real_upload.lua <book_id>")
book_id = tostring(book_id)

local settings = Settings:new()
local book = settings:get("books", {})[book_id]
assert(type(book) == "table", "book not found in settings: " .. book_id)
assert(type(book.cached_file) == "string" and book.cached_file ~= "",
    "book has no cached_file: " .. book_id)

local orig_percent = tonumber(book.progress) or 0
print("book:", book_id, "-", tostring(book.title))
print("cached_file:", book.cached_file)
print(string.format(
    "original position: progress=%s chapter_idx=%s chapter_offset=%s chapter_uid=%s",
    tostring(book.progress), tostring(book.chapter_idx),
    tostring(book.chapter_offset), tostring(book.chapter_uid)))
print("chapters in record:", type(book.chapters) == "table" and #book.chapters or "none (catalog cache fallback)")

-- The exact original coordinates, captured before anything mutates the
-- record: the restore report must reproduce these verbatim (the
-- full-book word-count mapper cannot hit "offset 159 of chapter 2").
local orig_pos = {
    progress = orig_percent,
    chapter_uid = book.chapter_uid,
    chapter_idx = tonumber(book.chapter_idx) or 0,
    chapter_offset = tonumber(book.chapter_offset) or 0,
}

if DRY_RUN then
    print("DRY_RUN: no network writes")
    return
end

-- The probe position: original +/- 2 percent, kept inside 1..99 so the
-- mapped chapter never jumps to the very start/end.
local new_percent = orig_percent + 2
if new_percent > 99 then new_percent = orig_percent - 2 end
if new_percent < 1 then new_percent = orig_percent + 2 end
-- +0.5 avoids float floor() off-by-one in percent = floor(fraction*100).
local f_orig = (orig_percent + 0.5) / 100
local f_new = (new_percent + 0.5) / 100

local client = Client:new(settings)

-- Observe every real server response.
local reports = {}
local orig_report_read = client.report_read
client.report_read = function(self, payload, referer)
    local result = orig_report_read(self, payload, referer)
    local accepted = type(result) == "table" and result.synckey ~= nil
    table.insert(reports, {
        progress = payload and (payload.progress or payload.pr),
        accepted = accepted,
        result = result,
    })
    print(string.format("report_read progress=%s -> %s (%s)",
        tostring(payload and (payload.progress or payload.pr)),
        accepted and "ACCEPTED" or "REJECTED",
        type(result) == "table" and ("table, synckey=" .. tostring(result.synckey)
            .. " succ=" .. tostring(result.succ)) or tostring(result)))
    return result
end

local clock = { t = os.time() }
local state = { fraction = f_orig }
local immediate = { scheduleIn = function(_, _delay, fn) fn() end }

local uploader = ProgressUploader:new{
    settings = settings,
    client = client,
    scheduler = immediate,
    get_fraction = function() return state.fraction end,
    now = function() return clock.t end,
}

local failures = 0
local function check(label, cond)
    print((cond and "ok   - " or "FAIL - ") .. label)
    if not cond then failures = failures + 1 end
end
local function last_read_accepted()
    for i = #reports, 1, -1 do
        return reports[i].accepted
    end
    return false
end

assert(uploader:onReaderReady(book.cached_file) == book_id,
    "uploader did not detect the book from its cached_file")
check("document_open report accepted (session alive)", last_read_accepted())

if last_read_accepted() then
    -- Move +2 percent: the actual progress change under test.
    clock.t = clock.t + 61
    state.fraction = f_new
    uploader:onPageUpdate(f_new)
    check("page_update report with new progress accepted",
        last_read_accepted() and reports[#reports].progress == new_percent)

    -- Restore: report the exact original coordinates back (a second
    -- uploader pass would map percent 9 onto different chapter
    -- coordinates, so this goes through client:report_read directly,
    -- the same endpoint the plugin uses).
    local book_now = settings:get("books", {})[book_id]
    local restore_payload = WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = orig_pos.chapter_uid or book_now.chapter_uid,
        chapter_idx = orig_pos.chapter_idx,
        chapter_offset = orig_pos.chapter_offset,
        progress = orig_pos.progress,
        summary = book_now.summary or "",
        elapsed_seconds = 1,
        app_id = book_now.app_id or WeRead.web_app_id(),
        psvts = book_now.psvts,
        pclts = book_now.pclts,
        token = book_now.token,
    }
    client:report_read(restore_payload,
        book_now.reader_url or WeRead.reader_url(book_id))
    check("original position reported back and accepted",
        last_read_accepted()
        and reports[#reports].progress == orig_pos.progress)

    uploader:onCloseDocument(f_orig)
else
    print("session expired or network down: skipping progress change, nothing was modified")
end

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("e2e checks passed")
