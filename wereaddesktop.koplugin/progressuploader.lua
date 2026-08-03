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
back to whole-book fractions via remote_to_local. On a clean open the pull
runs before the initial upload; a durable unsent local position is pushed
first so an older cloud position cannot overwrite it.

Uploads are heartbeat-driven, not page-turn-driven: a timer fires every
HEARTBEAT_INTERVAL seconds while the document is open, reporting the
latest position and the active reading time not yet reported (rt).
Suspend intervals are excluded. Although the official browser retries one
cumulative delta, the server does not credit rt above 60; longer offline
backlogs are kept locally until the user starts a paced replay from Settings.
While that replay runs, live readers continue syncing progress with rt=0 and
persist newly read time in a separate bucket for a later pass. Reconnection
itself uploads only the newest position.

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
-- Verified against the real account on both this client and the official web
-- reader. Official requests with a dynamic x-wrpa-0 return succ=1 + synckey for
-- rt=90/120 but do not change read stats; rt=60 is credited exactly. The
-- successful response therefore acknowledges progress, not necessarily rt.
local RT_CAP = 60
-- Real-account verification: back-to-back 60-second backlog reports all return
-- succ=1 but only the first is credited. Waiting a full accounting window and
-- using the actual send time credits every chunk.
local BACKLOG_REPLAY_DELAY = 61
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

-- Manual replay and live reading run in separate plugin instances (file manager
-- and reader) but share this required module in one KOReader process. Keep a
-- process-wide coordinator so only the replay sends credited time while it is
-- active. Weak keys avoid retaining reader instances after a document closes.
local live_uploaders = setmetatable({}, { __mode = "k" })
local time_replay = {
    active = false,
    token = 0,
    settings = nil,
    account_vid = nil,
    block_live_until = 0,
    last_replay_report_at = nil,
}

local TIME_BUCKETS = {
    pending = {
        elapsed = "pending_upload_elapsed",
        started_at = "pending_upload_started_at",
    },
    replay = {
        elapsed = "pending_replay_elapsed",
        started_at = "pending_replay_started_at",
    },
}

-- A live-device recovery showed that a read report can return succ=1 while
-- silently ignoring both the position and rt. Credited read reports include a
-- synckey, so both success and that server acknowledgement are required before
-- draining the durable queue. Enter-read reports do not carry reading time and
-- only need the ordinary success marker.
local function response_accepted(result)
    return WeRead.is_success_response(result)
        and type(result) == "table"
        and result.synckey ~= nil
        and tostring(result.synckey) ~= ""
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

