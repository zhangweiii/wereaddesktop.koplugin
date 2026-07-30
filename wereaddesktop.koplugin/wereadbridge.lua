--[[--
Integration layer between the weread-desktop plugin and the bundled WeRead
(weread.qq.com) client library. Exposes a small synchronous API for the
desktop: login state, QR login, shelf fetching/caching, cover downloads
and full-book EPUB downloads. All network calls block (LuaSocket);
callers are expected to wrap them in UIManager:scheduleIn-style deferred
tasks.
--]]--

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5

local Client = require("weread.lib.client")
local Content = require("weread.lib.content")
local Downloader = require("weread.lib.downloader")
local QRLogin = require("weread.lib.qr_login")
local Settings = require("weread.lib.settings")
local WeRead = require("weread.lib.protocol")
local logger = require("weread.lib.logger").scoped("Bridge")

local Bridge = {}
Bridge.__index = Bridge

local SHELF_CACHE_KEY = "wereaddesktop_shelf"
-- Shelf cache key used before the plugin was renamed; migrated on read.
local LEGACY_SHELF_CACHE_KEY = "kodesktop_shelf"
local COVER_EXTS = { ".jpg", ".png", ".webp", ".gif" }

-- Guess an image extension from the file's magic bytes.
local function sniff_ext(data)
    if type(data) ~= "string" or #data < 12 then
        return nil
    end
    if data:sub(1, 3) == "\xFF\xD8\xFF" then
        return ".jpg"
    end
    if data:sub(1, 4) == "\x89PNG" then
        return ".png"
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp"
    end
    if data:sub(1, 3) == "GIF" then
        return ".gif"
    end
    return nil
end

local function ensure_dir(path)
    if not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

-- Map one /shelf/sync entry onto the desktop book contract.
local function map_shelf_book(b)
    local progress = tonumber(b.progress) or tonumber(b.readingProgress) or 0
    return {
        book_id = tostring(b.bookId),
        text = b.title or "",
        authors = b.author or "",
        cover_url = WeRead.normalize_cover_url(b.cover),
        cover_path = nil,
        progress = math.max(0, math.min(1, progress / 100)),
        finished = b.finishReading == 1,
        read_update_time = tonumber(b.readUpdateTime) or 0,
        -- Filled in from the web shelf progress endpoint when available.
        chapter_uid = nil,
        chapter_idx = nil,
    }
end

-- host: table of UI callbacks used by QRLogin (showBusy, runOnlineTask,
-- showInfo, ...), implemented by the desktop plugin.
function Bridge:new(host)
    local settings = Settings:new()
    -- Covers lived under /kodesktop before the rename; move the directory
    -- once so already-downloaded covers survive.
    local data_dir = DataStorage:getFullDataDir()
    pcall(os.rename, data_dir .. "/kodesktop", data_dir .. "/wereaddesktop")
    local covers_dir = data_dir .. "/wereaddesktop/covers"
    ensure_dir(data_dir .. "/wereaddesktop")
    ensure_dir(covers_dir)
    return setmetatable({
        host = host,
        settings = settings,
        client = Client:new(settings),
        covers_dir = covers_dir,
        qr_login = nil,
    }, self)
end

function Bridge:isLoggedIn()
    return self.settings:is_api_configured()
        or self.settings:is_cookie_configured()
end

function Bridge:getAccountName()
    local account = self.settings:get("account", {})
    if type(account) == "table" and type(account.name) == "string"
        and account.name ~= "" then
        return account.name
    end
    return nil
end

-- Start the QR login flow. on_done(ok, err_msg) fires once: ok=true after
-- credentials were stored, ok=false when the flow is cancelled or fails
-- (QRLogin itself surfaces detailed errors through the host UI).
function Bridge:startLogin(on_done)
    local qr = QRLogin:new(self.host, self.client, self.settings)
    self.qr_login = qr
    if on_done then
        local fired = false
        local function fire(ok, err)
            if not fired then
                fired = true
                on_done(ok, err)
            end
        end
        -- Success persists credentials via settings:update_auth; shadow the
        -- method on this instance to hook that moment.
        local settings = self.settings
        local orig_update_auth = settings.update_auth
        settings.update_auth = function(s, credentials, options)
            settings.update_auth = orig_update_auth
            local result = orig_update_auth(s, credentials, options)
            fire(true)
            return result
        end
        -- Every abort path (user dismiss, expiry, protocol error) ends in
        -- cancel(). start() calls cancel() once up front, synchronously,
        -- so start first and wrap cancel only after it has returned —
        -- otherwise the up-front cancel consumes the oneshot callback.
        qr:start()
        local orig_cancel = qr.cancel
        qr.cancel = function(qr_self)
            orig_cancel(qr_self)
            fire(false, "登录失败或已取消")
        end
    else
        qr:start()
    end
