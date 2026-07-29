--[[--
READ-ONLY end-to-end check of the cloud-pull (download) direction:
fetches the real cloud reading progress from both endpoints
(gateway /book/getprogress and web /web/book/getProgress), runs the
real normalize_remote / choose_remote / remote_to_local pipeline and
compares the resulting whole-book fraction with the locally stored
progress — without any report_read or local writes.

Run from the KOReader emulator directory:

    KO_EMU_DIR=$PWD ./luajit plugins/wereaddesktop.koplugin/spec/e2e_cloud_pull.lua <book_id> [book_id...]
--]]--

local EMU = os.getenv("KO_EMU_DIR") or "."

package.path = "common/?.lua;frontend/?.lua;plugins/wereaddesktop.koplugin/?.lua;"
    .. package.path
package.cpath = "common/?.so;" .. package.cpath

-- Same bootstrap as KOReader's setupkoenv.lua.
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
local Content = require("weread.lib.content")
local PositionMapper = require("weread.lib.position_mapper")

local SYNC_AHEAD_THRESHOLD = 0.005 -- mirror of progressuploader.lua

local function brief(value, depth)
    depth = depth or 0
    if type(value) ~= "table" or depth > 2 then
        return tostring(value)
    end
    local parts = {}
    for k, v in pairs(value) do
        if type(v) ~= "table" then
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    table.sort(parts)
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local settings = Settings:new()
local client = Client:new(settings)

local book_ids = { ... }
assert(#book_ids > 0, "usage: e2e_cloud_pull.lua <book_id> [book_id...]")

for _, book_id in ipairs(book_ids) do
    book_id = tostring(book_id)
    print(string.rep("=", 70))
    local book = settings:get("books", {})[book_id]
    if type(book) ~= "table" then
        print("book " .. book_id .. ": not in settings, skipped")
    else
        print("book:", book_id, "-", tostring(book.title))
        print(string.format("local record: progress=%s chapter_idx=%s chapter_offset=%s chapter_uid=%s",
            tostring(book.progress), tostring(book.chapter_idx),
            tostring(book.chapter_offset), tostring(book.chapter_uid)))

        local chapters = book.chapters
        if type(chapters) ~= "table" or #chapters == 0 then
            chapters = Content.load_catalog_cache(client, settings, book)
        end
        print("chapters:", type(chapters) == "table" and #chapters or "NONE")

        -- 1. Gateway endpoint.
        local gw_ok, gw_raw = pcall(client.get_progress, client, book_id)
        print("gateway get_progress ok:", gw_ok)
        if gw_ok and gw_raw ~= nil then
            print("  raw:", brief(gw_raw, 1))
            local b = gw_raw.book or gw_raw
            print(string.format("  progress=%s chapterUid=%s chapterOffset=%s updateTime=%s",
                tostring(b.progress), tostring(b.chapterUid),
                tostring(b.chapterOffset), tostring(b.updateTime or b.timestamp)))
        elseif not gw_ok then
            print("  error:", tostring(gw_raw))
        end

        -- 2. Web endpoint.
        local web_ok, web_raw = pcall(client.get_web_progress, client, book_id)
        print("web get_web_progress ok:", web_ok)
        if web_ok and web_raw ~= nil then
            print("  raw:", brief(web_raw, 1))
            print(string.format("  progress=%s chapterUid=%s chapterOffset=%s updateTime=%s",
                tostring(web_raw.progress), tostring(web_raw.chapterUid),
                tostring(web_raw.chapterOffset), tostring(web_raw.updateTime)))
        elseif not web_ok then
            print("  error:", tostring(web_raw))
        end

        -- 3. Normalize + merge + map, exactly like _fetchRemote +
        --    _pullFromCloud do.
        if type(chapters) == "table" and #chapters > 0 then
            local norm_gw = (gw_ok and gw_raw ~= nil)
                and PositionMapper.normalize_remote(gw_raw, book_id, "gateway", chapters)
                or nil
            local norm_web = (web_ok and web_raw ~= nil)
                and PositionMapper.normalize_remote(web_raw, book_id, "web", chapters)
                or nil
            print("normalized gateway:", brief(norm_gw))
            print("normalized web:   ", brief(norm_web))
            local remote = PositionMapper.choose_remote(norm_web, norm_gw)
            print("chosen remote:    ", brief(remote))
            if remote then
                local target = PositionMapper.remote_to_local(chapters, remote, {
                    is_full_book = true,
                })
                local local_fraction = (tonumber(book.progress) or 0) / 100
                if target and target.fraction then
                    local delta = target.fraction - local_fraction
                    print(string.format(
                        "cloud fraction=%.4f (%.1f%%)  local fraction=%.4f (%d%%)  delta=%+.4f",
                        target.fraction, target.fraction * 100,
                        local_fraction, tonumber(book.progress) or 0, delta))
                    -- 4. The _pullFromCloud decision with the local
                    --    fraction taken from the stored record.
                    if delta >= SYNC_AHEAD_THRESHOLD then
                        print(string.format(
                            "VERDICT: WOULD JUMP to %.4f (cloud ahead by %.2f%%)",
                            target.fraction, delta * 100))
                    else
                        print("VERDICT: no jump (cloud not ahead by >= 0.5%)")
                    end
                else
                    print("remote_to_local failed:", brief(target))
                end
            else
                print("no usable remote position (both endpoints empty)")
            end
        end
    end
end
print(string.rep("=", 70))
print("read-only check done (no report_read, no local writes)")
