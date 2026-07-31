-- Local WeRead cache accounting and cleanup.
--
-- Book content is stored per book (EPUB, chapter parts, catalog and the
-- SQLite thought cache). Keeping filesystem knowledge here gives the UI and
-- download pipeline one small seam for size reporting and safe removal.

local lfs = require("libs/libkoreader-lfs")
local Content = require("weread.lib.content")

local Storage = {}

local function path_mode(path)
    local attributes = lfs.symlinkattributes or lfs.attributes
    return attributes(path, "mode")
end

local function scan(path, result)
    result = result or { bytes = 0, files = 0 }
    local mode = path_mode(path)
    if mode == "file" then
        result.bytes = result.bytes + (tonumber(lfs.attributes(path, "size")) or 0)
        result.files = result.files + 1
        return result
    end
    if mode ~= "directory" then
        return result
    end
    local ok, err = pcall(function()
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                scan(path .. "/" .. name, result)
            end
        end
    end)
    if not ok then
        result.error = tostring(err)
    end
    return result
end

local function remove_tree(path)
    local mode = path_mode(path)
    if mode == nil then
        return true
    end
    if mode ~= "directory" then
        local ok, err = os.remove(path)
        return ok == true, err
    end
    local ok, err = pcall(function()
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local child_ok, child_err = remove_tree(path .. "/" .. name)
                if not child_ok then
                    error(child_err or "remove_child_failed")
                end
            end
        end
        local removed, remove_err = lfs.rmdir(path)
        if not removed then
            error(remove_err or "remove_directory_failed")
        end
    end)
    if not ok then
        return false, err
    end
    return true
end

local function is_book_dir(settings, book_id, dir)
    if type(dir) ~= "string" or dir == "" then
        return false
    end
    local root = type(settings) == "table" and settings.cache_dir or nil
    if type(root) ~= "string" or root == "" then
        return false
    end
    root = root:gsub("/+$", "")
    dir = dir:gsub("/+$", "")
    local padded = "/" .. dir .. "/"
    if root == "" or root == "/"
        or padded:find("/../", 1, true)
        or padded:find("/./", 1, true) then
        return false
    end
    return dir == root .. "/" .. Content.book_dir_name(book_id)
end

function Storage.book_dir(settings, book_id, book)
    return Content.book_resolved_dir(settings, book_id, book)
end

function Storage.book_usage(settings, book_id, book)
    local dir = Storage.book_dir(settings, book_id, book)
    local usage = scan(dir)
    usage.book_id = tostring(book_id)
    usage.title = type(book) == "table" and (book.title or book.text) or nil
    usage.path = dir
    return usage
end

function Storage.summary(settings, books)
    local result = { bytes = 0, files = 0, books = {} }
    for book_id, book in pairs(type(books) == "table" and books or {}) do
        local usage = Storage.book_usage(settings, book_id, book)
        if usage.bytes > 0 or path_mode(usage.path) ~= nil then
            result.bytes = result.bytes + usage.bytes
            result.files = result.files + usage.files
            result.books[#result.books + 1] = usage
        end
    end
    table.sort(result.books, function(left, right)
        return (left.bytes or 0) > (right.bytes or 0)
    end)
    result.book_count = #result.books
    return result
end

function Storage.remove_book(settings, book_id, book)
    local dir = Storage.book_dir(settings, book_id, book)
    if not is_book_dir(settings, book_id, dir) then
        return false, "unsafe_book_cache_path"
    end
    return remove_tree(dir)
end

function Storage.format_bytes(bytes)
    bytes = math.max(0, tonumber(bytes) or 0)
    if bytes >= 1024 * 1024 * 1024 then
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    elseif bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    end
    return string.format("%d B", bytes)
end

return Storage