end

function Bridge:logout()
    if self.qr_login then
        self.qr_login:cancel()
        self.qr_login = nil
    end
    self.settings:reset_account()
    self.settings:set(SHELF_CACHE_KEY, nil)
    self.settings:set("pending_finish_sync", nil)
    self.settings:flush()
end

-- Books cached from the last successful fetch (usable offline), or nil.
-- Refreshed from disk first: the reader-context instance may have
-- written progress updates (updateShelfProgress) through its own
-- in-memory view since this instance last loaded the file.
function Bridge:getCachedShelf()
    self.settings:refresh(SHELF_CACHE_KEY)
    local cached = self.settings:get(SHELF_CACHE_KEY, nil)
    if cached == nil then
        cached = self.settings:get(LEGACY_SHELF_CACHE_KEY, nil)
        if cached ~= nil then
            self.settings:set(SHELF_CACHE_KEY, cached)
            self.settings:set(LEGACY_SHELF_CACHE_KEY, nil)
            self.settings:flush()
        end
    end
    if type(cached) == "table" and #cached > 0 then
        return cached
    end
    return nil
end

-- Write back a shelf table mutated after fetching (e.g. cover_path).
function Bridge:saveShelf(books)
    self.settings:set(SHELF_CACHE_KEY, books)
    self.settings:flush()
end

-- Patch the cached shelf entry after a successful progress upload, so
-- the desktop shows the new percentage without a network refresh.
function Bridge:updateShelfProgress(book_id, fraction)
    local books = self:getCachedShelf()
    if not books then
        return
    end
    for _, book in ipairs(books) do
        if book.book_id == tostring(book_id) then
            book.progress = math.max(0, math.min(1, tonumber(fraction) or 0))
            self:saveShelf(books)
            return
        end
    end
end

-- Patch the cached shelf after the explicit finished flag has been
-- accepted by WeRead. Progress and completion are separate server fields,
-- so cancelling completion must not rewind the last reading position.
function Bridge:updateShelfFinished(book_id, finished)
    local books = self:getCachedShelf()
    if not books then
        return
    end
    for _, book in ipairs(books) do
        if book.book_id == tostring(book_id) then
            book.finished = finished == true
            self:saveShelf(books)
            return
        end
    end
end

-- Fetch the shelf via the gateway and update the cache. Synchronous and
-- blocking; cb(books|nil, err). Without force_refresh a cached shelf is
-- returned straight away.
function Bridge:fetchShelf(force_refresh, cb)
    if not force_refresh then
        local cached = self:getCachedShelf()
        if cached then
            cb(cached)
            return
        end
    end
    local ok, result = pcall(function()
        return self.client:get_shelf()
    end)
    if not ok then
        logger.err("shelf fetch failed:", tostring(result))
        cb(nil, tostring(result))
        return
    end
    -- Keep previously downloaded cover paths and last-known progress
    -- across refreshes.
    local old_covers = {}
    local old_progress = {}
    for _, book in ipairs(self:getCachedShelf() or {}) do
        if book.cover_path then
            old_covers[book.book_id] = book.cover_path
        end
        old_progress[book.book_id] = book
    end
    -- The gateway shelf has no progress; merge it from the web endpoint.
    -- Failures here must not lose the shelf itself — nor the progress we
    -- already knew about.
    local progress_map = nil
    local ok_progress, map_or_err, progress_err = pcall(function()
        return self.client:get_shelf_progress()
    end)
    if not ok_progress then
        -- pcall caught a throw; the message sits in the second value.
        progress_err = map_or_err
        map_or_err = nil
    end
    if type(map_or_err) == "table" then
        progress_map = map_or_err
        self.session_expired = false
    else
        logger.warn("shelf progress unavailable, keeping cached progress:",
            tostring(progress_err))
        if progress_err == "auth_expired" then
            -- The web session is dead (kicked by another device or
            -- expired); main.lua prompts for a fresh QR login.
            self.session_expired = true
        end
    end
    local books = {}
    for _, b in ipairs(type(result) == "table" and result.books or {}) do
        if b.bookId and not WeRead.is_mp_book(b.bookId) then
            local book = map_shelf_book(b)
            book.cover_path = old_covers[book.book_id]
            local p = progress_map and progress_map[book.book_id] or nil
            if p then
                book.progress = math.max(0, math.min(1, p.progress / 100))
                book.finished = book.finished or p.progress >= 100
                book.chapter_uid = p.chapter_uid
                book.chapter_idx = p.chapter_idx
                -- The progress entry's update time moves on every device
                -- that reads the book; readUpdateTime alone can lag.
                book.last_read_time = math.max(book.read_update_time or 0,
                    p.update_time or 0)
            elseif not progress_map then
                -- Progress endpoint failed: keep the cached values instead
                -- of regressing a half-read book to 未读.
                local old = old_progress[book.book_id]
                if old then
                    book.progress = old.progress
                    book.finished = book.finished or old.finished
                    book.chapter_uid = old.chapter_uid
                    book.chapter_idx = old.chapter_idx
                    book.last_read_time = old.last_read_time
                end
            end
            table.insert(books, book)
        end
    end
    table.sort(books, function(a, b2)
        return (a.last_read_time or a.read_update_time or 0)
            > (b2.last_read_time or b2.read_update_time or 0)
    end)
    self.settings:set(SHELF_CACHE_KEY, books)
    self.settings:flush()
    cb(books)
