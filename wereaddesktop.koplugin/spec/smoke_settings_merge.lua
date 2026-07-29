--[[--
Smoke test: two weread.lib.settings instances sharing one settings file
(like the FM- and reader-context instances in KOReader) must not roll
each other's committed writes back when they flush.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/smoke_settings_merge.lua
--]]--

-- Stubs for the KOReader runtime modules that settings.lua and its
-- transitive requires pull in. luasettings/dump/cookie are the real
-- KOReader/bundled modules.
local TMP = os.getenv("TMPDIR") or "/tmp"
local ROOT = TMP .. "/wereaddesktop_smoke_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000))
os.execute("mkdir -p " .. string.format("%q", ROOT .. "/settings"))

-- Real KOReader modules (luasettings/dump/cookie) come from a KOReader
-- checkout; point KOREADER_DIR at its root:
--     KOREADER_DIR=~/koreader luajit spec/smoke_settings_merge.lua
local KOREADER_DIR = os.getenv("KOREADER_DIR")
package.path = package.path .. ";./?.lua"
if KOREADER_DIR then
    package.path = package.path .. ";" .. KOREADER_DIR .. "/frontend/?.lua"
end

package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return ROOT end,
        getSettingsDir = function() return ROOT .. "/settings" end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            local f = io.open(path, "rb")
            if f then
                f:close()
                if key == "mode" then return "file" end
                if key == "modification" then return os.time() end
                return { mode = "file", modification = os.time() }
            end
            local ok = os.execute("test -d " .. string.format("%q", path))
            local is_dir = ok == true or ok == 0
            if is_dir then
                if key == "mode" then return "directory" end
                if key == "modification" then return os.time() end
                return { mode = "directory", modification = os.time() }
            end
            return nil
        end,
        mkdir = function(path)
            os.execute("mkdir -p " .. string.format("%q", path))
        end,
    }
end

package.preload["ffi/util"] = function()
    return {
        orderedPairs = function(t) return pairs(t) end,
    }
end

package.preload["logger"] = function()
    local noop = function() end
    return { warn = noop, info = noop, err = noop, dbg = noop }
end

package.preload["util"] = function()
    return {
        -- Mirror KOReader's util.writeToFile: with lua_dofile_ready the
        -- payload is wrapped so the file can be read back with dofile.
        writeToFile = function(data, path, _force_flush, lua_dofile_ready)
            if lua_dofile_ready then
                data = "-- " .. path .. "\nreturn " .. data .. "\n"
            end
            local f = io.open(path, "wb")
            if not f then return nil, "open failed" end
            f:write(data)
            f:close()
            return true
        end,
    }
end

-- book_store wants a JSON module; a Lua round-trip is enough here since
-- both writer and reader use the same stub.
local function lua_encode(value, out)
    out = out or {}
    local t = type(value)
    if t == "table" then
        out[#out + 1] = "{"
        for k, v in pairs(value) do
            out[#out + 1] = "["
            lua_encode(k, out)
            out[#out + 1] = "]="
            lua_encode(v, out)
            out[#out + 1] = ","
        end
        out[#out + 1] = "}"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", value)
    elseif t == "number" or t == "boolean" then
        out[#out + 1] = tostring(value)
    else
        out[#out + 1] = "nil"
    end
    return table.concat(out)
end
package.preload["json"] = function()
    return {
        encode = function(v) return lua_encode(v) end,
        decode = function(s)
            local fn = loadstring("return " .. s)
            if not fn then error("decode failed") end
            return fn()
        end,
    }
end

local Settings = require("weread.lib.settings")

local failures = 0
local function check(label, cond)
    if cond then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local function disk_settings()
    local fn = loadfile(ROOT .. "/settings/weread.lua")
    return fn and fn() or {}
end

-- Two live instances over one file; A = "FM context", B = "reader".
local A = Settings:new()
local B = Settings:new()

-- 1. A writes the shelf cache, then B (holding a stale in-memory view)
--    writes an unrelated key and flushes: A's shelf must survive.
A:set("wereaddesktop_shelf", { { book_id = "1", progress = 0.1 } })
A:flush()
B:set("account", { name = "reader-user" })
B:flush()
local disk = disk_settings()
check("A's key survives B's flush",
    type(disk.wereaddesktop_shelf) == "table"
    and disk.wereaddesktop_shelf[1].book_id == "1")
check("B's key is written",
    type(disk.account) == "table" and disk.account.name == "reader-user")

-- 2. Same in the other direction: B writes, stale A flushes afterwards.
B:set("reader_marker", "from-reader")
B:flush()
A:set("fm_marker", "from-fm")
A:flush()
disk = disk_settings()
check("B's key survives A's later flush", disk.reader_marker == "from-reader")
check("A's key is written", disk.fm_marker == "from-fm")

-- 3. Books index merges per book_id: A "downloads" book1, B (stale)
--    persists progress on book2; both index entries must survive.
A:set("books", { book1 = { title = "Book One", cached_file = ROOT .. "/cache/book1/book1.epub" } })
A:flush()
local b_books = B:get("books", {}) -- reader's (pre-A-download) view
b_books.book2 = { title = "Book Two", cached_file = ROOT .. "/cache/book2/book2.epub", progress = 42 }
B:set("books", b_books)
B:flush()
disk = disk_settings()
check("book1 index entry survives B's books flush",
    type(disk.books) == "table" and type(disk.books.book1) == "table")
check("book2 index entry is written",
    type(disk.books) == "table" and type(disk.books.book2) == "table")
local C = Settings:new()
check("book1 data loads through BookStore",
    C:get("books", {}).book1.title == "Book One")
check("book2 progress persists through BookStore",
    C:get("books", {}).book2.progress == 42)

-- 4. Deletion propagates: A removes its marker; B's keys stay.
A:set("fm_marker", nil)
A:flush()
disk = disk_settings()
check("deleted key is gone", disk.fm_marker == nil)
check("other keys survive deletion flush", disk.reader_marker == "from-reader")

-- 5. refresh() pulls another instance's committed value into memory.
B:set("wereaddesktop_shelf", { { book_id = "1", progress = 0.8 } })
B:flush()
A:refresh("wereaddesktop_shelf")
check("refresh picks up cross-instance write",
    A:get("wereaddesktop_shelf")[1].progress == 0.8)
-- ... but never overwrites an unflushed local change.
A:set("wereaddesktop_shelf", { { book_id = "1", progress = 0.5 } })
A:refresh("wereaddesktop_shelf")
check("refresh skips locally dirty key",
    A:get("wereaddesktop_shelf")[1].progress == 0.5)
A:flush()
disk = disk_settings()
check("dirty key flushed after refresh skip",
    disk.wereaddesktop_shelf[1].progress == 0.5)

os.remove(ROOT .. "/settings/weread.lua")
os.execute("rm -rf " .. string.format("%q", ROOT))

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
