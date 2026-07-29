--[[--
Reading-time experiment (writes the real account, minimal scope):
simulates one ~4-minute reading session through the real
ProgressUploader with REAL time passing (sleep between ticks), so
rt/ts spacing matches actual Kindle usage exactly. Logs every
report_read payload (rt/ts/ps/pc/appId) and the server response, then
polls get_read_stats to see how much reading time the server credited.

Run from the KOReader emulator directory (takes ~8 minutes):

    KO_EMU_DIR=$PWD ./luajit plugins/wereaddesktop.koplugin/spec/e2e_read_time.lua <book_id>

Back up settings/weread.lua and the book's cache/*.json first; the
script re-reports the original position at the end but local records
must be restored from the backup.
--]]--

local EMU = os.getenv("KO_EMU_DIR") or "."
local BOOK_ID = assert(arg and arg[1], "usage: e2e_read_time.lua <book_id>")
BOOK_ID = tostring(BOOK_ID)
local TICK_SECONDS = 15
local TICKS = 16 -- 16 x 15s = 240s of "reading"

package.path = "common/?.lua;frontend/?.lua;plugins/wereaddesktop.koplugin/?.lua;"
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

local function dump(value, indent, depth)
    indent = indent or ""
    depth = depth or 0
    if type(value) ~= "table" then
        print(indent .. tostring(value))
        return
    end
    if depth > 4 then
        print(indent .. "...")
        return
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = value[k]
        if type(v) == "table" then
            print(indent .. tostring(k) .. ":")
            dump(v, indent .. "  ", depth + 1)
        else
            print(indent .. tostring(k) .. " = " .. tostring(v))
        end
    end
end

local settings = Settings:new()
local client = Client:new(settings)

-- ---- Baseline stats -------------------------------------------------
print("======== BASELINE weekly ========")
local weekly0 = client:get_read_stats("weekly")
dump(weekly0)
print("======== BASELINE overall ========")
local overall0 = client:get_read_stats("overall")
dump(overall0)

-- ---- Book + original position ----------------------------------------
local book = settings:get("books", {})[BOOK_ID]
assert(type(book) == "table" and book.cached_file, "book not usable")
local orig = {
    progress = tonumber(book.progress) or 0,
    chapter_uid = book.chapter_uid,
    chapter_idx = tonumber(book.chapter_idx) or 0,
    chapter_offset = tonumber(book.chapter_offset) or 0,
}
print(string.format("book %s original: progress=%d ci=%d co=%d uid=%s",
    BOOK_ID, orig.progress, orig.chapter_idx, orig.chapter_offset,
    tostring(orig.chapter_uid)))

-- ---- Log every report_read -------------------------------------------
local reports = {}
local orig_report_read = client.report_read
client.report_read = function(self, payload, referer)
    local result = orig_report_read(self, payload, referer)
    local accepted = WeRead.is_success_response(result)
        or (type(result) == "table" and result.synckey ~= nil)
    local entry = {
        wall = os.time(),
        rt = payload.rt, ts = payload.ts, ct = payload.ct,
        pr = payload.pr, ci = payload.ci, co = payload.co,
        ps = payload.ps, pc = payload.pc, appId = payload.appId,
        accepted = accepted,
        succ = type(result) == "table" and result.succ or nil,
        synckey = type(result) == "table" and result.synckey or nil,
        errcode = type(result) == "table" and (result.errcode or result.errCode) or nil,
    }
    reports[#reports + 1] = entry
    print(string.format(
        "[report %d] rt=%s pr=%s ci=%s co=%s ct=%s ts=%s ps=%s pc=%s appId=%s -> %s (succ=%s synckey=%s errcode=%s)",
        #reports, tostring(entry.rt), tostring(entry.pr), tostring(entry.ci),
        tostring(entry.co), tostring(entry.ct), tostring(entry.ts),
        tostring(entry.ps), tostring(entry.pc), tostring(entry.appId),
        accepted and "ACCEPTED" or "REJECTED",
        tostring(entry.succ), tostring(entry.synckey), tostring(entry.errcode)))
    return result
end

-- ---- Simulated session, real time ------------------------------------
local state = { fraction = orig.progress / 100 }
local uploader = ProgressUploader:new{
    settings = settings,
    client = client,
    scheduler = { scheduleIn = function(_, _delay, fn) fn() end },
    get_fraction = function() return state.fraction end,
    is_online = function() return true end,
}
print("======== SESSION START " .. os.date("%H:%M:%S") .. " ========")
assert(uploader:onReaderReady(book.cached_file) == BOOK_ID, "book not detected")
for i = 1, TICKS do
    os.execute("sleep " .. TICK_SECONDS)
    state.fraction = orig.progress / 100 + i * 0.01
    uploader:onPageUpdate(state.fraction)
    print(string.format("-- tick %d/%d (t+%ds, fraction=%.2f)",
        i, TICKS, i * TICK_SECONDS, state.fraction))
end
os.execute("sleep " .. TICK_SECONDS)
uploader:onCloseDocument(state.fraction)
print("======== SESSION END " .. os.date("%H:%M:%S") .. " ========")

local rt_sum = 0
for _, r in ipairs(reports) do
    if r.accepted and r.rt then rt_sum = rt_sum + r.rt end
end
print("accepted report_read count:", #reports, " sum of accepted rt:", rt_sum, "s")

-- ---- Restore the original position ------------------------------------
local book_now = settings:get("books", {})[BOOK_ID]
local restore = client.report_read -- still wrapped: gets logged
restore(client, WeRead.make_read_payload{
    book_id = BOOK_ID,
    chapter_uid = orig.chapter_uid,
    chapter_idx = orig.chapter_idx,
    chapter_offset = orig.chapter_offset,
    progress = orig.progress,
    summary = book_now.summary or "",
    elapsed_seconds = 1,
    app_id = book_now.app_id or WeRead.web_app_id(),
    psvts = book_now.psvts,
    pclts = book_now.pclts,
    token = book_now.token,
}, book_now.reader_url or WeRead.reader_url(BOOK_ID))
print("original position re-reported (progress=" .. orig.progress .. ")")

-- ---- Poll stats -------------------------------------------------------
for _, wait in ipairs{ 30, 30, 60 } do
    os.execute("sleep " .. wait)
    print("======== STATS weekly (after session, " .. os.date("%H:%M:%S") .. ") ========")
    dump(client:get_read_stats("weekly"))
    print("======== STATS overall ========")
    dump(client:get_read_stats("overall"))
end
print("done")
