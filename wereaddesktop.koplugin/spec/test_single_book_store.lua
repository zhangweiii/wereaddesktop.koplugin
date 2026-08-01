--[[--
Regression test for the single-book Settings API (get_book / save_book /
remove_book): per-book writes must stay scoped to one book, reads must not
scan the whole shelf, and the flush-time index merge must keep entries
written by other contexts (file-manager vs reader instances).

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_single_book_store.lua
--]]--

local TMP = os.getenv("TMPDIR") or "/tmp"
local ROOT = TMP .. "/wereaddesktop_singlebook_" .. tostring(os.time())
    .. "_" .. tostring(math.random(100000))
os.execute("mkdir -p " .. string.format("%q", ROOT))

package.path = package.path .. ";./?.lua"

local disk_state = {}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deepcopy(item)
    end
    return copy
end

package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return ROOT .. "/data" end,
        getSettingsDir = function() return ROOT .. "/settings" end,
    }
end

package.preload["luasettings"] = function()
    local LuaSettings = {}
    function LuaSettings:open(file_path)
        local instance = {
            file = file_path,
            data = deepcopy(disk_state[file_path] or {}),
        }
        function instance:readSetting(key, default)
            if self.data[key] == nil and default ~= nil then
                self.data[key] = deepcopy(default)
            end
            return self.data[key]
        end
        function instance:saveSetting(key, value)
            self.data[key] = deepcopy(value)
        end
        function instance:delSetting(key)
            self.data[key] = nil
        end
        function instance:has(key)
            return self.data[key] ~= nil
        end
        function instance:reset(data)
            self.data = data
        end
        function instance:flush()
            disk_state[self.file] = deepcopy(self.data)
        end
        return instance
    end
    return LuaSettings
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            local file = io.open(path, "rb")
            if file then
                file:close()
                if key == "mode" then return "file" end
                return { mode = "file" }
            end
            local ok = os.execute("test -d " .. string.format("%q", path))
            if (ok == true or ok == 0) and key == "mode" then
                return "directory"
            end
            return nil
        end,
        mkdir = function(path)
            local ok = os.execute("mkdir -p " .. string.format("%q", path))
            return (ok == true or ok == 0) or nil
        end,
    }
end

local book_store_mock
package.preload["weread.lib.book_store"] = function()
    book_store_mock = {
        save_calls = 0,
        load_calls = 0,
    }
    function book_store_mock.save(_settings, book_id, book)
        book_store_mock.save_calls = book_store_mock.save_calls + 1
        return true, { cache_dir = "/cache/" .. tostring(book_id) }
    end
    function book_store_mock.load(_settings, book_id, index)
        book_store_mock.load_calls = book_store_mock.load_calls + 1
        return {
            book_id = tostring(book_id),
            cache_dir = type(index) == "table" and index.cache_dir or nil,
        }
    end
    return book_store_mock
end

local Settings = require("weread.lib.settings")

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local first = Settings:new()
first:save_book("b1", { book_id = "b1", title = "一" })
first:save_book("b2", { book_id = "b2", title = "二" })
first:flush()

check("save_book writes exactly one book file per call",
    book_store_mock.save_calls == 2)

local second = Settings:new()
local loads_before = book_store_mock.load_calls
local b1 = second:get_book("b1")
check("get_book loads exactly one book record",
    b1 ~= nil and b1.book_id == "b1"
        and book_store_mock.load_calls == loads_before + 1)
check("get_book misses return nil", second:get_book("missing") == nil)

-- A third context writes a new book; the second context must pick it up
-- through refresh() instead of its stale in-memory snapshot.
local third = Settings:new()
third:save_book("b3", { book_id = "b3", title = "三" })
third:flush()

local b3 = second:get_book("b3")
check("get_book refreshes the index from disk for unknown books",
    b3 ~= nil and b3.book_id == "b3")

-- Updating one book must not rewrite the others.
local saves_before = book_store_mock.save_calls
first:save_book("b1", { book_id = "b1", title = "一改" })
first:flush()
check("updating one book saves only that book",
    book_store_mock.save_calls == saves_before + 1)

local fresh = Settings:new()
local b2 = fresh:get_book("b2")
check("other books survive a single-book update", b2 ~= nil
    and b2.book_id == "b2")

-- remove_book drops only the named index entry.
check("remove_book returns false for unknown books",
    first:remove_book("missing") == false)
first:remove_book("b1")
first:flush()
local after_remove = Settings:new()
check("remove_book drops the book index only",
    after_remove:get_book("b1") == nil
        and after_remove:get_book("b2") ~= nil)

os.execute("rm -rf " .. string.format("%q", ROOT))

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
