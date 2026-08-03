local Crypto = require("weread.lib.crypto")
local ReaderState = require("weread.lib.reader_state")
local WeRead = require("weread.lib.protocol")
local lfs = require("libs/libkoreader-lfs")
local logger = require("weread.lib.logger")

local Content = {}

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Recursive mkdir without a shell: lfs.mkdir only creates one level, while
-- the old `os.execute("mkdir -p ...")` relied on shell quoting that would
-- still expand $()/backticks inside double-quoted %q paths. Handles
-- absolute and relative paths; returns true or nil + error string.
function Content.ensure_dir_tree(path)
    if type(path) ~= "string" or path == "" then
        return nil, "empty path"
    end
    path = path:gsub("/+$", "")
    if path == "" or path == "/" then
        return true
    end
    local prefix = path:sub(1, 1) == "/" and "/" or ""
    local current = prefix
    local ok, err = pcall(function()
        for part in path:gmatch("[^/]+") do
            current = current == prefix and (prefix .. part)
                or (current .. "/" .. part)
            local mode = lfs.attributes(current, "mode")
            if mode == nil then
                local made, mkdir_err = lfs.mkdir(current)
                if not made then
                    error(mkdir_err or ("mkdir failed: " .. current))
                end
            elseif mode ~= "directory" and mode ~= "link" then
                -- lfs.attributes reports lstat: a symlink to a directory
                -- (e.g. /var -> /private/var on macOS) shows up as "link".
                -- Let it pass; a link to a non-directory still fails in
                -- mkdir/io.open below.
                error("not a directory: " .. current)
            end
        end
    end)
    if not ok then
        logger.warn("ensure_dir_tree failed:", path, tostring(err))
        return nil, tostring(err)
    end
    return true
end

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    if value == "" then
        value = "weread"
    end
    return value
end

-- Directory name a book is stored under (sanitized book id). Exposed so the
-- local-cache scanner can match on-disk directory names against shelf book ids.
function Content.book_dir_name(book_id)
    return basename_safe(book_id)
end

function Content.book_cache_dir(settings, book_id)
    return settings.cache_dir .. "/" .. Content.book_dir_name(book_id)
end

-- Resolve where a book's files actually live. The current settings.cache_dir may
-- differ from where a book was downloaded (the user changed it since), so prefer
-- concrete evidence of the real location: an explicit book.cache_dir (set when any
-- file — chapter or MP article — is written), then the directory of a stored
-- cached_file/chapter path, and only as a last resort the path recomputed under
-- the current root. This keeps deletion, stats and moves on the real files instead
-- of orphaning them. MP article-only books have no cached_file, so book.cache_dir
-- is the only thing that pins them down.
function Content.book_resolved_dir(settings, book_id, book)
    if book and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local function dirname(path)
        if type(path) == "string" then
            return path:match("^(.*)/[^/]+$")
        end
    end
    local dir = book and dirname(book.cached_file)
    if not dir and book and type(book.cached_chapters) == "table" then
        for _i, chapter_path in pairs(book.cached_chapters) do
            dir = dirname(chapter_path)
            if dir then
                break
            end
        end
    end
    return dir or Content.book_cache_dir(settings, book_id)
end

function Content.catalog_cache_path(settings, book)
    local book_id = book and (book.book_id or book.bookId)
    if not book_id then
        return nil
    end
    return Content.book_resolved_dir(settings, book_id, book) .. "/catalog.json"
end

function Content.save_catalog_cache(client, settings, book, chapters)
    if type(chapters) ~= "table" then
        return false, "chapter list is not a table"
    end
    local path = Content.catalog_cache_path(settings, book)
    if not path then
        return false, "missing book id"
    end
    local dir = path:match("^(.*)/[^/]+$")
    local made, mkdir_err = Content.ensure_dir_tree(dir)
    if not made then
        return false, mkdir_err or "mkdir failed"
    end
    local ok, encoded = pcall(function()
        return client:json_encode({
            version = 1,
            updated_at = os.time(),
            chapters = chapters,
        })
    end)
    if not ok then
        return false, encoded
    end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then
        return false, err
    end
    local write_ok, write_err = file:write(encoded)
    file:close()
    if not write_ok then
        os.remove(tmp_path)
        return false, write_err
    end
    local rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        return false, rename_err
    end
    book.cache_dir = dir
    return true, path
end

