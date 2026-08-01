--[[--
Regression test for Content.ensure_dir_tree and the atomic EPUB writer:
directories are created without a shell, EPUBs are staged as .tmp and only
renamed over the previous file after every libarchive write succeeded, and
a failed write must neither leave a .tmp behind nor destroy an existing
EPUB.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_epub_write.lua
--]]--

local TMP = os.getenv("TMPDIR") or "/tmp"
local ROOT = TMP .. "/wereaddesktop_epub_" .. tostring(os.time())
    .. "_" .. tostring(math.random(100000))
os.execute("mkdir -p " .. string.format("%q", ROOT))

package.path = package.path .. ";./?.lua"

package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id)
            return "https://weread.qq.com/web/reader/" .. tostring(book_id)
        end,
    }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
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
        end,
        mkdir = function(path)
            local ok = os.execute("mkdir -p " .. string.format("%q", path))
            return (ok == true or ok == 0) or nil
        end,
        dir = function(path)
            local pipe = io.popen("ls -1 " .. string.format("%q", path))
            local entries = {}
            if pipe then
                for line in pipe:lines() do
                    entries[#entries + 1] = line
                end
                pipe:close()
            end
            local index = 0
            return function()
                index = index + 1
                return entries[index]
            end
        end,
    }
end

local writer_state = {
    fail_open = false,
    fail_at = nil,
    fail_close = false,
}
package.preload["ffi/archiver"] = function()
    return {
        Writer = {
            new = function()
                return {
                    open = function(self, path)
                        self.opened_path = path
                        if writer_state.fail_open then
                            self.err = "open boom"
                            return nil
                        end
                        local file = assert(io.open(path, "wb"))
                        file:close()
                        return true
                    end,
                    setZipCompression = function()
                    end,
                    addFileFromMemory = function(self, name, data)
                        self.added = self.added or {}
                        table.insert(self.added, name)
                        if writer_state.fail_at == name then
                            self.err = "write boom: " .. name
                            return nil
                        end
                        local file = assert(io.open(self.opened_path, "ab"))
                        assert(file:write(data))
                        file:close()
                        return true
                    end,
                    close = function(self)
                        self.closed = true
                        if writer_state.fail_close then
                            self.err = "close boom"
                        end
                    end,
                }
            end,
        },
    }
end

local Content = require("weread.lib.content")

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function dir_exists(path)
    local ok = os.execute("test -d " .. string.format("%q", path))
    return ok == true or ok == 0
end

----------------------------------------------------------------
-- ensure_dir_tree: recursive creation without a shell.
----------------------------------------------------------------
local deep = ROOT .. "/a/b/c"
check("ensure_dir_tree creates nested directories",
    Content.ensure_dir_tree(deep) == true and dir_exists(deep))
check("ensure_dir_tree is idempotent",
    Content.ensure_dir_tree(deep) == true)

local blocking = ROOT .. "/fileblock"
local bf = assert(io.open(blocking, "wb"))
bf:close()
local blocked_ok, blocked_err = Content.ensure_dir_tree(blocking .. "/x")
check("ensure_dir_tree rejects paths through a file",
    blocked_ok == nil and tostring(blocked_err):find("not a directory")
        ~= nil)

----------------------------------------------------------------
-- save_chapter_epub: staged .tmp + atomic rename.
----------------------------------------------------------------
local settings = { cache_dir = ROOT .. "/cache" }
local book = { book_id = "b1", title = "测试书" }
local chapter = { chapterUid = "c1", title = "第一章" }
local xhtml = "<p>hello</p>"

local path = Content.save_chapter_epub(
    settings, book, chapter, xhtml, {}, nil)
check("epub is written to the final path", file_exists(path))
check("no .tmp staging file remains", not file_exists(path .. ".tmp"))
local final_file = io.open(path, "rb")
local final_data = final_file and final_file:read("*a") or ""
if final_file then final_file:close() end
check("epub contains the chapter body",
    final_data:find("<p>hello</p>", 1, true) ~= nil)

----------------------------------------------------------------
-- A failed write must not destroy an existing EPUB.
----------------------------------------------------------------
local old_file = assert(io.open(path, "wb"))
old_file:write("previous-good-epub")
old_file:close()

writer_state.fail_at = "OEBPS/text/chapter.xhtml"
local call_ok, err = pcall(Content.save_chapter_epub,
    settings, book, chapter, xhtml, {}, nil)
writer_state.fail_at = nil

check("failed write raises an error", not call_ok)
local kept_file = io.open(path, "rb")
local kept_data = kept_file and kept_file:read("*a") or ""
if kept_file then kept_file:close() end
check("failed write leaves the previous EPUB intact",
    file_exists(path) and kept_data == "previous-good-epub")
check("failed write cleans up the .tmp staging file",
    not file_exists(path .. ".tmp"))

----------------------------------------------------------------
-- A close failure must not promote a non-empty staged archive.
----------------------------------------------------------------
writer_state.fail_close = true
local close_ok, close_err = pcall(Content.save_chapter_epub,
    settings, book, chapter, xhtml, {}, nil)
writer_state.fail_close = false
check("archive close failure raises an error",
    not close_ok and tostring(close_err):find("close boom", 1, true) ~= nil)
local close_file = io.open(path, "rb")
local close_data = close_file and close_file:read("*a") or ""
if close_file then close_file:close() end
check("archive close failure leaves the previous EPUB intact",
    close_data == "previous-good-epub")
check("archive close failure cleans up the .tmp staging file",
    not file_exists(path .. ".tmp"))

----------------------------------------------------------------
-- A failed archive open produces no file at all.
----------------------------------------------------------------
writer_state.fail_open = true
local open_ok, open_err = pcall(Content.save_chapter_epub,
    settings, book, chapter, xhtml, {}, nil)
writer_state.fail_open = false
check("archive open failure raises an error", not open_ok)

os.execute("rm -rf " .. string.format("%q", ROOT))

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