end

----------------------------------------------------------------
-- WeRead store (书城): search and recommendation feeds.
----------------------------------------------------------------

-- Map a store/recommend bookInfo onto the shelf book contract, so store
-- results render with the same cells and cover pipeline as the shelf.
local function map_store_book(info)
    return {
        book_id = tostring(info.bookId),
        text = info.title or "",
        authors = info.author or "",
        cover_url = WeRead.normalize_cover_url(info.cover),
        cover_path = nil,
        progress = 0,
        finished = false,
    }
end

-- Search the store (blocking); cb(books|nil, err).
function Bridge:searchStore(keyword, cb)
    local ok, result = pcall(function()
        return self.client:gateway("/store/search", {
            keyword = keyword,
            scope = 10,
            count = 20,
            maxIdx = 0,
        })
    end)
    if not ok or type(result) ~= "table" then
        logger.err("store search failed:", tostring(result))
        cb(nil, tostring(result))
        return
    end
    local books = {}
    for _, r in ipairs(result.results or {}) do
        for _, b in ipairs(r.books or {}) do
            local info = b.bookInfo
            if info and info.bookId and not WeRead.is_mp_book(info.bookId) then
                table.insert(books, map_store_book(info))
            end
        end
    end
    cb(books)
end

-- Store home feed (blocking): recommendations plus books similar to the
-- most recently read shelf book. cb(sections|nil, err) where sections is
-- { {title=, books=...}, ... }; the similar section is omitted when it
-- comes back empty or the shelf is empty.
function Bridge:getStoreFeed(cb)
    local ok, result = pcall(function()
        return self.client:gateway("/book/recommend", { count = 20 })
    end)
    if not ok or type(result) ~= "table" then
        logger.err("store recommend failed:", tostring(result))
        cb(nil, tostring(result))
        return
    end
    local sections = {}
    local recommended = {}
    for _, b in ipairs(result.books or {}) do
        if b.bookId and not WeRead.is_mp_book(b.bookId) then
            table.insert(recommended, map_store_book(b))
        end
    end
    table.insert(sections, { title = "为你推荐", books = recommended })
    local shelf = self:getCachedShelf()
    if shelf and shelf[1] then
        local ok_similar, similar = pcall(function()
            return self.client:gateway("/book/similar", {
                bookId = tostring(shelf[1].book_id),
                count = 10,
                -- Not optional in practice: the gateway answers
                -- errcode -2003 (参数格式错误) without it.
                maxIdx = 0,
            })
        end)
        local books = {}
        if ok_similar and type(similar) == "table" then
            for _, entry in ipairs(similar.booksimilar and similar.booksimilar.books or {}) do
                local info = entry.book and entry.book.bookInfo
                if info and info.bookId and not WeRead.is_mp_book(info.bookId) then
                    table.insert(books, map_store_book(info))
                end
            end
        else
            logger.warn("store similar unavailable:", tostring(similar))
        end
        if #books > 0 then
            table.insert(sections, { title = "猜你喜欢", books = books })
        end
    end
    cb(sections)
