--[[--
Two-way WeRead reading-progress sync for the reader context.

Detects whether the document open in KOReader is a book downloaded from
WeRead (settings books[book_id].cached_file), maps the reader position
onto WeRead chapter coordinates (chapterUid/chapterIdx/chapterOffset)
with the bundled position mapper, and reports it to weread.qq.com
through Client:report_read(). The mapping prefers chapter coordinates:
the current page is located within the document TOC (one TOC entry per
downloaded chapter, both in catalog order) and the intra-chapter page
fraction is scaled by the chapter's word count. KOReader's whole-book
percent is page-based while WeRead positions are character-based, so
the plain fraction walk drifts badly on books with dialogue-heavy
chapters or images; the TOC path confines that error to one chapter.
The whole-book fraction walk remains as a fallback (no usable TOC).

The pull direction runs once per document open: the cloud position is
fetched (gateway + web endpoints, merged by PositionMapper.choose_remote)
and compared against the local position; when the cloud is ahead the
reader jumps forward. When the document TOC aligns with the chapter
catalog (always the case for full-book desktop downloads), comparison
and jump use chapter coordinates (chapterUid/chapterOffset, the same
units the official apps use) and TOC page numbers; otherwise it falls
back to whole-book fractions via remote_to_local. The pull always runs
before the initial upload, so a stale local position never overwrites
newer cloud progress.

Uploads are heartbeat-driven, not page-turn-driven: a timer fires every
HEARTBEAT_INTERVAL seconds while the document is open, reporting the
latest position and the active reading time not yet reported (rt).
Suspend intervals are excluded. The endpoint silently ignores rt values
above 60 despite returning succ=1, so longer backlogs are drained in
server-safe chunks over later reports.

All network calls are blocking (LuaSocket) and therefore always run
inside scheduler-deferred tasks; failures are logged and retried
silently, never surfaced to the user.
--]]--

local Content = require("weread.lib.content")
local PositionMapper = require("weread.lib.position_mapper")
local WeRead = require("weread.lib.protocol")
local logger = require("weread.lib.logger").scoped("ProgressUpload")

local ProgressUploader = {}
ProgressUploader.__index = ProgressUploader

-- Seconds between heartbeat uploads while reading, the delay before a
-- failed upload is retried, and how many retries one position gets.
local HEARTBEAT_INTERVAL = 30
local RETRY_DELAY = 30
local RETRY_LIMIT = 2
-- Verified against the live account: rt=62 and larger returned succ=1
-- but did not change read stats, while preceding rt=3 and rt=31 were
-- both credited. Never send more than 60 seconds in one report.
local RT_CAP = 60
-- Delay after the document is ready before the initial "reading" report.
local OPEN_REPORT_DELAY = 1
-- How far the cloud position must be ahead of the local one (whole-book
-- fraction) before the reader is jumped forward on open. Used only when
-- the chapter-coordinate path is unavailable.
local SYNC_AHEAD_THRESHOLD = 0.005
-- Chapter-coordinate path: the cloud must be at least this many
-- characters ahead within the same chapter to trigger a jump (chapter
-- offsets are character counts; ~100 chars is a few lines).
local OFFSET_AHEAD_THRESHOLD = 100

-- Mirror of the source plugin's response_accepted(): the web endpoint
-- answers 200 even for rejections, so the body decides.
local function response_accepted(result)
    if WeRead.is_success_response(result) then
        return true
    end
    if type(result) == "table" and result.synckey ~= nil then
        return true
    end
    return false
end

local function response_summary(result)
    if type(result) ~= "table" then
        return "type=" .. type(result) .. ",value=" .. tostring(result)
    end
    local parts = {}
    for _, key in ipairs({ "succ", "synckey", "errcode", "errCode" }) do
        if result[key] ~= nil then
            table.insert(parts, key .. "=" .. tostring(result[key]))
        end
    end
    local message = result.errmsg or result.errMsg or result.message
    if message ~= nil then
        message = tostring(message):gsub("[%c]+", " "):sub(1, 160)
        table.insert(parts, "message=" .. message)
    end
    return #parts > 0 and table.concat(parts, ",") or "table_without_status"
