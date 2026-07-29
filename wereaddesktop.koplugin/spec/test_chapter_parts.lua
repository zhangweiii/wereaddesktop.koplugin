--[[--
Unit test for the chapter parts cache in weread.lib.content (the
on-disk cache that lets a "补齐缺失章节" fill-missing run repack an EPUB
without re-downloading already-fetched chapters).

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_chapter_parts.lua
--]]--

local TMP = os.getenv("TMPDIR") or "/tmp"
local ROOT = TMP .. "/wereaddesktop_parts_" .. tostring(os.time())
    .. "_" .. tostring(math.random(100000))
os.execute("mkdir -p " .. string.format("%q", ROOT))

package.path = package.path .. ";./?.lua"

-- content.lua pulls these in; the parts-cache helpers never touch them.
package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end

-- Minimal lfs: attributes (mode) + dir iteration.
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            local f = io.open(path, "rb")
            if f then
                f:close()
                if key == "mode" then return "file" end
                return { mode = "file" }
            end
            local ok = os.execute("test -d " .. string.format("%q", path))
            if (ok == true or ok == 0) and key == "mode" then
                return "directory"
            end
            return nil
        end,
        dir = function(path)
            local pipe = io.popen("ls -1 " .. string.format("%q", path))
            local entries = {}
            if pipe then
                for line in pipe:lines() do
                    table.insert(entries, line)
                end
                pipe:close()
            end
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end
        end,
    }
end

local Content = require("weread.lib.content")

local failures = 0
local function check(label, cond)
    if cond then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local settings = { cache_dir = ROOT }
local book = { book_id = "bk1" }
local chapters = {
    { chapterUid = 1, title = "第一章" },
    { chapterUid = 2, title = "第二章" },
    { chapterUid = 3, title = "第三章" },
}

-- Chapter body roundtrip.
check("save/load chapter part roundtrip",
    Content.save_chapter_part(settings, book, "1", "<p>body-1</p>") == true
    and Content.load_chapter_part(settings, book, "1") == "<p>body-1</p>")
check("missing chapter part loads nil",
    Content.load_chapter_part(settings, book, "2") == nil)

-- Missing-chapter listing: chapters without a cached body.
Content.save_chapter_part(settings, book, "3", "<p>body-3</p>")
local missing = Content.list_missing_chapters(settings, book, chapters)
check("list_missing_chapters finds exactly the uncached chapter",
    #missing == 1 and missing[1].chapterUid == 2)

-- CSS roundtrip.
check("save/load parts css roundtrip",
    Content.save_parts_css(settings, book, "body{color:#000}") == true
    and Content.load_parts_css(settings, book) == "body{color:#000}")

-- Asset roundtrip: the href must survive exactly (flattening it into a
-- filename would mangle underscores), the media type is sniffed.
Content.save_part_asset(settings, book, {
    href = "images/pic_1.png",
    media_type = "image/png",
    data = "\137PNG\r\n\026\nfakepng",
})
Content.save_part_asset(settings, book, {
    href = "images/photo.jpeg",
    media_type = "image/jpeg",
    data = "\255\216\255fakejpg",
})
local assets = Content.load_part_assets(settings, book)
local by_href = {}
for _i, asset in ipairs(assets) do
    by_href[asset.href] = asset
end
check("cached assets come back with exact hrefs", #assets == 2
    and by_href["images/pic_1.png"] ~= nil
    and by_href["images/photo.jpeg"] ~= nil)
check("asset payloads and media types survive",
    by_href["images/pic_1.png"]
    and by_href["images/pic_1.png"].data == "\137PNG\r\n\026\nfakepng"
    and by_href["images/pic_1.png"].media_type == "image/png"
    and by_href["images/photo.jpeg"]
    and by_href["images/photo.jpeg"].media_type == "image/jpeg")

os.execute("rm -rf " .. string.format("%q", ROOT))

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