end

-- Account id shown on the settings tab, when known.
function Bridge:getAccountVid()
    local account = self.settings:get("account", {})
    if type(account) == "table" and account.user_vid
        and tostring(account.user_vid) ~= "" then
        return tostring(account.user_vid)
    end
    return nil
end

-- Local cover path for a book_id, if a previous download is still on disk.
function Bridge:findCachedCover(book_id)
    local base = self.covers_dir .. "/" .. md5(tostring(book_id))
    for _, ext in ipairs(COVER_EXTS) do
        local path = base .. ext
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
    return nil
end

-- Download the book's cover into the cache (blocking) and fill in
-- book.cover_path; cb(local_path|nil).
function Bridge:ensureCover(book, cb)
    if type(book) ~= "table" or not book.book_id then
        cb(nil)
        return
    end
    local cached = self:findCachedCover(book.book_id)
    if cached then
        book.cover_path = cached
        cb(cached)
        return
    end
    if type(book.cover_url) ~= "string" or book.cover_url == "" then
        cb(nil)
        return
    end
    local ok, result = pcall(function()
        return self.client:get_binary(book.cover_url)
    end)
    if not ok or type(result) ~= "string" then
        logger.warn("cover download failed:", tostring(result))
        cb(nil)
        return
    end
    local ext = sniff_ext(result)
    if not ext then
        logger.warn("cover has unknown format:", book.book_id)
        cb(nil)
        return
    end
    local path = self.covers_dir .. "/" .. md5(tostring(book.book_id)) .. ext
    local f = io.open(path, "wb")
    if not f then
        cb(nil)
        return
    end
    f:write(result)
    f:close()
    book.cover_path = path
    cb(path)
end

----------------------------------------------------------------
-- Book download (EPUB) pipeline.
--
-- The heavy lifting lives in the bundled weread.lib.downloader state
-- machine (copied verbatim from the weread plugin): it owns the progress
-- dialog, its cancel button, the standby guard and the per-chapter retry
-- logic. The bridge only adapts the desktop's shelf-book shape onto the
-- library book record the pipeline expects and maps raw errors onto
-- friendly Chinese messages.
----------------------------------------------------------------

-- Map a raw pipeline error onto a friendly Chinese message, or nil when
-- the downloader's own message is already adequate.
local function friendly_download_error(err)
    if type(err) ~= "string" then
        return nil
    end
    if err == "no_chapters_downloaded" then
        return "没有成功下载任何章节。\n本书可能需要购买或开通会员后才能阅读。"
    end
    if err:find("HTTP 401", 1, true) or err:find("HTTP 403", 1, true)
        or err:find("error_code=-201") then
        return "下载失败：登录已失效或没有该书的阅读权限，请重新扫码登录后再试。"
    end
    if err:find("timeout", 1, true) or err:find("connection", 1, true)
        or err:find("host not found", 1, true) or err:find("network", 1, true) then
        return "下载失败：网络连接异常，请检查网络后重试。"
    end
    return nil
end

-- Build the library-style book record the download pipeline expects from
-- a desktop shelf book, reusing the persisted record (cache_dir, reader
-- tokens) when the book was downloaded before.
function Bridge:_libBook(shelf_book)
    local book_id = tostring(shelf_book.book_id)
    local books = self.settings:get("books", {})
    local lib_book = type(books[book_id]) == "table" and books[book_id] or {}
    lib_book.book_id = book_id
    lib_book.title = lib_book.title or shelf_book.text
    lib_book.author = lib_book.author or shelf_book.authors
    lib_book.cover = shelf_book.cover_url or lib_book.cover
    return lib_book
end