end

-- Persist one mutated book record (books are stored per-book via
-- BookStore, so the whole table has to round-trip through settings).
local function persist_book(settings, book)
    local books = settings:get("books", {})
    books[tostring(book.book_id)] = book
    settings:set("books", books)
    settings:flush()
end

function ProgressUploader:new(options)
    options = options or {}
    assert(options.settings, "progress uploader settings are required")
    assert(options.client, "progress uploader client is required")
    assert(options.scheduler, "progress uploader scheduler is required")
    -- Seconds between heartbeat uploads; tests disable the timer by
    -- passing false (an and/or chain would turn false back into the
    -- default, so spell it out).
    local heartbeat_interval = HEARTBEAT_INTERVAL
    if options.heartbeat_interval ~= nil then
        heartbeat_interval = options.heartbeat_interval
    end
    return setmetatable({
        settings = options.settings,
        client = options.client,
        scheduler = options.scheduler,
        -- Returns the current reading position as a 0..1 fraction.
        get_fraction = options.get_fraction,
        -- Chapter-coordinate mapping (preferred over the fraction): the
        -- current 1-based page, the total page count and the document
        -- TOC as a list of { page = n } in document order. Any of them
        -- may be nil/unavailable; the fraction path is the fallback.
        get_page = options.get_page,
        get_page_count = options.get_page_count,
        get_toc = options.get_toc,
        -- Non-blocking link-state check; defaults to "assume online".
        is_online = options.is_online or function() return true end,
        -- Optional hook fired after a successful upload (used to refresh
        -- the desktop shelf cache).
        on_uploaded = options.on_uploaded,
        -- Optional hook fired on open when the cloud position is ahead of
        -- the local one: (fraction, remote). Should jump the reader to
        -- the fraction; runs synchronously inside a scheduled task.
        on_sync_to = options.on_sync_to,
        -- Like on_sync_to, but with a 1-based page number; preferred
        -- whenever the chapter-coordinate path resolved the jump target.
        on_sync_to_page = options.on_sync_to_page,
        now = options.now or os.time,
        heartbeat_interval = heartbeat_interval,
        generation = 0,
    }, self)
end

-- Internal cumulative active time for the current document session.
-- Payload rt is derived from the unreported portion of this value.
-- Exclude both completed and currently-active suspend intervals.
function ProgressUploader:_readingElapsed(at)
    -- Freeze the clock once CloseDocument arrives. A retry may run 30 seconds
    -- later, but that wait is no longer active reading time.
    local current = tonumber(at or self.closed_at or self.now()) or 0
    local opened = tonumber(self.opened_at) or current
    local paused = tonumber(self.paused_seconds) or 0
    if self.paused_at then
        paused = paused + math.max(0,
            current - (tonumber(self.paused_at) or current))
    end
    return math.floor(math.max(0, current - opened - paused))
end

-- Active seconds not yet covered by a successfully accepted report.
-- This is intentionally separate from wall-clock time so suspend gaps
-- stay excluded and failed/offline reports can be caught up later.
function ProgressUploader:_unreportedElapsed(at)
    return math.max(0, self:_readingElapsed(at)
        - (tonumber(self.last_reported_rt) or 0))
end

