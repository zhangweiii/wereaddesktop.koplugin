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
local Storage = require("weread.lib.storage")
local WeRead = require("weread.lib.protocol")
local logger = require("weread.lib.logger").scoped("Bridge")

local Bridge = {}
Bridge.__index = Bridge

local SHELF_CACHE_KEY = "wereaddesktop_shelf"
local SHELF_OWNER_KEY = "wereaddesktop_shelf_user_vid"
-- Shelf cache key used before the plugin was renamed; migrated on read.
local LEGACY_SHELF_CACHE_KEY = "kodesktop_shelf"
local SHELF_FETCHED_AT_KEY = "wereaddesktop_shelf_fetched_at"
local BACKGROUND_SHELF_TTL = 5 * 60
local COVER_EXTS = { ".jpg", ".png", ".webp", ".gif" }

local function settings_user_vid(settings)
    local account = settings:get("account", {})
    if type(account) == "table" and account.user_vid ~= nil then
        return tostring(account.user_vid)
    end
    return ""
end

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
    -- Move pre-rename cover storage once. os.rename refuses to replace a
    -- non-empty directory, so only attempt it when the target is absent;
    -- otherwise the legacy directory would linger forever, silently
    -- (review.md #17).
    local legacy_dir = data_dir .. "/kodesktop"
    local new_dir = data_dir .. "/wereaddesktop"
    local function rename_legacy()
        local called, renamed, rename_err = pcall(os.rename,
            legacy_dir, new_dir)
        if not called or not renamed then
            logger.warn("legacy cache migration failed:",
                tostring(called and rename_err or renamed))
            return false
        end
        return true
    end
    if lfs.attributes(legacy_dir, "mode") == "directory" then
        if lfs.attributes(new_dir, "mode") ~= "directory" then
            rename_legacy()
        else
            -- A previous run may have created the new directory while it
            -- was still empty; replace it so the legacy covers are not
            -- orphaned forever. A non-empty target is kept (it already
            -- holds real data; prefer the newer layout).
            local empty = false
            local opened, iterator, dir_state = pcall(lfs.dir, new_dir)
            if opened and type(iterator) == "function" then
                empty = true
                for name in iterator, dir_state do
                    if name ~= "." and name ~= ".." then
                        empty = false
                        break
                    end
                end
            else
                logger.warn("cache target inspection failed:",
                    tostring(iterator))
            end
            if empty then
                local removed, remove_result, remove_err = pcall(
                    os.remove, new_dir)
                if removed and remove_result then
                    rename_legacy()
                else
                    logger.warn("empty cache target removal failed:",
                        tostring(removed and remove_err or remove_result))
                end
            else
                logger.warn("legacy cache kept because target is non-empty:",
                    legacy_dir)
            end
        end
    end
    local covers_dir = new_dir .. "/covers"
    ensure_dir(new_dir)
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
    -- Only one QR flow may own the authentication callback. Without this,
    -- the older flow can finish after logout or a second scan and restore
    -- credentials the user no longer intended to use.
    if self.qr_login then
        self.qr_login:cancel()
        self.qr_login = nil
    end
    local qr = QRLogin:new(self.host, self.client, self.settings)
    self.qr_login = qr
    if on_done then
        local fired = false
        local function fire(ok, err)
            if not fired then
                fired = true
                if self.qr_login == qr then
                    self.qr_login = nil
                end
                on_done(ok, err)
            end
        end
        -- Success persists credentials via settings:update_auth; shadow the
        -- method on this instance to hook that moment. The shadow is
        -- restored from *every* exit path (success or cancel) and only when
        -- it is still the installed one, so a failed or cancelled login can
        -- never leave a stale hook that later fires on unrelated
        -- update_auth calls (e.g. cookie renewal) (review.md #3).
        local settings = self.settings
        local orig_update_auth = settings.update_auth
        local previous_vid = settings_user_vid(settings)
        local patched
        patched = function(s, credentials, options)
            if settings.update_auth == patched then
                settings.update_auth = orig_update_auth
            end
            local result = orig_update_auth(s, credentials, options)
            local current_vid = settings_user_vid(settings)
            if current_vid ~= previous_vid then
                settings:set(SHELF_CACHE_KEY, nil)
                settings:set(SHELF_OWNER_KEY, nil)
                settings:set(SHELF_FETCHED_AT_KEY, nil)
                settings:set(LEGACY_SHELF_CACHE_KEY, nil)
                settings:flush()
                self:invalidateStorageSummary()
            end
            -- Only report success while the flow is still active: an
            -- offline start or an initial-protocol failure ends the flow
            -- inside QRLogin:start() (before the cancel wrapper below is
            -- installed), so the shadow stays installed until the next
            -- update_auth call — it must never fire the callback then
            -- (review.md #3).
            if qr.flow_active then
                fire(true)
            end
            return result
        end
        settings.update_auth = patched
        -- Every abort path (user dismiss, expiry, protocol error) ends in
        -- cancel(). start() also calls cancel() once up front, synchronously,
        -- so the wrapper suppresses finalization only during that initial
        -- reset while remaining installed for every real exit path.
        local starting = true
        local orig_cancel = qr.cancel
        qr.cancel = function(qr_self)
            if not starting and settings.update_auth == patched then
                settings.update_auth = orig_update_auth
            end
            orig_cancel(qr_self)
            if not starting then
                fire(false, "登录失败或已取消")
            end
        end
        local start_ok, start_err = pcall(qr.start, qr)
        starting = false
        -- Offline start fails synchronously, before any later cancel callback
        -- can run. Finalize it here so the shadow method and on_done contract
        -- are both restored immediately.
        if not start_ok or not qr.flow_active then
            if settings.update_auth == patched then
                settings.update_auth = orig_update_auth
            end
            if not start_ok then
                pcall(orig_cancel, qr)
                logger.warn("QR login start failed:", tostring(start_err))
            end
            fire(false, start_ok and "登录失败或已取消" or tostring(start_err))
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
    self.settings:set(SHELF_OWNER_KEY, nil)
    self.settings:set(SHELF_FETCHED_AT_KEY, nil)
    self.settings:set(LEGACY_SHELF_CACHE_KEY, nil)
    self.settings:flush()
    self:invalidateStorageSummary()
end

-- Books cached from the last successful fetch (usable offline), or nil.
-- Refreshed from disk first: the reader-context instance may have
-- written progress updates (updateShelfProgress) through its own
-- in-memory view since this instance last loaded the file.
function Bridge:getCachedShelf()
    self.settings:refresh(SHELF_CACHE_KEY)
    self.settings:refresh(SHELF_OWNER_KEY)
    local cached = self.settings:get(SHELF_CACHE_KEY, nil)
    local current_vid = settings_user_vid(self.settings)
    local cached_vid = tostring(self.settings:get(SHELF_OWNER_KEY, "") or "")
    if cached == nil then
        cached = self.settings:get(LEGACY_SHELF_CACHE_KEY, nil)
        if cached ~= nil then
            self.settings:set(SHELF_CACHE_KEY, cached)
            self.settings:set(SHELF_OWNER_KEY,
                current_vid ~= "" and current_vid or nil)
            self.settings:set(LEGACY_SHELF_CACHE_KEY, nil)
            self.settings:flush()
        end
    end
    if type(cached) == "table" and cached_vid == "" and current_vid ~= "" then
        -- One-time ownership migration for caches written before this key
        -- existed. The persisted account and shelf came from the same settings
        -- file, so binding them here preserves offline use after upgrade.
        cached_vid = current_vid
        self.settings:set(SHELF_OWNER_KEY, current_vid)
        self.settings:flush()
    end
    if current_vid == "" or cached_vid ~= current_vid then
        return nil
    end
    if type(cached) == "table" and #cached > 0 then
        return cached
    end
    return nil
end

-- Write back a shelf table mutated after fetching (e.g. cover_path).
function Bridge:saveShelf(books)
    local current_vid = settings_user_vid(self.settings)
    if current_vid == "" then
        return false
    end
    self.settings:set(SHELF_CACHE_KEY, books)
    self.settings:set(SHELF_OWNER_KEY, current_vid)
    self.settings:flush()
    return true
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

function Bridge:getStorageSummary()
    local now = os.time()
    if self.storage_summary and self.storage_summary_at
        and now - self.storage_summary_at < 10 then
        return self.storage_summary
    end
    self.storage_summary = Storage.summary(
        self.settings, self.settings:get("books", {}))
    self.storage_summary_at = now
    return self.storage_summary
end

function Bridge:invalidateStorageSummary()
    self.storage_summary = nil
    self.storage_summary_at = nil
    -- The pending-upload summary is derived from the same book records and
    -- is cached with the same short TTL; drop it alongside (review.md #11).
    self.pending_summary = nil
    self.pending_summary_at = nil
    self.pending_summary_vid = nil
end

-- Reuse the downloader's reference-counted KOReader + device standby guard
-- for other long background work such as paced reading-time replay.
function Bridge:acquireStandbyGuard()
    self:_getDownloader():_beginStandby()
end

function Bridge:releaseStandbyGuard()
    if self.downloader then
        self.downloader:_endStandby()
    end
end

function Bridge:getPendingUploadSummary()
    local now = os.time()
    local current_vid = settings_user_vid(self.settings)
    if self.pending_summary and self.pending_summary_at
        and self.pending_summary_vid == current_vid
        and now - self.pending_summary_at < 10 then
        return self.pending_summary
    end
    local count, time_count, elapsed, replay_chunks = 0, 0, 0, 0
    for _, book in pairs(self.settings:get("books", {})) do
        local pending_elapsed = type(book) == "table"
            and (math.max(0, tonumber(book.pending_upload_elapsed) or 0)
                + math.max(0, tonumber(book.pending_replay_elapsed) or 0)) or 0
        local book_vid = type(book) == "table"
            and tostring(book.pending_upload_user_vid or "") or ""
        -- Ignore pending data queued under another account (review.md #1):
        -- it is never uploaded, so it must not be shown as actionable.
        if type(book) == "table"
            and current_vid ~= "" and book_vid == current_vid
            and (type(book.pending_upload_position) == "table"
                or pending_elapsed > 0) then
            count = count + 1
            elapsed = elapsed + pending_elapsed
            if pending_elapsed > 0 then
                time_count = time_count + 1
                replay_chunks = replay_chunks + math.ceil(pending_elapsed / 60)
            end
        end
    end
    local summary = {
        count = count,
        time_count = time_count,
        elapsed = elapsed,
        replay_chunks = replay_chunks,
    }
    self.pending_summary = summary
    self.pending_summary_at = now
    self.pending_summary_vid = current_vid
    return summary
end

-- Discard only queued reading-time deltas. Keep the pending position so the
-- next automatic reconnect can still sync the user's latest reading place.
function Bridge:clearPendingUploadElapsed()
    local books = self.settings:get("books", {})
    local current_vid = settings_user_vid(self.settings)
    local count, elapsed = 0, 0
    for _, book in pairs(type(books) == "table" and books or {}) do
        local pending_elapsed = type(book) == "table"
            and (math.max(0, tonumber(book.pending_upload_elapsed) or 0)
                + math.max(0, tonumber(book.pending_replay_elapsed) or 0)) or 0
        local book_vid = type(book) == "table"
            and tostring(book.pending_upload_user_vid or "") or ""
        -- Only clear time belonging to the current account. Foreign and
        -- legacy-unowned data is hidden from the UI and must remain intact.
        if pending_elapsed > 0
            and current_vid ~= "" and book_vid == current_vid then
            count = count + 1
            elapsed = elapsed + pending_elapsed
            book.pending_upload_elapsed = nil
            book.pending_upload_started_at = nil
            book.pending_replay_elapsed = nil
            book.pending_replay_started_at = nil
            book.pending_upload_updated_at = os.time()
        end
    end
    if count > 0 then
        self.settings:set("books", books)
        self.settings:flush()
        self:invalidateStorageSummary()
    end
    return count, elapsed
end

-- Remove only the dedicated per-book cache directory, then remove its index
-- record. The confirmation dialog lives in main.lua; this method is the
-- storage seam used by both the desktop and future maintenance tools.
function Bridge:deleteBook(book_id)
    book_id = tostring(book_id or "")
    if book_id == "" then
        return false, "empty_book_id"
    end
    local book = self.settings:get_book(book_id)
    if type(book) ~= "table" then
        return false, "book_not_found"
    end
    local ok, err = Storage.remove_book(self.settings, book_id, book)
    if not ok then
        return false, err or "remove_cache_failed"
    end
    self.settings:remove_book(book_id)
    self.settings:flush()
    self:invalidateStorageSummary()
    return true
end

-- Fetch the shelf via the gateway and update the cache. Synchronous and
-- blocking; cb(books|nil, err). Without force_refresh a cached shelf is
-- returned straight away.
function Bridge:fetchShelf(force_refresh, cb)
    -- The account this fetch runs for; compared again right before the
    -- result is persisted so a mid-fetch account switch can never write
    -- one account's shelf into the other's cache (review.md #1 follow-up).
    local fetch_vid = settings_user_vid(self.settings)
    if fetch_vid == "" then
        cb(nil, "account_missing")
        return
    end
    local cached = self:getCachedShelf()
    if force_refresh == "background" and cached then
        local fetched_at = tonumber(self.settings:get(
            SHELF_FETCHED_AT_KEY, 0)) or 0
        if fetched_at > 0 and os.time() - fetched_at < BACKGROUND_SHELF_TTL then
            cb(cached)
            return
        end
    end
    if not force_refresh then
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
    -- A business error (HTTP 200 with an errcode payload, or a response
    -- without the books list) must not be mistaken for an empty shelf and
    -- persisted over the cached one (review.md #2).
    local shelf_err_code = type(result) == "table"
        and (result.errCode or result.errcode) or nil
    local shelf_failed_succ = type(result) == "table" and result.succ ~= nil
        and result.succ ~= true and tonumber(result.succ) ~= 1
    if type(result) ~= "table" or type(result.books) ~= "table"
        or (shelf_err_code ~= nil and tonumber(shelf_err_code) ~= 0)
        or shelf_failed_succ then
        logger.err("shelf sync rejected by server:",
            "error_code=", tostring(shelf_err_code or "missing_books"))
        cb(nil, "shelf_sync_business_error")
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
    -- Account switch during the fetch: discard instead of persisting this
    -- account's shelf under the new one.
    local current_account = self.settings:get("account", {})
    local current_vid = type(current_account) == "table"
        and tostring(current_account.user_vid or "") or ""
    if current_vid ~= fetch_vid then
        logger.warn("shelf fetch account changed, discarding result:",
            "fetch_vid=", fetch_vid, "current_vid=", current_vid)
        cb(nil, "account_changed")
        return
    end
    self.settings:set(SHELF_CACHE_KEY, books)
    self.settings:set(SHELF_OWNER_KEY, current_vid)
    self.settings:set(SHELF_FETCHED_AT_KEY, os.time())
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
    local vid = settings_user_vid(self.settings)
    return vid ~= "" and vid or nil
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
        -- Stream with a hard byte cap: an oversized cover aborts the
        -- transfer instead of being buffered whole (review.md #18/#5).
        return self.client:get_binary_limited(book.cover_url, 8 * 1024 * 1024)
    end)
    if not ok or type(result) ~= "string" then
        logger.warn("cover download failed:",
            "book_id=", tostring(book.book_id),
            "error=", tostring(ok and "size_limit_or_error" or result))
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
    local lib_book = self.settings:get_book(book_id) or {}
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
        show_overlay = function(widget, refresh_mode)
            if self.host.showOverlay then
                return self.host:showOverlay(widget, refresh_mode)
            end
            return nil
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
    local record = self.settings:get_book(book_id)
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
                self:invalidateStorageSummary()
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