function Bridge:_getDownloader()
    if self.downloader then
        return self.downloader
    end
    self.downloader = Downloader:new{
        client = self.client,
        settings = self.settings,
        -- In every failure path the downloader notifies on_complete first
        -- and then shows its own "下载失败：..." dialog. on_complete stashes
        -- the raw error in self._download_err so this wrapper can replace
        -- the technical detail with a friendly message, keeping a single
        -- error dialog.
        show_info = function(text)
            local err = self._download_err
            self._download_err = nil
            if err and type(text) == "string"
                and (text:find("^下载失败") or text:find("^Download failed")
                    or text:find("没有成功下载") or text:find("^No chapters")) then
                text = friendly_download_error(err) or text
            end
            self.host:showInfo(text)
        end,
        show_transient = function(text, timeout)
            self.host:showTransientInfo(text, timeout)
        end,
        refresh_ui = function()
            self.host:refreshUI()
        end,
        -- The desktop has no per-book download indicators; a plain data
        -- refresh is enough.
        refresh_shelf = function()
            if self.host.refreshDesktop then
                self.host:refreshDesktop()
            end
        end,
        open_file = function(path)
            self.host:openBookFile(path)
        end,
        safe_callback = function(_label, fn)
            return function(...)
                local ok, err = xpcall(fn, debug.traceback, ...)
                if not ok then
                    logger.err("download callback failed:", tostring(err))
                    self.host:showInfo("操作失败：" .. tostring(err))
                end
            end
        end,
        require_login = function(_cookie, _api_key)
            if self:isLoggedIn() then
                return true
            end
            self.host:showInfo("请先扫码登录微信读书")
            return false
        end,
        run_online_task = function(label, fn)
            return self.host:runOnlineTask(label, fn)
        end,
    }
    return self.downloader
end

-- Local EPUB path of a previously downloaded book, or nil.
function Bridge:isBookDownloaded(book_id)
    local books = self.settings:get("books", {})
    local record = books[tostring(book_id)]
    local path = type(record) == "table" and record.cached_file or nil
    if type(path) == "string" and path ~= ""
        and lfs.attributes(path, "mode") == "file" then
        return path
    end
    return nil
end

-- Load the chapter catalog for a shelf book (disk cache first, then the
-- network). Blocking; cb(chapters|nil, err). On success the resolved
-- library book record is kept around for the following downloadBook call.
function Bridge:fetchChapterList(shelf_book, force_refresh, cb)
    local lib_book = self:_libBook(shelf_book)
    if not force_refresh then
        local cached = Content.load_catalog_cache(self.client, self.settings, lib_book)
        if type(cached) == "table" and #cached > 0 then
            self._pending_book = lib_book
            cb(cached)
            return
        end
    end
    local ok, result = pcall(function()
        Content.ensure_reader_state(self.client, lib_book)
        return Content.fetch_catalog(self.client, lib_book)
    end)
    if not ok then
        logger.err("fetch chapter list failed:", tostring(result))
        cb(nil, tostring(result))
        return
    end
    local cache_ok, cache_err = Content.save_catalog_cache(
        self.client, self.settings, lib_book, result)
    if not cache_ok then
        logger.warn("save chapter catalog cache failed:", tostring(cache_err))
    end
    self._pending_book = lib_book
    cb(result)
end

-- Download the whole book as one EPUB and open it on completion. Progress
-- and cancellation are handled by the downloader's own dialog; cancelling
-- leaves no partial files behind (chapters are kept in memory until the
-- final EPUB is written). cb(epub_path|nil, err) is optional and fires
-- once after the pipeline's own UI has been taken care of.
-- opts.fill_missing: only download chapters missing from the parts cache
--   and repack (chapters must be the full catalog).
-- opts.open_on_complete: override the auto-open (default true).
function Bridge:downloadBook(shelf_book, chapters, cb, opts)
    opts = opts or {}
    local book_id = tostring(shelf_book.book_id)
    local lib_book = self._pending_book
    if type(lib_book) ~= "table" or lib_book.book_id ~= book_id then
        lib_book = self:_libBook(shelf_book)
    end
    self._pending_book = nil
    if type(chapters) == "table" then
        lib_book.chapters = chapters
    end
    chapters = type(chapters) == "table" and chapters or lib_book.chapters or {}
    local downloader = self:_getDownloader()
    return downloader:start(lib_book, chapters, "full", {
        fill_missing = opts.fill_missing == true,
        open_on_complete = opts.open_on_complete ~= false,
        on_complete = function(ok, value)
            if ok then
                self._download_err = nil
                if cb then
                    pcall(cb, value)
                end
                return
            end
            if value == "authentication_required"
                or value == "offline" or value == "cancelled" then
                -- require_login / runOnlineTask / the downloader already
                -- surfaced these; no extra dialog here.
            else
                self._download_err = value
            end
            if cb then
                pcall(cb, nil, value)
            end
        end,
    })
end

return Bridge