-- book_id of the WeRead download matching an open file path, or nil.
function ProgressUploader:detectBook(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        if type(book) == "table" and type(book.cached_file) == "string"
            and book.cached_file == path then
            return book_id
        end
    end
    -- Fall back to the download root layout <cache_dir>/<book_id>/...
    local prefix = (self.settings.cache_dir or ""):gsub("/+$", "") .. "/"
    if #prefix > 1 and path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1):match("^([^/]+)")
    end
    return nil
end

-- Reset per-document state and detect the newly opened document.
-- Returns the detected book_id (nil for non-WeRead books).
function ProgressUploader:onReaderReady(path)
    self.generation = self.generation + 1
    self.book_id = nil
    self.book = nil
    self.chapters = nil
    self.dirty = false
    self.uploading = false
    self.entered = false
    self.last_position = nil
    self.last_uploaded = nil
    self.last_upload_at = nil
    -- Cumulative active seconds already covered by accepted delta
    -- reports; despite the legacy name, this is not the last rt payload.
    self.last_reported_rt = 0
    self.closing = false
    self.close_position = nil
    self.closed_at = nil
    self.paused_at = nil
    self.paused_seconds = 0
    self._toc_aligned_source = nil
    self._toc_aligned = nil
    self.opened_at = self.now()
    local book_id = self:detectBook(path)
    if not book_id or WeRead.is_mp_book(book_id) then
        logger.dbg("reader open ignored:", "path=", tostring(path),
            "detected_book=", tostring(book_id))
        return nil
    end
    self.book_id = tostring(book_id)
    logger.info("reading session opened:", "book=", self.book_id,
        "generation=", tostring(self.generation),
        "heartbeat_s=", tostring(self.heartbeat_interval))
    -- Pull-then-upload on open: fetch the cloud position first (jumping
    -- forward when it is ahead), then report the resulting position, so a
    -- stale local position never overwrites newer cloud progress.
    local generation = self.generation
    self.scheduler:scheduleIn(OPEN_REPORT_DELAY, function()
        if generation ~= self.generation or not self.book_id then
            return
        end
        self:_pullFromCloud()
        local fraction = self.get_fraction and self.get_fraction()
        local position = fraction and self:capture(fraction)
        if position then
            self.last_position = position
            self.dirty = true
            self:_upload(position, "document_open")
        end
    end)
    -- A 30-second cadence normally keeps each active-time delta below
    -- the endpoint's 60-second acceptance limit.
    if self.heartbeat_interval then
        self.scheduler:scheduleIn(self.heartbeat_interval, function()
            self:_heartbeat(generation)
        end)
    end
    return self.book_id
end

-- One heartbeat tick: upload the current position (page turns only
-- record it; the timer is what reports position and reading time), then
-- re-arm. Stops when the document changes.
function ProgressUploader:_heartbeat(generation)
    if generation ~= self.generation or not self.book_id or self.closing then
        logger.dbg("heartbeat stopped:", "scheduled_generation=", tostring(generation),
            "current_generation=", tostring(self.generation),
            "book=", tostring(self.book_id),
            "closing=", tostring(self.closing == true))
        return
    end
    local fraction = self.get_fraction and self.get_fraction()
    local position = fraction and self:capture(fraction)
    if position then
        self.last_position = position
        self.dirty = true
        self:_upload(position, "heartbeat")
    else
        logger.warn("heartbeat skipped: position unavailable:",
            "book=", tostring(self.book_id),
            "fraction=", tostring(fraction))
    end
    if self.heartbeat_interval then
        self.scheduler:scheduleIn(self.heartbeat_interval, function()
            self:_heartbeat(generation)
        end)
    end
end

-- Reader/device suspend and resume events delimit time that must not be
-- counted as active reading. Calls are idempotent because KOReader may
-- deliver more than one lifecycle notification around a sleep cycle.
function ProgressUploader:onSuspend()
    if not self.book_id or self.paused_at then
        return
    end
    self.paused_at = self.now()
    logger.info("reading session paused:", "book=", tostring(self.book_id),
        "active_total_s=", tostring(self:_readingElapsed(self.paused_at)),
        "reported_total_s=", tostring(self.last_reported_rt))
end

function ProgressUploader:onResume()
    if not self.paused_at then
        return
    end
    local resumed_at = self.now()
    local paused_for = math.max(0,
        resumed_at - (tonumber(self.paused_at) or resumed_at))
    self.paused_seconds = (tonumber(self.paused_seconds) or 0) + paused_for
    self.paused_at = nil
    logger.info("reading session resumed:", "book=", tostring(self.book_id),
        "paused_s=", tostring(paused_for),
        "paused_total_s=", tostring(self.paused_seconds),
        "active_total_s=", tostring(self:_readingElapsed(resumed_at)),
        "reported_total_s=", tostring(self.last_reported_rt))
end

-- Fetch the cloud position of the open book and jump forward when it is
-- ahead of the local position. Runs inside a scheduled task (blocking
-- network); any failure just skips the pull.
function ProgressUploader:_pullFromCloud()
    if not self.is_online() or not self:_ensureContext() then
        return
    end
    local remote = self:_fetchRemote()
    if not remote then
        return
    end
    if self:_pullChapterPath(remote) then
        return
    end
    local target = PositionMapper.remote_to_local(self.chapters, remote, {
        is_full_book = true,
    })
    if not target or not target.fraction then
        return
    end
    local local_fraction = (self.get_fraction and self.get_fraction()) or 0
    if target.fraction - local_fraction < SYNC_AHEAD_THRESHOLD then
        return
    end
    logger.info("cloud progress ahead: book=", self.book_id,
        "cloud=", tostring(target.fraction),
        "local=", tostring(local_fraction))
    if self.on_sync_to then
        local ok, err = pcall(self.on_sync_to, target.fraction, remote)
        if not ok then
            logger.warn("sync-to-cloud-position failed:", tostring(err))
        end
    end
end

-- Chapter-coordinate pull: when the TOC aligns with the chapter catalog
-- and the cloud position carries chapter coordinates, compare chapter
-- order + offset directly (the fraction comparison below would mix
-- page-based local coordinates with word-based cloud ones) and jump by
-- page number. Returns true when the decision was made here (jumped or
-- deliberately stayed), false to fall back to the fraction comparison.
function ProgressUploader:_pullChapterPath(remote)
    local aligned = self:_tocChapters()
    if not aligned or remote.chapter_uid == nil then
        return false
    end
    -- Catalog order of a chapter uid (comparison key; the catalog and
    -- the TOC are both in book order).
    local order = {}
    for i, chapter in ipairs(self.chapters) do
        local uid = chapter.chapterUid or chapter.chapter_uid or chapter.chapterId
        if uid ~= nil then
            order[tostring(uid)] = i
        end
    end
    local remote_order = order[tostring(remote.chapter_uid)]
    if not remote_order then
        return false
    end
    local current = self:_captureByChapter()
    if not current then
        return false
    end
    local current_order = order[tostring(current.chapter_uid)] or 0
    local remote_offset = tonumber(remote.chapter_offset) or 0
    local current_offset = tonumber(current.chapter_offset) or 0
    local ahead = remote_order > current_order
        or (remote_order == current_order
            and remote_offset - current_offset > OFFSET_AHEAD_THRESHOLD)
    if not ahead then
        return true
    end
    if not self.on_sync_to_page then
        return false
    end
    for k, entry in ipairs(aligned) do
        local chapter = entry.chapter
        local uid = chapter.chapterUid or chapter.chapter_uid or chapter.chapterId
        if uid ~= nil and tostring(uid) == tostring(remote.chapter_uid) then
            local words = tonumber(chapter.wordCount or chapter.word_count) or 0
            local chapter_fraction = words > 0
                and math.max(0, math.min(1, remote_offset / words)) or 0
            local start_page = entry.page
            local page_count = self.get_page_count and self.get_page_count()
            local end_page = (aligned[k + 1] and aligned[k + 1].page)
                or ((page_count or start_page) + 1)
            local span = math.max(1, end_page - start_page)
            local page = math.floor(start_page + chapter_fraction * span + 0.5)
            logger.info("cloud progress ahead: book=", self.book_id,
                "chapter=", tostring(remote.chapter_uid),
                "offset=", tostring(remote_offset), "-> page=", tostring(page))
            local ok, err = pcall(self.on_sync_to_page, page, remote)
            if not ok then
                logger.warn("sync-to-cloud-page failed:", tostring(err))
            end
            return true
        end
    end
    -- The cloud chapter is not part of the downloaded EPUB (e.g. its
    -- download failed): let the fraction path approximate the jump.
    return false
end

-- Merge the gateway and web progress endpoints into one remote position
-- (normalize_remote maps both response shapes onto the same record).
-- Returns nil when neither endpoint answers with a usable position.
function ProgressUploader:_fetchRemote()
    local gateway, web
    if type(self.client.get_progress) == "function" then
        local ok, result = pcall(self.client.get_progress, self.client,
            self.book_id)
        if ok and result ~= nil then
            gateway = PositionMapper.normalize_remote(
                result, self.book_id, "gateway", self.chapters)
        end
    end
    if type(self.client.get_web_progress) == "function" then
        local ok, result = pcall(self.client.get_web_progress, self.client,
            self.book_id)
        if ok and result ~= nil then
            web = PositionMapper.normalize_remote(
                result, self.book_id, "web", self.chapters)
        end
    end
    return PositionMapper.choose_remote(web, gateway)
end

-- Load the persisted book record and its chapter catalog (the record
-- carries the chapters after a full download; the catalog cache on disk
-- is the fallback). Returns false when positions cannot be mapped.
function ProgressUploader:_ensureContext()
    if self.book and self.chapters then
        return true
    end
    if not self.book_id then
        return false
    end
    local book = self.settings:get("books", {})[self.book_id]
    if type(book) ~= "table" then
        return false
    end
    local chapters = book.chapters
    if type(chapters) ~= "table" or #chapters == 0 then
        chapters = Content.load_catalog_cache(self.client, self.settings, book)
    end
    if type(chapters) ~= "table" or #chapters == 0 then
        logger.warn("no chapter catalog for book:", self.book_id)
        return false
    end
    self.book = book
    self.chapters = chapters
    return true
end

-- Align the document TOC with the book's chapter catalog. The desktop
-- download packs one XHTML file per downloaded chapter and emits one
-- TOC entry per file, both in catalog order, so toc[k] pairs with the
-- k-th downloaded chapter; when some chapters failed to download, the
-- persisted cached_chapters map identifies the downloaded subset.
-- Returns a list of { page = n, chapter = <catalog entry> } in document
-- order, or nil when the TOC cannot be aligned — callers then fall back
-- to the whole-book word-count walk.
function ProgressUploader:_tocChapters()
    if not self.get_toc or not self.chapters then
        return nil
    end
    local toc = self.get_toc()
    if type(toc) ~= "table" or #toc == 0 then
        return nil
    end
    -- TOC page numbers shift when the layout changes (font size etc.);
    -- memoize only on table identity so a rebuilt TOC is picked up.
    if self._toc_aligned_source == toc then
        return self._toc_aligned
    end
    local aligned
    local function pair(list)
        if #list ~= #toc then
            return nil
        end
        local result = {}
        for i, entry in ipairs(toc) do
            local page = tonumber(type(entry) == "table" and entry.page or entry)
            if not page then
                return nil
            end
            result[i] = { page = page, chapter = list[i] }
        end
        return result
    end
    aligned = pair(self.chapters)
    if not aligned and type(self.book) == "table"
        and type(self.book.cached_chapters) == "table" then
        local selected = {}
        for _, chapter in ipairs(self.chapters) do
            local uid = chapter.chapterUid or chapter.chapter_uid or chapter.chapterId
            if uid ~= nil and self.book.cached_chapters[tostring(uid)] ~= nil then
                table.insert(selected, chapter)
            end
        end
        aligned = pair(selected)
    end
    self._toc_aligned_source = toc
    self._toc_aligned = aligned
    return aligned
end

-- Current position via the chapter-coordinate path: locate the current
-- page within the TOC chapter boundaries, compute the intra-chapter
-- fraction from rendered pages, and map that onto the chapter's word
-- count. Unlike the whole-book word-count walk, this cannot pick the
-- wrong chapter and confines the pages-per-character density error to
-- a single chapter. Returns nil when unavailable (caller falls back).
function ProgressUploader:_captureByChapter()
    local aligned = self:_tocChapters()
    local page = self.get_page and self.get_page()
    if not aligned or not page then
        return nil
    end
    local index
    for i, entry in ipairs(aligned) do
        if entry.page <= page then
            index = i
        else
            break
        end
    end
    -- Before the first TOC entry (e.g. the cover page): chapter 1, 0%.
    index = index or 1
    local start_page = aligned[index].page
    local page_count = self.get_page_count and self.get_page_count()
    local end_page = (aligned[index + 1] and aligned[index + 1].page)
        or ((page_count or page) + 1)
    local span = end_page - start_page
    local intra = 0
    if page > start_page and span > 0 then
        intra = math.min(1, (page - start_page) / span)
    end
    local chapter = aligned[index].chapter
    return PositionMapper.local_to_remote(self.chapters, intra, {
        is_full_book = false,
        current_chapter_uid = chapter.chapterUid
            or chapter.chapter_uid or chapter.chapterId,
        summary = self.book.summary or self.book.title or "",
    })
end

-- Map the current reader position onto WeRead chapter coordinates. The
-- chapter-coordinate path (TOC + page) is tried first; the fallback is
-- the whole-book word-count walk of the source plugin over the given
-- fraction, which assumes a uniform pages-per-character density across
-- the book and can land in the wrong chapter (or far off the real
-- chapter offset) for books with dialogue-heavy chapters or images.
function ProgressUploader:capture(fraction)
    if not self:_ensureContext() then
        return nil
    end
    local position = self:_captureByChapter()
    if not position then
        if not fraction then
            return nil
        end
        position = PositionMapper.local_to_remote(self.chapters, fraction, {
            is_full_book = true,
            summary = self.book.summary or self.book.title or "",
        })
    end
    if not position then
        return nil
    end
    position.book_id = self.book_id
    return position
end

-- ReaderUI PageUpdate/PosUpdate event: record the latest position. The
-- heartbeat timer is what uploads — page turns never trigger network
-- traffic themselves.
function ProgressUploader:onPageUpdate(fraction)
    if not self.book_id or self.closing or not fraction then
        return
    end
    local position = self:capture(fraction)
    if not position then
        return
    end
    if self.last_position
        and PositionMapper.same_position(position, self.last_position) then
        return
    end
    self.last_position = position
    self.dirty = true
end

-- Clear state after the final close upload has either succeeded or exhausted
-- its retry chain. The generation guard prevents an old session from clearing
-- a newly opened document.
function ProgressUploader:_finishClose(generation)
    if generation ~= self.generation or not self.closing then
        return
    end
    local unreported = self:_unreportedElapsed()
    logger.info("reading session closed:", "book=", tostring(self.book_id),
        "reported_total_s=", tostring(self.last_reported_rt or 0),
        "unreported_s=", tostring(unreported))
    self.generation = self.generation + 1
    self.book_id = nil
    self.book = nil
    self.chapters = nil
    self.dirty = false
    self.uploading = false
    self.entered = false
    self.last_position = nil
    self.last_uploaded = nil
    self.paused_at = nil
    self.paused_seconds = 0
    self.last_reported_rt = nil
    self.closing = false
    self.close_position = nil
    self.closed_at = nil
end

-- ReaderUI CloseDocument event: freeze active time, stop heartbeats and keep
-- the session alive until the final upload (including retries) completes.
function ProgressUploader:onCloseDocument(fraction)
    if not self.book_id or self.closing then
        return
    end
    self.closed_at = self.now()
    self.closing = true
    local position = (fraction and self:capture(fraction))
        or self.last_position
    self.close_position = position
    local elapsed = self:_readingElapsed()
    local unreported = self:_unreportedElapsed()
    logger.info("reading session closing:", "book=", tostring(self.book_id),
        "dirty=", tostring(self.dirty),
        "uploading=", tostring(self.uploading == true),
        "active_total_s=", tostring(elapsed),
        "reported_total_s=", tostring(self.last_reported_rt),
        "unreported_s=", tostring(unreported),
        "position=", tostring(position ~= nil))
    local generation = self.generation
    if self.uploading then
        logger.info("close upload queued behind active upload:",
            "book=", tostring(self.book_id))
        return
    end
    if not position or (not self.dirty and unreported <= 0) then
        self:_finishClose(generation)
        return
    end
    if not self:_upload(position, "document_close") then
        logger.warn("reading session closed without final upload:",
            "book=", tostring(self.book_id),
            "unreported_s=", tostring(unreported))
        self:_finishClose(generation)
    end
end

-- Schedule one upload attempt chain for a captured position. The
-- `uploading` flag stays set across retries so page ticks cannot start
-- a parallel send; it is cleared on success, on final failure and when
-- the document changes underneath a scheduled task.
function ProgressUploader:_upload(position, reason, attempt)
    if not position then
        logger.warn("upload skipped:", "reason=", tostring(reason),
            "cause=position_missing")
        return false
    end
    if self.uploading then
        logger.info("upload skipped:", "book=", tostring(position.book_id),
            "reason=", tostring(reason), "cause=upload_busy")
        return false
    end
    if not self.is_online() then
        -- Offline: keep the position dirty; the next heartbeat or the
        -- document close will try again.
        logger.info("upload deferred:", "book=", tostring(position.book_id),
            "reason=", tostring(reason), "cause=offline")
        return false
    end
    attempt = attempt or 1
    self.uploading = true
    logger.info("upload scheduled:", "book=", tostring(position.book_id),
        "reason=", tostring(reason), "attempt=", tostring(attempt),
        "percent=", tostring(position.percent))
    local generation = self.generation
    self.scheduler:scheduleIn(0.1, function()
        if generation ~= self.generation then
            return
        end
        local active_total = self:_readingElapsed()
        local unreported = self:_unreportedElapsed()
        local elapsed = math.min(RT_CAP, unreported)
        logger.info("upload sending:", "book=", tostring(position.book_id),
            "reason=", tostring(reason), "attempt=", tostring(attempt),
            "rt=", tostring(elapsed),
            "active_total_s=", tostring(active_total),
            "reported_total_s=", tostring(self.last_reported_rt or 0),
            "backlog_after_s=", tostring(math.max(0, unreported - elapsed)),
            "paused_s=", tostring(self.paused_seconds or 0),
            "percent=", tostring(position.percent))
        local ok, err = pcall(function()
            return self:_send(position, elapsed, reason, attempt)
        end)
        if generation ~= self.generation then
            return
        end
        if ok and not err then
            self.uploading = false
            self.dirty = false
            self.last_upload_at = self.now()
            self.last_reported_rt =
                (tonumber(self.last_reported_rt) or 0) + elapsed
            self.last_uploaded = position
            logger.info("progress uploaded: book=", tostring(position.book_id),
                "percent=", tostring(position.percent), "reason=", reason,
                "attempt=", tostring(attempt), "rt=", tostring(elapsed),
                "reported_total_s=", tostring(self.last_reported_rt))
            self:_persist(position)
            if self.on_uploaded then
                pcall(self.on_uploaded, position.book_id, position)
            end
            if self.closing then
                local final_position = self.close_position or position
                local position_pending = final_position
                    and not PositionMapper.same_position(final_position, position)
                local time_pending = self:_unreportedElapsed() > 0
                if position_pending or time_pending then
                    if self:_upload(final_position, "document_close") then
                        return
                    end
                end
                self:_finishClose(generation)
            end
            return
        end
        logger.warn("progress upload failed:", "book=", tostring(position.book_id),
            "reason=", tostring(reason), "attempt=", tostring(attempt),
            "rt=", tostring(elapsed), "error=", tostring(err))
        if attempt <= RETRY_LIMIT then
            self.scheduler:scheduleIn(RETRY_DELAY, function()
                if generation ~= self.generation then
                    return
                end
                self.uploading = false
                self:_upload(position, "retry", attempt + 1)
            end)
        else
            self.uploading = false
            if self.closing then
                self:_finishClose(generation)
            end
        end
    end)
    return true
end

-- Blocking network part (runs inside a scheduled task): send the
-- enter-read report once per document, then the read report. When the
-- stored web-session tokens are rejected, refresh the reader state once
-- and retry before giving up. Returns nil on success, error otherwise.
function ProgressUploader:_send(position, elapsed, reason, attempt)
    local book_id = position.book_id
    local book = self.settings:get("books", {})[tostring(book_id)]
    if type(book) ~= "table" then
        return "book_record_missing"
    end
    if book.pclts == nil or book.pclts == "" or tonumber(book.pclts) == 0 then
        -- Persist right away: _persist() later re-reads the books table,
        -- so an in-memory-only mutation would be lost and pclts would be
        -- regenerated on every upload.
        book.pclts = WeRead.e(self.now())
        persist_book(self.settings, book)
    end
    local referer = book.reader_url or WeRead.reader_url(book_id)

    if not self.entered then
        local enter_result = self.client:report_read(WeRead.make_enter_read_payload{
            book_id = book_id,
            chapter_uid = position.chapter_uid or book.chapter_uid,
            chapter_idx = tonumber(position.chapter_idx) or 0,
            chapter_offset = tonumber(position.chapter_offset) or 0,
            progress = tonumber(position.percent) or 0,
            summary = position.summary or "",
            app_id = book.app_id or WeRead.web_app_id(),
            psvts = book.psvts,
            pclts = book.pclts,
        }, referer)
        logger.info("enter-read response:", "book=", tostring(book_id),
            "result=", response_summary(enter_result))
        self.entered = true
    end

    local function send_read()
        return self.client:report_read(WeRead.make_read_payload{
            book_id = book_id,
            chapter_uid = position.chapter_uid or book.chapter_uid,
            chapter_idx = tonumber(position.chapter_idx) or 0,
            chapter_offset = tonumber(position.chapter_offset) or 0,
            progress = tonumber(position.percent) or tonumber(book.progress) or 0,
            summary = position.summary or book.summary or "",
            elapsed_seconds = elapsed,
            app_id = book.app_id or WeRead.web_app_id(),
            psvts = book.psvts,
            pclts = book.pclts,
            token = book.token,
        }, referer)
    end

    local result = send_read()
    local accepted = response_accepted(result)
    logger.info("read response:", "book=", tostring(book_id),
        "reason=", tostring(reason), "attempt=", tostring(attempt),
        "rt=", tostring(elapsed), "accepted=", tostring(accepted),
        "result=", response_summary(result))
    if accepted then
        return nil
    end
    -- The stored psvts/pclts belong to the download-time web session and
    -- may have expired: reopen the reader page once and retry.
    Content.ensure_reader_state(self.client, book)
    persist_book(self.settings, book)
    result = send_read()
    accepted = response_accepted(result)
    logger.info("read response after state refresh:",
        "book=", tostring(book_id), "reason=", tostring(reason),
        "attempt=", tostring(attempt), "rt=", tostring(elapsed),
        "accepted=", tostring(accepted),
        "result=", response_summary(result))
    if accepted then
        return nil
    end
    return "server_rejected"
end

-- Write the uploaded position back into the book record so later
-- reports start from it even across restarts.
function ProgressUploader:_persist(position)
    local books = self.settings:get("books", {})
    local book = books[tostring(position.book_id)]
    if type(book) ~= "table" then
        return
    end
    book.chapter_uid = position.chapter_uid
    book.chapter_idx = tonumber(position.chapter_idx) or 0
    book.chapter_offset = tonumber(position.chapter_offset) or 0
    book.progress = tonumber(position.percent) or 0
    book.summary = position.summary or book.summary or ""
    book.last_upload_at = self.now()
    self.settings:set("books", books)
    self.settings:flush()
end

return ProgressUploader