function Content.load_catalog_cache(client, settings, book)
    local path = Content.catalog_cache_path(settings, book)
    if not path then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local encoded = file:read("*a")
    file:close()
    local ok, decoded = pcall(function()
        return client:json_decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        logger.warn("ignore invalid catalog cache:", path)
        return nil
    end
    local chapters = decoded.chapters
    if type(chapters) ~= "table" then
        return nil
    end
    book.chapters = chapters
    return chapters
end

local function filename_safe(value)
    value = tostring(value or ""):gsub("[%z%c/\\:%*%?\"<>|]", "_")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("%s+", " ")
    if value == "" then
        value = "weread"
    end
    return value
end

local function item_id(prefix, value)
    return prefix .. basename_safe(value):gsub("%.", "_")
end

local function utc_modified()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function media_type_for(data)
    if data:sub(1, 8) == "\137PNG\r\n\026\n" then
        return ".png", "image/png"
    elseif data:sub(1, 3) == "\255\216\255" then
        return ".jpg", "image/jpeg"
    elseif data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return ".gif", "image/gif"
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp", "image/webp"
    end
    return ".bin", "application/octet-stream"
end

----------------------------------------------------------------
-- Chapter parts cache: during a full-book download every finished
-- chapter's finalized XHTML body and its image assets are written to
-- <book_dir>/parts/. When some chapters fail, a later "补齐缺失章节"
-- (fill-missing) run downloads only the missing ones and repacks the
-- EPUB from this cache plus the fresh downloads, instead of
-- re-downloading the whole book.
----------------------------------------------------------------

function Content.chapter_parts_dir(settings, book)
    local book_id = book and (book.book_id or book.bookId)
    if not book_id then
        return nil
    end
    return Content.book_resolved_dir(settings, book_id, book) .. "/parts"
end

local function write_file(path, data)
    local made = Content.ensure_dir_tree(path:match("^(.*)/[^/]+$"))
    if not made then
        return false
    end
    -- Write via a temp file and check every step so a disk-full/IO error
    -- cannot leave a truncated file that looks complete to the
    -- missing-chapter scan (review.md #6).
    local tmp_path = path .. ".tmp"
    local file = io.open(tmp_path, "wb")
    if not file then
        return false
    end
    local write_ok = file:write(data)
    local close_ok = file:close()
    if not write_ok or not close_ok then
        os.remove(tmp_path)
        return false
    end
    local rename_ok = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        return false
    end
    return true
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    return data
end

-- Persist one finished chapter body. Failures are non-fatal (the fill
-- run just re-downloads the chapter), so callers may ignore the result.
function Content.save_chapter_part(settings, book, uid, xhtml)
    local dir = Content.chapter_parts_dir(settings, book)
    if not dir or type(xhtml) ~= "string" then
        return false
    end
    return write_file(dir .. "/" .. basename_safe(uid) .. ".xhtml", xhtml)
end

function Content.load_chapter_part(settings, book, uid)
    local dir = Content.chapter_parts_dir(settings, book)
    if not dir then
        return nil
    end
    local data = read_file(dir .. "/" .. basename_safe(uid) .. ".xhtml")
    -- Treat missing AND empty/truncated files as absent so a fill-missing
    -- repack never embeds a broken chapter body (review.md #6).
    if type(data) ~= "string" or data == "" then
        return nil
    end
    return data
end

-- Chapters of the catalog whose part body is missing from the cache
-- (i.e. what a fill-missing run still has to download).
function Content.list_missing_chapters(settings, book, chapters)
    local missing = {}
    local dir = Content.chapter_parts_dir(settings, book)
    if not dir then
        return missing
    end
    for index, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        local uid = tostring(chapter.chapterUid or chapter.chapter_uid or index)
        local path = dir .. "/" .. basename_safe(uid) .. ".xhtml"
        -- Require a regular file *and* a non-zero size: a zero-byte file is
        -- the leftover of a failed write, and non-regular entries (dirs,
        -- links) must not count as valid chapter bodies (review.md #6).
        local mode = lfs.attributes(path, "mode")
        local size = lfs.attributes(path, "size")
        if mode ~= "file" or size == nil or tonumber(size) == 0 then
            table.insert(missing, chapter)
        end
    end
    return missing
end

-- The merged CSS of a full-book download (includes annotation styles);
-- saved once per book so a fill-missing repack can reuse it.
function Content.save_parts_css(settings, book, css)
    local dir = Content.chapter_parts_dir(settings, book)
    if not dir or type(css) ~= "string" or css == "" then
        return false
    end
    return write_file(dir .. "/style.css", css)
end

function Content.load_parts_css(settings, book)
    local dir = Content.chapter_parts_dir(settings, book)
    if not dir then
        return nil
    end
    return read_file(dir .. "/style.css")
end

-- Persist one downloaded asset (image) plus a sidecar file holding the
-- original href (flattening it into the filename would be lossy).
function Content.save_part_asset(settings, book, asset)
    local dir = Content.chapter_parts_dir(settings, book)
    if not dir or type(asset) ~= "table"
        or type(asset.href) ~= "string" or type(asset.data) ~= "string" then
        return false
    end
    local name = "asset_" .. basename_safe(asset.href:gsub("/", "_"))
    if not write_file(dir .. "/" .. name, asset.data) then
        return false
    end
    return write_file(dir .. "/" .. name .. ".href", asset.href)
end

-- All cached part assets as a save_book_epub-compatible list.
function Content.load_part_assets(settings, book)
    local dir = Content.chapter_parts_dir(settings, book)
    if not dir then
        return {}
    end
    local assets = {}
    for entry in lfs.dir(dir) do
        if entry:sub(1, 6) == "asset_" and entry:sub(-5) ~= ".href" then
            local data = read_file(dir .. "/" .. entry)
            local href = read_file(dir .. "/" .. entry .. ".href")
            if data and href then
                href = href:gsub("%s+$", "")
                assets[#assets + 1] = {
                    href = href,
                    media_type = select(2, media_type_for(data)),
                    data = data,
                }
            end
        end
    end
    return assets
end

local function trim_nulls(value)
    return tostring(value or ""):gsub("%z.*$", ""):gsub("%s+$", "")
end

local function tar_entries(data)
    local entries = {}
    local offset = 1
    while offset + 511 <= #data do
        local header = data:sub(offset, offset + 511)
        if header:match("^%z+$") then
            break
        end
        local name = trim_nulls(header:sub(1, 100))
        local size_text = trim_nulls(header:sub(125, 136)):gsub("%s", "")
        local size = tonumber(size_text, 8) or 0
        local typeflag = header:sub(157, 157)
        local body_start = offset + 512
        local body_end = body_start + size - 1
        if name ~= "" and (typeflag == "0" or typeflag == "" or typeflag == "\0") and size > 0 then
            table.insert(entries, {
                name = name,
                data = data:sub(body_start, body_end),
            })
        end
        offset = body_start + math.ceil(size / 512) * 512
    end
    return entries
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function unique_asset_name(used, name, ext)
    local base = filename_safe(name)
    if not base:lower():match(ext:gsub("%.", "%%.") .. "$") then
        base = base .. ext
    end
    local candidate = base
    local index = 2
    while used[candidate] do
        local stem = base:gsub("%.[^%.]+$", "")
        candidate = stem .. "-" .. tostring(index) .. ext
        index = index + 1
    end
    used[candidate] = true
    return candidate
end

local function write_epub(path, entries)
    local Archiver = require("ffi/archiver")
    local tmp_path = path .. ".tmp"
    local archive = Archiver.Writer:new{}
    if not archive:open(tmp_path, "epub") then
        os.remove(tmp_path)
        error("failed to open archive for writing: " .. tostring(archive.err))
    end

    -- Archive operations report failure through .err; a failed EPUB must
    -- never replace an existing file.
    local function fail(label, err)
        archive:close()
        os.remove(tmp_path)
        error(label .. ": " .. tostring(err))
    end

    local function check_archive_error(label)
        if archive.err then
            fail(label, archive.err)
        end
    end

    local mtime = os.time()
    archive:setZipCompression("store")
    check_archive_error("failed to set zip compression")
    local mimetype_data = "application/epub+zip"
    for _, entry in ipairs(entries) do
        if entry.name == "mimetype" then
            mimetype_data = entry.data
            break
        end
    end
    if not archive:addFileFromMemory("mimetype", mimetype_data, mtime) then
        fail("failed to write mimetype", archive.err)
    end

    archive:setZipCompression("deflate")
    check_archive_error("failed to set zip compression")
    for _, entry in ipairs(entries) do
        if entry.name ~= "mimetype" then
            if not archive:addFileFromMemory(
                entry.name, entry.data or "", mtime) then
                fail("failed to write " .. entry.name, archive.err)
            end
        end
    end

    archive:close()
    if archive.err then
        local archive_err = archive.err
        os.remove(tmp_path)
        error("failed to finalize archive: " .. tostring(archive_err))
    end
    -- Writer:close() swallows libarchive's finalization status, so verify
    -- the staged file was actually produced before atomically replacing
    -- the previous EPUB.
    local size = lfs.attributes(tmp_path, "size")
    if not size or size <= 0 then
        os.remove(tmp_path)
        error("failed to finalize archive")
    end
    local renamed, rename_err = os.rename(tmp_path, path)
    if not renamed then
        os.remove(tmp_path)
        error("failed to move archive into place: " .. tostring(rename_err))
    end
end

local function xml_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub("\"", "&quot;")
    return value
end

-- WeRead publisher footnotes arrive as a solid-color note.png whose
-- annotation text exists only in the image's alt attribute:
--   <img class="qqreader-footnote" alt="annotation" .../>
-- Convert them into standard EPUB noteref/footnote pairs so KOReader can
-- render a font-safe marker and show the annotation in its native popup.
function Content.convert_publisher_footnotes(xhtml)
    if type(xhtml) ~= "string" or xhtml == "" then
        return xhtml, 0
    end

    local footnotes = {}
    local function attribute(tag, name)
        return tag:match('[%s<]' .. name .. '%s*=%s*"(.-)"')
            or tag:match("[%s<]" .. name .. "%s*=%s*'(.-)'")
    end
    local converted = xhtml:gsub("<img%s[^>]->", function(tag)
        local class_name = attribute(tag, "class")
        local padded_class = " "
            .. tostring(class_name or ""):gsub("%s+", " ") .. " "
        if not padded_class:find(" qqreader-footnote ", 1, true) then
            return tag
        end

        local index = #footnotes + 1
        local note = attribute(tag, "alt")
        if type(note) ~= "string" or note == "" then
            note = "注释"
        end
        footnotes[index] = note
        return '<a id="wr-footnote-ref-' .. index
            .. '" class="wr-footnote-ref" epub:type="noteref"'
            .. ' role="doc-noteref" href="#wr-footnote-' .. index
            .. '"><sup>[' .. index .. ']</sup></a>'
    end)

    if #footnotes == 0 then
        return xhtml, 0
    end

    local targets = {
        '\n<section class="wr-footnotes" epub:type="footnotes"'
            .. ' role="doc-endnotes">\n',
    }
    for index, note in ipairs(footnotes) do
        targets[#targets + 1] = '<aside id="wr-footnote-' .. index
            .. '" class="wr-footnote" epub:type="footnote"'
            .. ' role="doc-footnote"><p><a href="#wr-footnote-ref-'
            .. index .. '">' .. index .. '.</a> ' .. note
            .. '</p></aside>\n'
    end
    targets[#targets + 1] = "</section>\n"
    local target_html = table.concat(targets)

    -- Decoded chapters may contain multiple concatenated XHTML documents.
    -- Place all targets in the last body so every target follows its source,
    -- which is required by KOReader's conservative footnote detection.
    local body_close
    local search_from = 1
    while true do
        local found = converted:find("</body>", search_from, true)
        if not found then
            break
        end
        body_close = found
        search_from = found + 7
    end
    if body_close then
        converted = converted:sub(1, body_close - 1) .. target_html
            .. converted:sub(body_close)
    else
        converted = converted .. target_html
    end

    logger.info("publisher footnotes converted:", tostring(#footnotes))
    return converted, #footnotes
end

-- WeRead EPUB chapters may decode to multiple concatenated XHTML documents.
-- The first <body> is often a title shell; main content lives in later bodies.
local function body_fragment(xhtml)
    xhtml = tostring(xhtml or "")
    local bodies = {}
    local remaining = xhtml
    while remaining ~= "" do
        local body_start = remaining:find("<body", 1, true)
        if not body_start then
            break
        end
        local body_open_end = remaining:find(">", body_start, true)
        if not body_open_end then
            break
        end
        local body_close = remaining:find("</body>", body_open_end, true)
        if not body_close then
            bodies[#bodies + 1] = remaining:sub(body_open_end + 1)
            break
        end
        bodies[#bodies + 1] = remaining:sub(body_open_end + 1, body_close - 1)
        remaining = remaining:sub(body_close + 7)
    end
    if #bodies > 0 then
        return table.concat(bodies, "\n")
    end
    xhtml = xhtml:gsub("<%?xml.-%?>", "")
    xhtml = xhtml:gsub("<!DOCTYPE.-%>", "")
    return xhtml
end

local function checked_body(response_text)
    if not response_text or #response_text <= 32 then
        return ""
    end
    local expected = response_text:sub(1, 32)
    local body = response_text:sub(33)
    local actual = Crypto.md5_hex(body):upper()
    if actual ~= expected then
        error("Shard MD5 mismatch")
    end
    return body
end

local function base64_decode(data)
    data = data:gsub("-", "+"):gsub("_", "/")
    local pad = #data % 4
    if pad > 0 then
        data = data .. string.rep("=", 4 - pad)
    end
    data = data:gsub("[^" .. b64chars .. "=]", "")
    return (data:gsub(".", function(char)
        if char == "=" then
            return ""
        end
        local bits = ""
        local index = b64chars:find(char, 1, true) - 1
        for bit = 6, 1, -1 do
            bits = bits .. (index % 2 ^ bit - index % 2 ^ (bit - 1) > 0 and "1" or "0")
        end
        return bits
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(bits)
        if #bits ~= 8 then
            return ""
        end
        local byte = 0
        for i = 1, 8 do
            if bits:sub(i, i) == "1" then
                byte = byte + 2 ^ (8 - i)
            end
        end
        return string.char(byte)
    end))
end

local function swap_positions(encoded)
    local length = #encoded
    if length < 4 then
        return {}
    end
    if length < 11 then
        return {0, 2}
    end

    local n = math.min(4, math.floor((length + 9) / 10))
    local tmp = {}
    for i = length, length - n + 1, -1 do
        local byte = encoded:byte(i)
        local bin = {}
        repeat
            table.insert(bin, 1, tostring(byte % 2))
            byte = math.floor(byte / 2)
        until byte == 0
        local value = tonumber(table.concat(bin), 4) or 0
        table.insert(tmp, tostring(value))
    end
    tmp = table.concat(tmp)

    local result = {}
    local m = length - n - 2
    local step = #tostring(m)
    local i = 1
    while #result < 10 and i + step - 1 < #tmp do
        table.insert(result, (tonumber(tmp:sub(i, i + step - 1)) or 0) % m)
        local end2 = math.min(i + step, #tmp)
        if i + 1 <= #tmp then
            table.insert(result, (tonumber(tmp:sub(i + 1, end2)) or 0) % m)
        end
        i = i + step
    end
    return result
end

local function reverse_swaps(encoded, positions)
    local chars = {}
    for i = 1, #encoded do
        chars[i] = encoded:sub(i, i)
    end
    for i = #positions, 1, -2 do
        for k = 1, 0, -1 do
            local left = positions[i] + k + 1
            local right = positions[i - 1] + k + 1
            chars[left], chars[right] = chars[right], chars[left]
        end
    end
    return table.concat(chars)
end

local function decode_encoded_body(body)
    if #body == 0 then
        return ""
    end
    local encoded = body:sub(2)
    local restored = reverse_swaps(encoded, swap_positions(encoded))
    return base64_decode(restored)
end

function Content.decode_content_shards(e0, e1, e3)
    local body = checked_body(e0) .. checked_body(e1) .. checked_body(e3)
    return decode_encoded_body(body)
end

function Content.decode_content_shard(e0)
    return decode_encoded_body(checked_body(e0))
end

function Content.extract_reader_state(html, json_decode)
    return ReaderState.extract(html, json_decode)
end

function Content.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then
        records = payload.data
    end
    if type(records) ~= "table" then
        return {}
    end
    if records.bookId or records.updated then
        records = { records }
    end
    for record_index, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            return record.updated or record.chapterInfos or record.chapters or {}
        end
    end
    return {}
end

function Content.readable_chapters(chapters)
    local out = {}
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tonumber(chapter.wordCount or 0) > 0 and tostring(chapter.title or "") ~= "封面" then
            table.insert(out, chapter)
        end
    end
    return out
end

local function chapter_level(chapter)
    local level = tonumber(chapter and chapter.level or 1) or 1
    if level < 1 then
        level = 1
    elseif level > 6 then
        level = 6
    end
    return level
end

local function build_chapter_tree(chapters, filename_for)
    local root = { children = {} }
    local stack = { root }
    for chapter_index, chapter in ipairs(chapters or {}) do
        local level = chapter_level(chapter)
        if level > #stack then
            level = #stack
        end
        while #stack > level do
            table.remove(stack)
        end
        local parent = stack[#stack] or root
        local node = {
            title = chapter.title or ("Chapter " .. tostring(chapter.chapterUid or chapter_index)),
            href = filename_for(chapter_index, chapter),
            children = {},
        }
        table.insert(parent.children, node)
        stack[level + 1] = node
    end
    return root.children
end

local function build_nav_items(chapters, filename_for)
    local tree = build_chapter_tree(chapters, filename_for)
    local function render(nodes)
        local out = {}
        for node_index, node in ipairs(nodes or {}) do
            table.insert(out, [[<li><a href="]] .. xml_escape(node.href) .. [[">]] .. xml_escape(node.title) .. [[</a>]])
            if node.children and #node.children > 0 then
                table.insert(out, "<ol>")
                table.insert(out, render(node.children))
                table.insert(out, "</ol>")
            end
            table.insert(out, "</li>")
        end
        return table.concat(out, "\n")
    end

    return render(tree)
end

local function build_ncx_points(chapters, filename_for)
    local tree = build_chapter_tree(chapters, filename_for)
    local play_order = 0
    local function render(nodes)
        local out = {}
        for node_index, node in ipairs(nodes or {}) do
            play_order = play_order + 1
            local current_order = play_order
            table.insert(out, [[<navPoint id="navPoint-]] .. tostring(current_order) .. [[" playOrder="]] .. tostring(current_order) .. [[">]])
            table.insert(out, [[<navLabel><text>]] .. xml_escape(node.title) .. [[</text></navLabel>]])
            table.insert(out, [[<content src="]] .. xml_escape(node.href) .. [["/>]])
            if node.children and #node.children > 0 then
                table.insert(out, render(node.children))
            end
            table.insert(out, "</navPoint>")
        end
        return table.concat(out, "\n")
    end
    return render(tree), play_order
end

function Content.save_chapter_epub(settings, book, chapter, xhtml, assets, css)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    local made, mkdir_err = Content.ensure_dir_tree(dir)
    if not made then
        error("cannot create book directory: " .. tostring(mkdir_err))
    end
    book.cache_dir = dir
    local book_title = book.title or "WeRead"
    local path = dir .. "/" .. filename_safe(book_title .. " - " .. (chapter.title or tostring(chapter.chapterUid or "chapter"))) .. ".epub"
    local title = chapter.title or book.title or "WeRead"
    local author = book.author or "WeRead"
    local manifest_assets = {}
    local asset_entries = {}
    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_assets, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
        table.insert(asset_entries, { name = "OEBPS/" .. asset.href, data = asset.data })
    end
    local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(xhtml) .. [[
</body>
</html>]]
    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(chapter.chapterUid or "chapter") .. [[</dc:identifier>
<dc:title>]] .. xml_escape(book_title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(author) .. [[</dc:creator>
<dc:publisher>WeRead</dc:publisher>
<dc:source>]] .. xml_escape(WeRead.reader_url(book_id, chapter.chapterUid)) .. [[</dc:source>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="style" href="style.css" media-type="text/css"/>
<item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
]] .. table.concat(manifest_assets, "\n") .. [[
</manifest>
<spine>
<itemref idref="chapter"/>
</spine>
</package>]]
    local nav = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
<ol><li><a href="text/chapter.xhtml">]] .. xml_escape(title) .. [[</a></li></ol>
</nav>
</body>
</html>]]
    css = css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
        { name = "OEBPS/content.opf", data = opf },
        { name = "OEBPS/nav.xhtml", data = nav },
        { name = "OEBPS/style.css", data = css },
        { name = "OEBPS/text/chapter.xhtml", data = chapter_xhtml },
    }
    for asset_index, asset in ipairs(asset_entries) do
        table.insert(entries, asset)
    end
    write_epub(path, entries)
    return path
end

function Content.save_book_epub(settings, book, chapters, chapter_bodies, suffix, assets, css, cover_data)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    local made, mkdir_err = Content.ensure_dir_tree(dir)
    if not made then
        error("cannot create book directory: " .. tostring(mkdir_err))
    end
    book.cache_dir = dir
    local book_title = book.title or "WeRead"
    local path = dir .. "/" .. filename_safe(book_title .. " - " .. (suffix or "book")) .. ".epub"
    local author = book.author or "WeRead"
    local manifest_items = {
        [[<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>]],
        [[<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]],
        [[<item id="style" href="style.css" media-type="text/css"/>]],
    }
    local spine_items = {}
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
    }

    local cover_meta = ""
    if cover_data and #cover_data > 0 then
        local ext, mime = media_type_for(cover_data)
        local cover_img_href = "images/cover" .. ext
        table.insert(entries, { name = "OEBPS/" .. cover_img_href, data = cover_data })
        table.insert(manifest_items, [[<item id="cover-image" href="]] .. xml_escape(cover_img_href) .. [[" media-type="]] .. xml_escape(mime) .. [[" properties="cover-image"/>]])
        table.insert(manifest_items, [[<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="cover"/>]])
        local cover_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head><title>Cover</title>
<style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;}img{display:block;width:100%;height:100%;object-fit:contain;}</style>
</head>
<body><img src="../]] .. xml_escape(cover_img_href) .. [[" alt="Cover"/></body>
</html>]]
        table.insert(entries, { name = "OEBPS/text/cover.xhtml", data = cover_xhtml })
        cover_meta = '\n<meta name="cover" content="cover-image"/>'
    end

    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_items, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
        table.insert(entries, { name = "OEBPS/" .. asset.href, data = asset.data })
    end

    for chapter_index, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        local filename = string.format("text/chapter-%03d.xhtml", chapter_index)
        local id = item_id("chapter_", uid)
        local title = chapter.title or ("Chapter " .. uid)
        local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(chapter_bodies[uid] or "") .. [[
</body>
</html>]]
        table.insert(entries, { name = "OEBPS/" .. filename, data = chapter_xhtml })
        table.insert(manifest_items, [[<item id="]] .. id .. [[" href="]] .. filename .. [[" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="]] .. id .. [["/>]])
    end

    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(suffix or "book") .. [[</dc:identifier>
<dc:title>]] .. xml_escape(book_title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(author) .. [[</dc:creator>
<dc:publisher>WeRead</dc:publisher>
<dc:source>]] .. xml_escape(WeRead.reader_url(book_id)) .. [[</dc:source>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>]] .. cover_meta .. [[
</metadata>
<manifest>
]] .. table.concat(manifest_items, "\n") .. [[
</manifest>
<spine toc="toc">
]] .. table.concat(spine_items, "\n") .. [[
</spine>
</package>]]
    local ncx_points = build_ncx_points(chapters, function(chapter_index)
        return string.format("text/chapter-%03d.xhtml", chapter_index)
    end)
    local ncx = [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head>
<meta name="dtb:uid" content="weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(suffix or "book") .. [["/>
<meta name="dtb:depth" content="6"/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>
<docTitle><text>]] .. xml_escape(book_title) .. [[</text></docTitle>
<navMap>
]] .. ncx_points .. [[
</navMap>
</ncx>]]
    local nav = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
<ol>
]] .. build_nav_items(chapters, function(chapter_index)
        return string.format("text/chapter-%03d.xhtml", chapter_index)
    end) .. [[
</ol>
</nav>
</body>
</html>]]
    css = css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    table.insert(entries, { name = "OEBPS/content.opf", data = opf })
    table.insert(entries, { name = "OEBPS/nav.xhtml", data = nav })
    table.insert(entries, { name = "OEBPS/toc.ncx", data = ncx })
    table.insert(entries, { name = "OEBPS/style.css", data = css })
    write_epub(path, entries)
    return path
end

function Content.rewrite_image_sources(xhtml, src_map)
    if not src_map or not next(src_map) then
        return xhtml
    end
    local function replace_src(quote, src)
        local clean = tostring(src or ""):gsub("&amp;", "&")
        local key = basename(clean:match("^[^%?#]+") or clean)
        local href = src_map[key]
        if href then
            return "src=" .. quote .. href .. quote
        end
        return "src=" .. quote .. src .. quote
    end
    xhtml = xhtml:gsub("src=(['\"])(.-)%1", replace_src)
    return xhtml
end

function Content.download_remote_images(client, xhtml, used_names, progress)
    local assets = {}
    used_names = used_names or {}
    used_names.__remote_image_hrefs = used_names.__remote_image_hrefs or {}
    local remote_image_hrefs = used_names.__remote_image_hrefs
    local function remote_url(src)
        local url = tostring(src or "")
        if url:match("^//") then
            url = "https:" .. url
        end
        if url:match("^https?://") then
            return url
        end
    end
    local img_total = 0
    xhtml:gsub('src=(["\'])(.-)%1', function(_, src)
        if remote_url(src) then
            img_total = img_total + 1
        end
    end)
    if img_total == 0 then
        return xhtml, assets
    end
    local index = 0
    local body = xhtml:gsub('src=(["\'])(.-)%1', function(quote, src)
        local url = remote_url(src)
        if not url then
            return "src=" .. quote .. src .. quote
        end
        index = index + 1
        if progress then
            progress(index, img_total)
        end
        local cached_href = remote_image_hrefs[url]
        if cached_href then
            return "src=" .. quote .. "../" .. cached_href .. quote
        end
        local ok, data = pcall(function()
            return client:get_binary(url, { referer = "https://weread.qq.com/" })
        end)
        if not ok or not data or #data == 0 then
            return "src=" .. quote .. src .. quote
        end
        local ext, mt = media_type_for(data)
        if not mt:match("^image/") then
            return "src=" .. quote .. src .. quote
        end
        local seed = basename((url:match("^[^%?#]+") or url))
        local fname = unique_asset_name(used_names, seed ~= "" and seed or ("img" .. tostring(index)), ext)
        local href = "images/" .. fname
        remote_image_hrefs[url] = href
        table.insert(assets, {
            href = href,
            media_type = mt,
            data = data,
        })
        return "src=" .. quote .. "../" .. href .. quote
    end)
    return body, assets
end

function Content.download_chapter_assets(client, book, chapter, used_names)
    if not chapter or not chapter.tar or chapter.tar == "" then
        return {}, {}
    end
    used_names = used_names or {}
    local book_id = book.book_id or book.bookId
    local referer = WeRead.reader_url(book_id, chapter.chapterUid)
    local tar_url = tostring(chapter.tar)
    if tar_url:match("^//") then
        tar_url = "https:" .. tar_url
    elseif tar_url:match("^/") then
        tar_url = "https://weread.qq.com" .. tar_url
    end
    local raw = client:get_binary(tar_url, { referer = referer })
    local assets = {}
    local src_map = {}
    for entry_index, entry in ipairs(tar_entries(raw)) do
        local ext, media_type = media_type_for(entry.data)
        if media_type:match("^image/") then
            local stem = basename(entry.name)
            local filename = unique_asset_name(used_names, stem, ext)
            local href = "images/" .. filename
            local epub_relative = "../" .. href
            table.insert(assets, {
                href = href,
                media_type = media_type,
                data = entry.data,
            })
            src_map[stem] = epub_relative
            src_map[filename] = epub_relative
        end
    end
    return assets, src_map
end

function Content.ensure_reader_state(client, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or WeRead.reader_url(book_id)
    local reader_html = client:get_text(reader_url, { referer = reader_url })
    local state = Content.extract_reader_state(reader_html, function(encoded)
        return client:json_decode(encoded)
    end)
    book.book_id = book.book_id or state.book_id or book.bookId
    book.title = book.title or state.title
    book.author = book.author or state.author
    -- These values belong to one Web Reader session. Never retain a cached
    -- value when the freshly opened reader omits it (notably pclts).
    book.psvts = state.psvts
    book.pclts = state.pclts
    book.token = state.token
    book.reader_url = reader_url

    ReaderState.apply_to_book(book, state)

    if not book.psvts then
        error("reader.psvts not found")
    end
    return state
end

--- Refresh psvts before downloading a chapter (matches per-chapter reader page fetch).
function Content.refresh_reader_state(client, book, chapter)
    book.psvts = nil
    local book_id = book.book_id or book.bookId
    if chapter and chapter.chapterUid then
        book.reader_url = WeRead.reader_url(book_id, chapter.chapterUid)
    else
        book.reader_url = book.reader_url or WeRead.reader_url(book_id)
    end
    Content.ensure_reader_state(client, book)
end

function Content.fetch_catalog(client, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or WeRead.reader_url(book_id)
    local catalog = client:post_json("https://weread.qq.com/web/book/chapterInfos", {
        bookIds = { tostring(book_id) },
    }, { referer = reader_url })
    local chapters = Content.readable_chapters(Content.normalize_chapters(catalog, book_id))
    book.chapters = chapters
    return chapters
end

function Content.fetch_chapter_shard(client, _settings, book, chapter, endpoint)
    if not book.psvts then
        Content.ensure_reader_state(client, book)
    end
    local book_id = book.book_id or book.bookId
    if not chapter then
        error("chapter is required")
    end

    local chapter_url = WeRead.reader_url(book_id, chapter.chapterUid)
    local is_style_shard = endpoint:find("/e_2", 1, true) ~= nil
    local params = WeRead.make_content_params(book_id, chapter.chapterUid, book.psvts, {
        sc = 1,
        style = is_style_shard,
    })
    local text, code = client:request({
        url = "https://weread.qq.com" .. endpoint,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            ["Referer"] = chapter_url,
        },
        body = client:json_encode(params),
    })
    if not code or code < 200 or code >= 300 then
        error(endpoint .. " failed: HTTP " .. tostring(code or "unknown"))
    end
    if text == "{}" then
        error(endpoint .. " returned empty object")
    end
    return text
end

function Content.txt_to_xhtml(text)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local parts = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^(.-)%s*$") or ""
        if line ~= "" then
            table.insert(parts, "<p>" .. xml_escape(line) .. "</p>")
        end
    end
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head>\n'
        .. '<body>\n' .. table.concat(parts, "\n") .. '\n</body></html>'
end

function Content.fetch_txt_as_xhtml(client, settings, book, chapter)
    local t0 = Content.fetch_chapter_shard(client, settings, book, chapter, "/web/book/chapter/t_0")
    local ok_t1, t1 = pcall(Content.fetch_chapter_shard, client, settings, book, chapter, "/web/book/chapter/t_1")
    if not ok_t1 then t1 = "" end
    local plain = Content.decode_content_shards(t0, t1, "")
    return Content.txt_to_xhtml(plain)
end

function Content.fetch_chapter_xhtml(client, settings, book, chapter)
    Content.refresh_reader_state(client, book, chapter)

    if book._content_format == "txt" then
        return Content.fetch_txt_as_xhtml(client, settings, book, chapter)
    end

    local ok, e0 = pcall(Content.fetch_chapter_shard, client, settings, book, chapter, "/web/book/chapter/e_0")

    if ok and e0:sub(1, 1) == "{" and e0:find('"bookId"', 1, true) then
        book._content_format = "txt"
        return Content.fetch_txt_as_xhtml(client, settings, book, chapter)
    end

    if not ok then
        error(e0)
    end

    book._content_format = "epub"
    return Content.decode_content_shards(
        e0,
        Content.fetch_chapter_shard(client, settings, book, chapter, "/web/book/chapter/e_1"),
        Content.fetch_chapter_shard(client, settings, book, chapter, "/web/book/chapter/e_3")
    )
end

function Content.fetch_chapter_css(client, settings, book, chapter)
    local ok, css = pcall(function()
        return Content.decode_content_shard(Content.fetch_chapter_shard(client, settings, book, chapter, "/web/book/chapter/e_2"))
    end)
    if ok then
        return css
    end
    return nil
end

-- Split chapter downloading around annotation fetching so the UI can request
-- thought batches cooperatively instead of blocking on them mid-download.
function Content.fetch_single_chapter_source(client, settings, book, chapter, state)
    state = state or {}
    local xhtml = Content.fetch_chapter_xhtml(client, settings, book, chapter)
    if not state.css then
        state.css = Content.fetch_chapter_css(client, settings, book, chapter)
    end
    return xhtml
end

function Content.finalize_single_chapter_content(client, settings, book, chapter, xhtml, state)
    state = state or {}
    local chapter_assets = {}
    xhtml = Content.convert_publisher_footnotes(xhtml)
    local cache = settings:get("cache", {})
    if cache.download_book_images then
        state.used_asset_names = state.used_asset_names or {}
        local tar_assets, src_map = Content.download_chapter_assets(client, book, chapter, state.used_asset_names)
        for _, asset in ipairs(tar_assets) do
            table.insert(chapter_assets, asset)
        end
        xhtml = Content.rewrite_image_sources(xhtml, src_map)
        local inline_xhtml, inline_assets = Content.download_remote_images(client, xhtml, state.used_asset_names)
        xhtml = inline_xhtml
        for _, asset in ipairs(inline_assets) do
            table.insert(chapter_assets, asset)
        end
    end
    return xhtml, chapter_assets
end

return Content
