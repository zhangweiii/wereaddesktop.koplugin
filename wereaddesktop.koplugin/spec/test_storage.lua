-- Unit test for the local cache accounting/removal module.

local TMP = os.getenv("TMPDIR") or "/tmp"
local ROOT = TMP .. "/wereaddesktop_storage_" .. tostring(os.time())
os.execute("mkdir -p " .. string.format("%q", ROOT))
package.path = package.path .. ";./?.lua"

package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function()
    local lfs = {}
    function lfs.attributes(path, key)
        local is_dir = os.execute("test -d " .. string.format("%q", path))
        if is_dir == true or is_dir == 0 then
            if key == "mode" then return "directory" end
            return { mode = "directory" }
        end
        local file = io.open(path, "rb")
        if file then
            local size = file:seek("end") or 0
            file:close()
            if key == "mode" then return "file" end
            if key == "size" then return size end
            return { mode = "file", size = size }
        end
        return nil
    end
    function lfs.dir(path)
        local pipe = io.popen("ls -1 " .. string.format("%q", path))
        local entries = {}
        if pipe then
            for line in pipe:lines() do entries[#entries + 1] = line end
            pipe:close()
        end
        local index = 0
        return function()
            index = index + 1
            return entries[index]
        end
    end
    function lfs.rmdir(path)
        local ok = os.execute("rmdir " .. string.format("%q", path))
        return ok == true or ok == 0
    end
    function lfs.mkdir(path)
        local ok = os.execute("mkdir -p " .. string.format("%q", path))
        return ok == true or ok == 0
    end
    return lfs
end

local Content = require("weread.lib.content")
local Storage = require("weread.lib.storage")

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local settings = { cache_dir = ROOT }
local book = { book_id = "book-1", title = "测试书" }
Content.save_chapter_part(settings, book, "1", "<p>chapter</p>")
Content.save_parts_css(settings, book, "body{}")

local summary = Storage.summary(settings, { [book.book_id] = book })
check("summary counts one local book", summary.book_count == 1)
check("summary counts cached bytes", summary.bytes > 0)
check("format bytes is human readable",
    Storage.format_bytes(summary.bytes):match("[KMG]?B$") ~= nil)

local unsafe_id = "book-unsafe"
local unsafe_root = ROOT .. "_outside"
local unsafe_dir = unsafe_root .. "/" .. unsafe_id
os.execute("mkdir -p " .. string.format("%q", unsafe_dir))
local unsafe_file = io.open(unsafe_dir .. "/keep.txt", "wb")
unsafe_file:write("keep")
unsafe_file:close()
local unsafe_ok, unsafe_err = Storage.remove_book(settings, unsafe_id, {
    book_id = unsafe_id,
    cache_dir = unsafe_dir,
})
check("book-like directory outside cache root is rejected",
    unsafe_ok == false and unsafe_err == "unsafe_book_cache_path")
local retained = io.open(unsafe_dir .. "/keep.txt", "rb")
check("unsafe cache rejection leaves outside data untouched", retained ~= nil)
if retained then retained:close() end

local ok, err = Storage.remove_book(settings, book.book_id, book)
check("dedicated book cache can be removed", ok == true and err == nil)
check("removed cache is no longer counted",
    Storage.summary(settings, { [book.book_id] = book }).book_count == 0)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
os.execute("rm -rf " .. string.format("%q", ROOT))
os.execute("rm -rf " .. string.format("%q", unsafe_root))
print("all checks passed")