-- Account (user_vid) the current settings instance is logged in as;
-- empty when not logged in. Queued offline data is stamped with this so
-- a later account switch cannot upload it under the new credentials
-- (review.md #1).
local function current_user_vid(settings)
    local account = type(settings.get) == "function"
        and settings:get("account", {}) or {}
    if type(account) == "table" and account.user_vid ~= nil then
        return tostring(account.user_vid)
    end
    return ""
end

local function has_pending_payload(book)
    return type(book) == "table"
        and (type(book.pending_upload_position) == "table"
            or (tonumber(book.pending_upload_elapsed) or 0) > 0
            or (tonumber(book.pending_replay_elapsed) or 0) > 0)
end

local function pending_owner_vid(book)
    return type(book) == "table"
        and tostring(book.pending_upload_user_vid or "") or ""
end

local function uploader_account_matches(uploader)
    local expected = tostring(uploader and uploader.account_vid or "")
    return expected ~= ""
        and current_user_vid(uploader.settings) == expected
end

-- A flat per-book pending record can have only one owner. Unknown legacy
-- records and records belonging to another account are quarantined: callers
-- may still upload the current live position, but must not mutate that durable
-- queue.
local function can_mutate_pending(book, vid)
    vid = tostring(vid or "")
    if vid == "" then
        return false
    end
    local owner = pending_owner_vid(book)
    if has_pending_payload(book) then
        return owner == vid
    end
    return true
end

-- Persist one mutated book record. Books live in per-book BookStore files
-- (metadata.json + reading_state.json); the single-book path avoids
-- reloading and rewriting every other book on every heartbeat.
local function persist_book(settings, book)
    settings:save_book(tostring(book.book_id), book)
    settings:flush()
end

local function copy_position(position)
    if type(position) ~= "table" then
        return nil
    end
    local copy = {}
    for key, value in pairs(position) do
        copy[key] = value
    end
    return copy
end

local function same_settings_scope(left, right)
    if left == right then
        return true
    end
    return type(left) == "table" and type(right) == "table"
        and type(left.settings_file) == "string"
        and left.settings_file ~= ""
        and left.settings_file == right.settings_file
end

local function positive_min(...)
    local result
    for index = 1, select("#", ...) do
        local selected = select(index, ...)
        local value = tonumber(selected)
        if value and value > 0 and (not result or value < result) then
            result = value
        end
    end
    return result
end

-- Freeze all time already accumulated by live readers into a replay-only
-- bucket. New reading after this boundary stays in pending_upload_elapsed, so
-- the two uploader instances never decrement or overwrite the same number.
function ProgressUploader.beginTimeReplay(settings)
    if time_replay.active then
        return nil, nil, "already_active"
    end
    local current_vid = current_user_vid(settings)
    if current_vid == "" then
        return nil, {}, "account_missing"
    end
    local prepared = {}
    for uploader in pairs(live_uploaders) do
        if same_settings_scope(uploader.settings, settings)
            and uploader.time_bucket == "pending"
            and uploader.book_id
            and uploader.account_vid == current_vid
            and uploader_account_matches(uploader) then
            local ok, captured = pcall(
                uploader._prepareTimeReplayBoundary, uploader)
            prepared[uploader] = ok and captured == true
            if not ok then
                logger.warn("live replay boundary persistence failed:",
                    tostring(captured))
            end
        end
    end

    local books = settings:get("books", {})
    local ids = {}
    for book_id, book in pairs(type(books) == "table" and books or {}) do
        local pending = type(book) == "table"
            and math.max(0, tonumber(book.pending_upload_elapsed) or 0) or 0
        local replay = type(book) == "table"
            and math.max(0, tonumber(book.pending_replay_elapsed) or 0) or 0
        local book_vid = type(book) == "table"
            and tostring(book.pending_upload_user_vid or "") or ""
        -- Skip time queued under another account: replaying it would credit
        -- reading time to the currently logged-in account (review.md #1).
        if type(book) == "table"
            and book_vid == current_vid
            and type(book.pending_upload_position) == "table"
            and pending + replay > 0 then
            book.pending_replay_elapsed = pending + replay
            book.pending_replay_started_at = positive_min(
                book.pending_replay_started_at,
                book.pending_upload_started_at,
                (tonumber(book.pending_upload_updated_at) or os.time())
                    - (pending + replay))
            book.pending_upload_elapsed = nil
            book.pending_upload_started_at = nil
            book.pending_upload_updated_at = os.time()
            ids[#ids + 1] = tostring(book_id)
        end
    end
    if #ids == 0 then
        return nil, ids, "empty"
    end
    table.sort(ids)
    settings:set("books", books)
    settings:flush()

    time_replay.token = time_replay.token + 1
    time_replay.active = true
    time_replay.settings = settings
    time_replay.account_vid = current_vid
    time_replay.last_replay_report_at = nil
    local token = time_replay.token
    local coordination_failed = false
    for uploader in pairs(live_uploaders) do
        if same_settings_scope(uploader.settings, settings)
            and uploader.time_bucket == "pending"
            and uploader.book_id
            and uploader.account_vid == current_vid
            and uploader_account_matches(uploader) then
            local ok, err = pcall(uploader._onTimeReplayStarted, uploader,
                prepared[uploader] == true)
            if not ok then
                coordination_failed = true
                logger.warn("live replay start coordination failed:",
                    tostring(err))
            end
        end
    end
    if coordination_failed then
        time_replay.active = false
        time_replay.settings = nil
        time_replay.account_vid = nil
        return nil, ids, "reader_coordination_failed"
    end
    return token, ids
end

-- Before releasing the replay lock, durably hand all time read during replay
-- to the normal pending bucket. It will be offered by the next manual pass;
-- advancing the live session baseline prevents those seconds being counted
-- again by its next heartbeat.
function ProgressUploader.endTimeReplay(token, _at)
    if not time_replay.active or token ~= time_replay.token then
        return false
    end
    local settings = time_replay.settings
    local account_vid = time_replay.account_vid
    for uploader in pairs(live_uploaders) do
        if same_settings_scope(uploader.settings, settings)
            and uploader.time_bucket == "pending"
            and uploader.book_id
            and uploader.account_vid == account_vid
            and uploader_account_matches(uploader) then
            local ok, err = pcall(uploader._onTimeReplayFinishing, uploader)
            if not ok then
                logger.warn("live replay finish coordination failed:",
                    tostring(err))
            end
        end
    end
    local last_report_at = tonumber(time_replay.last_replay_report_at)
    time_replay.active = false
    time_replay.settings = nil
    time_replay.account_vid = nil
    if last_report_at then
        time_replay.block_live_until = math.max(
            tonumber(time_replay.block_live_until) or 0,
            last_report_at + BACKLOG_REPLAY_DELAY)
    end
    time_replay.last_replay_report_at = nil
    return true
end

function ProgressUploader.isTimeReplayActive()
    return time_replay.active == true
end

function ProgressUploader.isLiveTimeBlocked(at)
    return time_replay.active == true
        or (tonumber(at) or os.time()) <
            (tonumber(time_replay.block_live_until) or 0)
end

function ProgressUploader.timeReplayStartDelay(at)
    return math.max(0, (tonumber(time_replay.block_live_until) or 0)
        - (tonumber(at) or os.time()))
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
    local time_bucket = options.time_bucket == "replay"
        and "replay" or "pending"
    local instance = setmetatable({
        settings = options.settings,
        client = options.client,
        scheduler = options.scheduler,
        -- Every scheduled callback is bound to this account. It is refreshed
        -- only when a new document session starts; retries keep the original
        -- owner so an account switch cannot change credentials underneath an
        -- in-flight upload.
        account_vid = current_user_vid(options.settings),
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
        time_bucket = time_bucket,
        replay_initial_delay_used = false,
        generation = 0,
        pending_position = nil,
        pending_elapsed = 0,
        pending_started_at = nil,
        pending_reason = nil,
        last_pending_persist_at = nil,
        -- Once reading time has been queued offline, automatic progress
        -- reports must leave it untouched. It is drained only by the
        -- explicit Settings action (include_pending_time=true).
        defer_pending_time = false,
        on_finished = options.on_finished,
    }, self)
    live_uploaders[instance] = true
    return instance
end

function ProgressUploader:_timeFields()
    return TIME_BUCKETS[self.time_bucket] or TIME_BUCKETS.pending
end

function ProgressUploader:_accountMatches()
    return uploader_account_matches(self)
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

-- Active seconds not yet covered by a successfully accepted report or handed
-- to one of the durable time buckets.
-- This is intentionally separate from wall-clock time so suspend gaps
-- stay excluded and failed/offline reports can be caught up later.
function ProgressUploader:_unreportedElapsed(at)
    return math.max(0, tonumber(self.pending_elapsed) or 0)
        + math.max(0, self:_readingElapsed(at)
            - (tonumber(self.last_reported_rt) or 0))
end

-- Called synchronously by beginTimeReplay before it moves the normal pending
-- bucket. This captures the live session exactly at the hand-off boundary.
function ProgressUploader:_prepareTimeReplayBoundary()
    local position = self.last_position or self.pending_position
    if not position and self.get_fraction then
        local fraction = self.get_fraction()
        position = fraction and self:capture(fraction) or nil
    end
    if not position then
        return false
    end
    return self:_persistPending(position, "manual_replay_boundary",
        self:_unreportedElapsed(), true)
end

function ProgressUploader:_onTimeReplayStarted(boundary_captured)
    if self.time_bucket ~= "pending" or not self.book_id then
        return
    end
    -- Everything up to this instant was flushed and moved to the replay
    -- bucket. Start a fresh live accumulator for reading that happens while
    -- the replay worker owns the server's credited-time window.
    self.pending_elapsed = 0
    self.pending_started_at = nil
    if boundary_captured then
        self.last_reported_rt = self:_readingElapsed()
    end
    self.defer_pending_time = true
end

function ProgressUploader:_onTimeReplayFinishing()
    if self.time_bucket ~= "pending" or not self.book_id then
        return
    end
    local position = self.last_position or self.pending_position
    if not position and self.get_fraction then
        local fraction = self.get_fraction()
        position = fraction and self:capture(fraction) or nil
    end
    local persisted = position and self:_persistPending(position,
        "reading_during_manual_replay",
            self:_unreportedElapsed(), true)
    local fields = self:_timeFields()
    local book = self.settings:get_book(self.book_id)
    self.pending_elapsed = type(book) == "table"
        and math.max(0, tonumber(book[fields.elapsed]) or 0) or 0
    self.pending_started_at = type(book) == "table"
        and tonumber(book[fields.started_at]) or nil
    -- Treat the persisted live accumulator as handed off, not uploaded. It is
    -- now represented by pending_elapsed, so the session clock must begin a
    -- new delta or the next heartbeat would count the same seconds twice.
    if persisted then
        self.last_reported_rt = self:_readingElapsed()
    end
    self.defer_pending_time = self.pending_elapsed > 0
        or (type(book) == "table"
            and (tonumber(book.pending_replay_elapsed) or 0) > 0)
end

-- Keep the latest unsent position and active reading time durable. This is
-- intentionally best-effort: a broken settings write must not interrupt the
-- reader, while a successful write lets the next KOReader process resume the
-- report after a crash, battery loss or an offline close.
function ProgressUploader:_persistPending(position, reason, elapsed, force)
    if not self.book_id or not position then
        return false
    end
    local now = self.now()
    if not force and self.last_pending_persist_at
        and now - self.last_pending_persist_at < 5 then
        return false
    end
    local book = self.settings:get_book(self.book_id)
    if type(book) ~= "table" then
        return false
    end
    if not self:_accountMatches()
        or not can_mutate_pending(book, self.account_vid) then
        logger.warn("pending progress is quarantined for another/unknown account:",
            "book=", tostring(self.book_id),
            "owner=", pending_owner_vid(book),
            "current=", current_user_vid(self.settings))
        return false
    end
    self.pending_position = copy_position(position)
    self.pending_reason = reason or self.pending_reason or "unknown"
    book.pending_upload_position = copy_position(self.pending_position)
    book.pending_upload_reason = self.pending_reason
    -- Stamp the owning account, but never overwrite a marker that belongs
    -- to another account: that would reattribute queued offline data to
    -- the currently logged-in user (review.md #1 follow-up).
    book.pending_upload_user_vid = self.account_vid
    local fields = self:_timeFields()
    -- `pending_elapsed` in memory is the backlog from previous sessions;
    -- the current session's unreported time is derived from the clock. The
    -- persisted value intentionally stores their sum so a new process can
    -- resume it without double-counting the current session.
    local pending_elapsed = math.max(0, tonumber(elapsed) or 0)
    book[fields.elapsed] = pending_elapsed > 0 and pending_elapsed or nil
    if pending_elapsed > 0 then
        if not self.is_online() then
            self.defer_pending_time = true
        end
        self.pending_started_at = tonumber(self.pending_started_at)
            or tonumber(book[fields.started_at])
            or math.max(0, now - pending_elapsed)
        book[fields.started_at] = self.pending_started_at
    else
        self.pending_started_at = nil
        book[fields.started_at] = nil
    end
    book.pending_upload_updated_at = now
    local ok, err = pcall(persist_book, self.settings, book)
    if not ok then
        logger.warn("pending progress persistence failed:", tostring(err))
        return false
    end
    self.last_pending_persist_at = now
    return true
end

function ProgressUploader:_clearPending()
    self.pending_position = nil
    self.pending_elapsed = 0
    self.pending_started_at = nil
    self.pending_reason = nil
    self.last_pending_persist_at = nil
    self.defer_pending_time = false
    if not self.book_id then
        return false
    end
    local book = self.settings:get_book(self.book_id)
    if type(book) ~= "table" then
        return false
    end
    if not self:_accountMatches()
        or pending_owner_vid(book) ~= self.account_vid then
        return false
    end
    local fields = self:_timeFields()
    book[fields.elapsed] = nil
    book[fields.started_at] = nil
    local remaining_elapsed = math.max(0,
        tonumber(book.pending_upload_elapsed) or 0)
        + math.max(0, tonumber(book.pending_replay_elapsed) or 0)
    if remaining_elapsed <= 0 then
        book.pending_upload_position = nil
        book.pending_upload_reason = nil
        book.pending_upload_updated_at = nil
        book.pending_upload_user_vid = nil
    else
        book.pending_upload_updated_at = self.now()
    end
    local ok, err = pcall(persist_book, self.settings, book)
    if not ok then
        logger.warn("pending progress cleanup failed:", tostring(err))
        return false
    end
    return true
end

function ProgressUploader:_restorePending()
    if not self.book_id then
        return false
    end
    local book = self.settings:get_book(self.book_id)
    if type(book) ~= "table"
        or type(book.pending_upload_position) ~= "table" then
        return false
    end
    -- Offline data queued under another account must never be resumed and
    -- uploaded with the current credentials; leave the record (and its
    -- marker) untouched so the previous owner's queue is preserved
    -- (review.md #1 follow-up).
    local vid = current_user_vid(self.settings)
    local book_vid = pending_owner_vid(book)
    if vid == "" or vid ~= self.account_vid or book_vid ~= vid then
        logger.warn("pending progress belongs to another account, not resumed:",
            "book=", tostring(self.book_id))
        return false
    end
    self.pending_position = copy_position(book.pending_upload_position)
    local fields = self:_timeFields()
    self.pending_elapsed = math.max(0,
        tonumber(book[fields.elapsed]) or 0)
    if self.pending_elapsed > 0 then
        self.pending_started_at = tonumber(book[fields.started_at])
            or math.max(0,
                (tonumber(book.pending_upload_updated_at) or self.now())
                    - self.pending_elapsed)
    end
    self.pending_reason = book.pending_upload_reason or "recovered"
    self.defer_pending_time = self.pending_elapsed > 0
        or (tonumber(book.pending_upload_elapsed) or 0) > 0
        or (tonumber(book.pending_replay_elapsed) or 0) > 0
    self.last_position = copy_position(self.pending_position)
    self.dirty = true
    logger.info("restored pending progress:",
        "book=", tostring(self.book_id),
        "elapsed_s=", tostring(self.pending_elapsed),
        "reason=", tostring(self.pending_reason))
    return true
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
    -- Cumulative active seconds already covered by accepted delta reports or
    -- handed to a durable replay bucket; despite the legacy name, this is not
    -- the last rt payload.
    self.last_reported_rt = 0
    self.closing = false
    self.close_position = nil
    self.closed_at = nil
    self.paused_at = nil
    self.paused_seconds = 0
    self._toc_aligned_source = nil
    self._toc_aligned = nil
    self.pending_position = nil
    self.pending_elapsed = 0
    self.pending_started_at = nil
    self.pending_reason = nil
    self.last_pending_persist_at = nil
    self.defer_pending_time = false
    self._pulled_ahead = false
    self.opened_at = self.now()
    self.account_vid = current_user_vid(self.settings)
    local book_id = self:detectBook(path)
    if not book_id or WeRead.is_mp_book(book_id) then
        logger.dbg("reader open ignored:", "path=", tostring(path),
            "detected_book=", tostring(book_id))
        return nil
    end
    self.book_id = tostring(book_id)
    local restored_pending = self:_restorePending()
    logger.info("reading session opened:", "book=", self.book_id,
        "generation=", tostring(self.generation),
        "heartbeat_s=", tostring(self.heartbeat_interval))
    -- Pull-then-upload on a clean open. A restored local queue takes priority
    -- and is uploaded before a later clean open may pull cloud progress.
    local generation = self.generation
    self.scheduler:scheduleIn(OPEN_REPORT_DELAY, function()
        if generation ~= self.generation or not self.book_id
            or not self:_accountMatches() then
            return
        end
        -- A durable local position has not reached the cloud yet and is the
        -- canonical newest local state. Push it first; pulling beforehand can
        -- jump to an older cloud position and destroy the queued one.
        if not restored_pending then
            self:_pullFromCloud()
        end
        local fraction = self.get_fraction and self.get_fraction()
        local position = self.pending_position
            or (fraction and self:capture(fraction))
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

-- Resume one durable queue entry without an open document. Automatic
-- reconnection passes progress_only; the explicit Settings action passes
-- include_pending_time and drains RT_CAP-sized chunks at the paced interval.
function ProgressUploader:retryPending(book_id, options)
    options = options or {}
    if self.uploading or not self.is_online() or not self:_accountMatches() then
        return false
    end
    if self.book_id then
        if book_id ~= nil and tostring(book_id) ~= tostring(self.book_id) then
            return false
        end
        local position = self.pending_position or self.last_position
        if position and options.progress_only then
            -- Freeze everything accumulated before reconnection into the
            -- manual queue. Later online heartbeats can still report newly
            -- read time without consuming this offline backlog.
            self.pending_elapsed = self:_unreportedElapsed()
            self.last_reported_rt = self:_readingElapsed()
            self.defer_pending_time = self.pending_elapsed > 0
            self:_persistPending(position, "network_reconnect",
                self.pending_elapsed, true)
        end
        return position
            and self:_upload(position, "network_reconnect", nil, options)
            or false
    end
    book_id = tostring(book_id or "")
    local book = self.settings:get_book(book_id)
    if book_id == "" or type(book) ~= "table"
        or type(book.pending_upload_position) ~= "table"
        or pending_owner_vid(book) ~= self.account_vid then
        return false
    end
    self.generation = self.generation + 1
    self.book_id = book_id
    self.book = nil
    self.chapters = nil
    self.dirty = true
    self.uploading = false
    self.entered = false
    self.last_position = nil
    self.last_uploaded = nil
    self.last_upload_at = nil
    self.last_reported_rt = 0
    self.closing = true
    self.opened_at = self.now()
    self.closed_at = self.opened_at
    self.close_position = nil
    self.paused_at = nil
    self.paused_seconds = 0
    self.pending_position = nil
    self.pending_elapsed = 0
    self.pending_started_at = nil
    self.pending_reason = nil
    self.last_pending_persist_at = nil
    self._pulled_ahead = false
    if not self:_restorePending() then
        self:_finishClose(self.generation)
        return false
    end
    self.close_position = copy_position(self.pending_position)
    return self:_upload(self.pending_position, "network_reconnect", nil, options)
end

-- One heartbeat tick: upload the current position (page turns only
-- record it; the timer is what reports position and reading time), then
-- re-arm. Stops when the document changes.
function ProgressUploader:_heartbeat(generation)
    if generation ~= self.generation or not self.book_id or self.closing
        or not self:_accountMatches() then
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
    self._pulled_ahead = false
    if not self.is_online() or not self:_ensureContext() then
        return false
    end
    local remote = self:_fetchRemote()
    if not remote then
        return false
    end
    if self:_pullChapterPath(remote) then
        return self._pulled_ahead == true
    end
    local target = PositionMapper.remote_to_local(self.chapters, remote, {
        is_full_book = true,
    })
    if not target or not target.fraction then
        return false
    end
    local local_fraction = (self.get_fraction and self.get_fraction()) or 0
    if target.fraction - local_fraction < SYNC_AHEAD_THRESHOLD then
        return false
    end
    logger.info("cloud progress ahead: book=", self.book_id,
        "cloud=", tostring(target.fraction),
        "local=", tostring(local_fraction))
    if self.on_sync_to then
        local ok, result = pcall(self.on_sync_to, target.fraction, remote)
        self._pulled_ahead = ok and result ~= false
        if not ok then
            logger.warn("sync-to-cloud-position failed:", tostring(result))
        end
    end
    return self._pulled_ahead == true
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
            local ok, result = pcall(self.on_sync_to_page, page, remote)
            self._pulled_ahead = ok and result ~= false
            if not ok then
                logger.warn("sync-to-cloud-page failed:", tostring(result))
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
    local book = self.settings:get_book(self.book_id)
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
    -- Persist page turns at a modest cadence so a crash before the next
    -- heartbeat still leaves a recoverable position without writing on every
    -- single reader repaint.
    self:_persistPending(position, "page_update", self:_unreportedElapsed())
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
    local finished_book_id = self.book_id
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
    self.pending_position = nil
    self.pending_elapsed = 0
    self.pending_started_at = nil
    self.pending_reason = nil
    self.last_pending_persist_at = nil
    self.defer_pending_time = false
    self._pulled_ahead = false
    if self.on_finished then
        pcall(self.on_finished, finished_book_id)
    end
end

-- Cancel a headless close/replay worker while keeping its durable queue. The
-- scheduler cannot remove an already queued task, so invalidate its
-- generation first; the next task will be ignored and the owner can release
-- its standby guard from on_finished.
function ProgressUploader:cancel(reason)
    if not self.book_id then
        return false
    end
    local position = self.close_position or self.pending_position
        or self.last_position
    self.generation = self.generation + 1
    self.uploading = false
    self.closing = true
    self.close_position = position and copy_position(position) or nil
    if position then
        self:_persistPending(position, reason or "cancelled",
            self:_unreportedElapsed(), true)
    end
    self:_finishClose(self.generation)
    return true
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
    local has_pending = self.pending_position ~= nil
        or (tonumber(self.pending_elapsed) or 0) > 0
    if (not position and not has_pending)
        or (not self.dirty and unreported <= 0 and not has_pending) then
        self:_finishClose(generation)
        return
    end
    position = position or self.pending_position
    self:_persistPending(position, "document_close", self:_unreportedElapsed(), true)
    if not self:_upload(position, "document_close") then
        logger.warn("reading session closed without final upload:",
            "book=", tostring(self.book_id),
            "unreported_s=", tostring(unreported))
        self:_finishClose(generation)
    end
end

-- The read endpoint acknowledges progress independently of whether it credits
-- rt. Keep a closed-book backlog durable and replay at real-time speed; firing
-- the chunks back-to-back silently loses every chunk after the first.
function ProgressUploader:_scheduleBacklogReplay(position, generation, options)
    local scheduled_at = tonumber(self.now()) or 0
    logger.info("backlog replay scheduled:",
        "book=", tostring(position and position.book_id),
        "delay_s=", tostring(BACKLOG_REPLAY_DELAY),
        "remaining_s=", tostring(self:_unreportedElapsed()))
    self.scheduler:scheduleIn(BACKLOG_REPLAY_DELAY, function()
        local ok, err = xpcall(function()
            local late_s = math.max(0,
                (tonumber(self.now()) or scheduled_at)
                    - scheduled_at - BACKLOG_REPLAY_DELAY)
            if late_s >= 5 then
                logger.warn("backlog replay task late:",
                    "book=", tostring(position and position.book_id),
                    "late_s=", tostring(late_s))
            end
            if generation ~= self.generation or not self.closing then
                return
            end
            if not self:_upload(position, "backlog_replay", nil, options) then
                -- Offline/final failure leaves the durable record intact. Release
                -- this headless uploader so the next network event can restore it.
                self:_finishClose(generation)
            end
        end, debug.traceback)
        if not ok then
            self.uploading = false
            logger.err("backlog replay task failed:",
                "book=", tostring(position and position.book_id),
                "error=", tostring(err))
            if generation == self.generation and self.closing then
                self:_persistPending(position, "backlog_replay",
                    self:_unreportedElapsed(), true)
                self:_finishClose(generation)
            end
        end
    end)
end

-- Schedule one upload attempt chain for a captured position. The
-- `uploading` flag stays set across retries so page ticks cannot start
-- a parallel send; it is cleared on success, on final failure and when
-- the document changes underneath a scheduled task.
function ProgressUploader:_upload(position, reason, attempt, options)
    options = options or {}
    if not self:_accountMatches() then
        logger.warn("upload skipped after account change:",
            "book=", tostring(position and position.book_id),
            "expected=", tostring(self.account_vid),
            "current=", current_user_vid(self.settings))
        return false
    end
    if self.time_bucket == "replay" and self.book_id then
        -- A live reader may have advanced the book while this worker waited
        -- for the next 61-second slot. Carry its newest position instead of
        -- repeatedly pushing the stale position captured at replay start.
        local latest_book = self.settings:get_book(self.book_id)
        if type(latest_book) == "table"
            and type(latest_book.pending_upload_position) == "table" then
            position = copy_position(latest_book.pending_upload_position)
        end
    end
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
    self.pending_position = copy_position(position)
    self.pending_reason = reason or self.pending_reason or "unknown"
    self:_persistPending(position, self.pending_reason,
        self:_unreportedElapsed(), true)
    if not self.is_online() then
        if self:_unreportedElapsed() > 0 then
            self.defer_pending_time = true
        end
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
    local upload_delay = 0.1
    if self.time_bucket == "replay" and not self.replay_initial_delay_used then
        self.replay_initial_delay_used = true
        upload_delay = math.max(upload_delay,
            ProgressUploader.timeReplayStartDelay(self.now()))
    end
    local scheduled_at = tonumber(self.now()) or 0
    self.scheduler:scheduleIn(upload_delay, function()
        local late_s = math.max(0,
            (tonumber(self.now()) or scheduled_at)
                - scheduled_at - upload_delay)
        if late_s >= 5 then
            logger.warn("upload task late:",
                "book=", tostring(position.book_id),
                "reason=", tostring(reason),
                "late_s=", tostring(late_s))
        end
        if generation ~= self.generation then
            return
        end
        if not self:_accountMatches() then
            self.uploading = false
            if self.closing then
                self:_finishClose(generation)
            end
            return
        end
        if not self.is_online() then
            self.uploading = false
            logger.info("upload deferred after wait:",
                "book=", tostring(position.book_id),
                "reason=", tostring(reason), "cause=offline")
            if self.closing then
                self:_finishClose(generation)
            end
            return
        end
        local active_total = self:_readingElapsed()
        local unreported = self:_unreportedElapsed()
        local pending_before = tonumber(self.pending_elapsed) or 0
        local coordinated_progress_only = self.time_bucket == "pending"
            and ProgressUploader.isLiveTimeBlocked(self.now())
        local progress_only = options.progress_only == true
            or coordinated_progress_only
        local include_pending_time = options.include_pending_time == true
        local hold_pending_time = self.defer_pending_time
            and not include_pending_time
        local session_unreported = math.max(0, active_total
            - (tonumber(self.last_reported_rt) or 0))
        local sending_pending = not progress_only
            and not hold_pending_time and pending_before > 0
        -- Automatic reconnect and live reading during/cooldown after a manual
        -- replay report position with rt=0. Outside that coordination window,
        -- normal heartbeats may report only the current session delta without
        -- consuming a durable backlog. The server silently fails to credit any
        -- one rt above RT_CAP.
        local elapsed
        if progress_only then
            elapsed = 0
        elseif hold_pending_time then
            elapsed = math.min(RT_CAP, session_unreported)
        else
            elapsed = math.min(RT_CAP,
                pending_before > 0 and pending_before or unreported)
        end
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
            local handled, handling_error = xpcall(function()
                self.uploading = false
            local pending_sent = sending_pending
                and math.min(pending_before, elapsed) or 0
            local session_sent = elapsed - pending_sent
            self.pending_elapsed = math.max(0, pending_before - pending_sent)
            if pending_sent > 0 and self.pending_started_at then
                self.pending_started_at = self.pending_started_at + pending_sent
                if self.pending_elapsed <= 0 then
                    self.pending_started_at = nil
                end
            end
            self.last_reported_rt =
                (tonumber(self.last_reported_rt) or 0) + session_sent
            self.dirty = false
            self.last_upload_at = self.now()
            self.last_uploaded = position
            if self.time_bucket == "replay" and elapsed > 0 then
                time_replay.last_replay_report_at = self.now()
            end
            logger.info("progress uploaded: book=", tostring(position.book_id),
                "percent=", tostring(position.percent), "reason=", reason,
                "attempt=", tostring(attempt), "rt=", tostring(elapsed),
                "reported_total_s=", tostring(self.last_reported_rt))
            local final_position = self.close_position or position
            local position_pending = self.closing and final_position
                and not PositionMapper.same_position(final_position, position)
            local remaining_unreported = self:_unreportedElapsed()
            local time_pending = remaining_unreported > 0
            local pending_position
            local pending_reason
            if self.closing then
                if progress_only or hold_pending_time then
                    if position_pending or time_pending then
                        pending_position = final_position
                        pending_reason = "offline_time_pending"
                    end
                elseif position_pending or time_pending then
                    pending_position = final_position
                    pending_reason = "document_close"
                end
            elseif time_pending then
                pending_position = self.pending_position or position
                pending_reason = self.pending_reason or reason
            end
            self:_persistUploadResult(position, pending_position,
                pending_reason, remaining_unreported)
            if self.on_uploaded then
                pcall(self.on_uploaded, position.book_id, position)
            end
            if self.closing then
                if progress_only or hold_pending_time then
                    self:_finishClose(generation)
                    return
                end
                if position_pending or time_pending then
                    self.dirty = position_pending == true
                    if time_pending then
                        self:_scheduleBacklogReplay(final_position, generation,
                            options)
                        return
                    end
                    if self:_upload(final_position, "document_close", nil,
                        options) then
                        return
                    end
                end
                self:_finishClose(generation)
                end
            end, debug.traceback)
            if not handled then
                self.uploading = false
                logger.err("progress upload bookkeeping failed:",
                    "book=", tostring(position.book_id),
                    "reason=", tostring(reason),
                    "error=", tostring(handling_error))
                local recovery_position = self.close_position
                    or self.pending_position or position
                if recovery_position then
                    self:_persistPending(recovery_position,
                        self.pending_reason or reason,
                        self:_unreportedElapsed(), true)
                end
                if self.closing then
                    self:_finishClose(generation)
                end
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
                if not self:_accountMatches() then
                    if self.closing then
                        self:_finishClose(generation)
                    end
                    return
                end
                self:_upload(position, "retry", attempt + 1, options)
            end)
        else
            self.uploading = false
            if self.closing then
                local final_position = self.close_position or position
                if final_position
                    and not PositionMapper.same_position(final_position, position) then
                    self.pending_position = copy_position(final_position)
                    self.dirty = true
                    self:_persistPending(final_position, "document_close",
                        self:_unreportedElapsed(), true)
                    if self:_upload(final_position, "document_close", nil,
                        options) then
                        return
                    end
                end
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
    if not self:_accountMatches() then
        return "account_changed"
    end
    local book_id = position.book_id
    local book = self.settings:get_book(book_id)
    if type(book) ~= "table" then
        return "book_record_missing"
    end
    if book.pclts == nil or book.pclts == "" or tonumber(book.pclts) == 0 then
        -- Persist right away: post-send persistence re-reads the book record,
        -- so an in-memory-only mutation would be lost and pclts would be
        -- regenerated on every upload.
        book.pclts = WeRead.e(self.now())
        persist_book(self.settings, book)
    end
    local referer = book.reader_url or WeRead.reader_url(book_id)

    local function send_enter()
        local result = self.client:report_read(WeRead.make_enter_read_payload{
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
        self.entered = WeRead.is_success_response(result)
        logger.info("enter-read response:", "book=", tostring(book_id),
            "accepted=", tostring(self.entered),
            "result=", response_summary(result))
        return self.entered
    end

    local function refresh_reader_state()
        local ok, err = pcall(Content.ensure_reader_state, self.client, book)
        if not ok then
            logger.warn("reader-state refresh failed:", "book=", tostring(book_id),
                "error=", tostring(err))
            return false
        end
        persist_book(self.settings, book)
        return true
    end

    if not self.entered and not send_enter() then
        -- A stale web session commonly rejects the headless enter request.
        -- Refresh first, then establish the reading session before sending rt.
        if not refresh_reader_state() or not send_enter() then
            return "enter_rejected"
        end
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
            now = self.now(),
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
    self.entered = false
    if not refresh_reader_state() or not send_enter() then
        return "enter_rejected_after_refresh"
    end
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

-- Write the uploaded position and the remaining pending state together so a
-- successful heartbeat does not save the same book twice.
function ProgressUploader:_persistUploadResult(position, pending_position,
    pending_reason, pending_elapsed)
    local book = self.settings:get_book(position.book_id)
    if type(book) ~= "table" then
        return
    end
    local now = self.now()
    book.chapter_uid = position.chapter_uid
    book.chapter_idx = tonumber(position.chapter_idx) or 0
    book.chapter_offset = tonumber(position.chapter_offset) or 0
    book.progress = tonumber(position.percent) or 0
    book.summary = position.summary or book.summary or ""
    book.last_upload_at = now
    local elapsed = math.max(0, tonumber(pending_elapsed) or 0)
    local fields = self:_timeFields()
    local may_mutate_pending = self:_accountMatches()
        and can_mutate_pending(book, self.account_vid)
    if not may_mutate_pending then
        -- Keep the other/unknown owner's durable queue byte-for-byte intact.
        -- The accepted live position above is still safe to persist locally.
        logger.warn("upload result left quarantined pending data untouched:",
            "book=", tostring(position.book_id),
            "owner=", pending_owner_vid(book),
            "current=", current_user_vid(self.settings))
        self.settings:save_book(tostring(position.book_id), book)
        self.settings:flush()
        return
    end
    if pending_position then
        self.pending_position = copy_position(pending_position)
        self.pending_reason = pending_reason or self.pending_reason or "unknown"
        book.pending_upload_position = copy_position(self.pending_position)
        book.pending_upload_reason = self.pending_reason
        -- Never overwrite another account's ownership marker (see
        -- _persistPending; review.md #1 follow-up).
        book.pending_upload_user_vid = self.account_vid
        book[fields.elapsed] = elapsed > 0 and elapsed or nil
        if elapsed > 0 then
            if not self.is_online() then
                self.defer_pending_time = true
            end
            self.pending_started_at = tonumber(self.pending_started_at)
                or tonumber(book[fields.started_at])
                or math.max(0, now - elapsed)
            book[fields.started_at] = self.pending_started_at
        else
            self.pending_started_at = nil
            book[fields.started_at] = nil
        end
        book.pending_upload_updated_at = now
        self.last_pending_persist_at = now
    else
        self.pending_position = nil
        self.pending_started_at = nil
        self.pending_reason = nil
        self.pending_elapsed = 0
        self.last_pending_persist_at = nil
        self.defer_pending_time = false
        book[fields.elapsed] = nil
        book[fields.started_at] = nil
        local remaining_elapsed = math.max(0,
            tonumber(book.pending_upload_elapsed) or 0)
            + math.max(0, tonumber(book.pending_replay_elapsed) or 0)
        if remaining_elapsed <= 0 then
            book.pending_upload_position = nil
            book.pending_upload_reason = nil
            book.pending_upload_updated_at = nil
            book.pending_upload_user_vid = nil
        else
            book.pending_upload_updated_at = now
        end
    end
    self.settings:save_book(tostring(position.book_id), book)
    self.settings:flush()
end

return ProgressUploader
