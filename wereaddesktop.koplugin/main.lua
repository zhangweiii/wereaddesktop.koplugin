--[[--
WeRead desktop plugin: shows the WeRead shelf (cloud bookshelf, store
and settings tabs) as a full-screen home screen on top of the file
manager at startup. Not logged in: a QR login prompt is shown instead.
--]]--

local BookshelfWidget = require("desktop")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local ProgressUploader = require("progressuploader")
local UIManager = require("ui/uimanager")
local WereadBridge = require("wereadbridge")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Annotations = require("weread.lib.annotations")
local logger = require("logger")
local _ = require("gettext")

local function formatStorageBytes(bytes)
    return require("weread.lib.storage").format_bytes(bytes)
end

local WeReadDesktop = WidgetContainer:extend{
    name = "wereaddesktop",
    is_doc_only = false,
}

-- One-time migration of reader settings written under the pre-rename
-- "kodesktop_*" keys.
local SETTINGS_MIGRATION = {
    "show_on_start", "progress_sync", "debug_screenshot",
}
local function migrateSettings()
    if G_reader_settings:readSetting("wereaddesktop_migrated") then
        return
    end
    for _, key in ipairs(SETTINGS_MIGRATION) do
        local value = G_reader_settings:readSetting("kodesktop_" .. key)
        if value ~= nil then
            G_reader_settings:saveSetting("wereaddesktop_" .. key, value)
            G_reader_settings:delSetting("kodesktop_" .. key)
        end
    end
    G_reader_settings:saveSetting("wereaddesktop_migrated", true)
    G_reader_settings:flush()
end

-- Read the radio and connection state through NetworkMgr's own refresh
-- path. Keeping both values matters: Wi-Fi can be enabled without being
-- associated with a network, which the stock KOReader menu treats as a
-- third state (connect or turn off), not as a plain on/off toggle.
local function networkState()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr then
        return false, false, nil
    end
    if type(NetworkMgr.queryNetworkState) == "function" then
        pcall(NetworkMgr.queryNetworkState, NetworkMgr)
    end
    local function read(primary, fallback)
        local method = NetworkMgr[primary] or NetworkMgr[fallback]
        if type(method) ~= "function" then
            return false
        end
        local ok_value, value = pcall(method, NetworkMgr)
        return ok_value and value == true
    end
    local wifi_on = read("getWifiState", "isWifiOn")
    local connected = wifi_on and read("getConnectionState", "isConnected")
    return wifi_on, connected, NetworkMgr
end

function WeReadDesktop:init()
    -- The vendored WeRead protocol layer salts its signatures with
    -- math.random (protocol.lua ts/rn fields).
    math.randomseed(os.time())
    migrateSettings()
    -- In the reader context only the WeRead progress upload runs; the
    -- desktop itself (and its menu/callbacks) stays file-manager-only.
    if self.ui.document then
        self:hookShowFileManager()
        self:hookWeReadFootnotePopups()
        self:hookWeReadFinishedStatus()
        self:initProgressSync()
        if self.ui.menu then
            self.ui.menu:registerToMainMenu(self)
        end
        return
    end
    -- WeRead shelf integration; the bridge doubles as the QRLogin host,
    -- so the host callbacks below live on this module.
    self.weread = WereadBridge:new(self)
    self.ui.menu:registerToMainMenu(self)
    -- Show the desktop after the FileManager has been instantiated and
    -- shown at startup (only FileManager has registerPostInitCallback).
    if self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function()
            -- nextTick: postInitCallbacks run before UIManager:show(FM),
            -- defer so the desktop lands on top of the file manager.
            UIManager:nextTick(function()
                if self:showOnStart() then
                    self:showDesktop()
                end
            end)
        end)
    end
end

function WeReadDesktop:showOnStart()
    if G_reader_settings:readSetting("wereaddesktop_show_on_start") == false then
        return false
    end
    -- Show whenever the file manager is the start screen; don't cover
    -- history/favorites/etc. when the user picked another "Start with"
    -- mode that opens an FM module on top.
    local start_with = G_reader_settings:readSetting("start_with") or "filemanager"
    return start_with ~= "history" and start_with ~= "favorites"
        and start_with ~= "folder_shortcuts"
end

-- Hook ReaderUI:showFileManager (once per process) so the desktop lands
-- on top of the freshly re-created file manager *in the same task*.
--
-- Background: the file manager is fully closed when a book opens
-- (FileManager:onShowingReader → UIManager:close), so while reading,
-- FileManager.instance is nil. When the book closes, ReaderUI re-creates
-- the FM via showFileManager → showFiles → UIManager:show(FM), and the
-- repaint at the end of that event-loop iteration paints the FM before
-- any nextTick callback gets a chance to stack the desktop above it —
-- that gap was the brief flash of the file list on book close. Showing
-- the desktop here, synchronously after the FM is stacked, makes the
-- same repaint paint the desktop on top instead.
function WeReadDesktop:hookShowFileManager()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or ReaderUI._wereaddesktop_hooked then
        return
    end
    ReaderUI._wereaddesktop_hooked = true
    local original = ReaderUI.showFileManager
    ReaderUI.showFileManager = function(reader, ...)
        local ret = original(reader, ...)
        if G_reader_settings:readSetting("wereaddesktop_show_on_start") == false then
            return ret
        end
        local fm_ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        local fm = fm_ok and FileManager.instance
        if fm and fm.wereaddesktop then
            fm.wereaddesktop:showDesktop()
        end
        return ret
    end
end

local function readBookStatus(reader_status)
    local doc_settings = reader_status.ui and reader_status.ui.doc_settings
    if not doc_settings then
        return nil
    end
    local summary
    if type(doc_settings.readSetting) == "function" then
        local ok, value = pcall(doc_settings.readSetting, doc_settings, "summary")
        if ok then
            summary = value
        end
    elseif type(doc_settings.summary) == "table" then
        summary = doc_settings.summary
    end
    return type(summary) == "table" and summary.status or nil
end

-- KOReader's end-of-book dialog only changes summary.status locally and
-- emits no event. Wrap that single mutation point once, preserving the
-- original behavior, and notify the open WeRead document after it changed.
function WeReadDesktop:hookWeReadFinishedStatus()
    local ok, ReaderStatus = pcall(
        require, "apps/reader/modules/readerstatus"
    )
    if not ok or ReaderStatus._wereaddesktop_finish_hooked
        or type(ReaderStatus.markBook) ~= "function" then
        return
    end
    ReaderStatus._wereaddesktop_finish_hooked = true
    local original = ReaderStatus.markBook
    ReaderStatus.markBook = function(reader_status, ...)
        local previous = readBookStatus(reader_status)
        local result = original(reader_status, ...)
        local current = readBookStatus(reader_status)
        local document = reader_status.ui and reader_status.ui.document
        local handler = document
            and document._wereaddesktop_finish_handler
        if current ~= previous
            and (current == "complete" or current == "reading")
            and type(handler) == "function" then
            local call_ok, err = pcall(handler, current == "complete")
            if not call_ok then
                logger.warn("wereaddesktop: finished-status handler failed:",
                    tostring(err))
            end
        end
        return result
    end
end

-- KOReader only attempts its native footnote popup when the global
-- "show footnotes in popup" preference is enabled. For a WeRead EPUB we
-- know publisher note markers are real footnotes, so enable detection for
-- that document without changing the user's global KOReader preference.
function WeReadDesktop:hookWeReadFootnotePopups()
    local ok, ReaderLink = pcall(require, "apps/reader/modules/readerlink")
    if not ok or ReaderLink._wereaddesktop_footnote_hooked
        or type(ReaderLink.showLinkBox) ~= "function" then
        return
    end
    ReaderLink._wereaddesktop_footnote_hooked = true
    local original = ReaderLink.showLinkBox
    ReaderLink.showLinkBox = function(reader_link, link, allow_footnote_popup)
        local document = reader_link.ui and reader_link.ui.document
        if document and document._wereaddesktop_footnotes then
            allow_footnote_popup = true
        end
        return original(reader_link, link, allow_footnote_popup)
    end
    if type(ReaderLink.onGotoLink) == "function" then
        local original_goto = ReaderLink.onGotoLink
        ReaderLink.onGotoLink = function(reader_link, link, ...)
            local url = type(link) == "table" and link.xpointer or link
            local document = reader_link.ui and reader_link.ui.document
            local handler = document
                and document._wereaddesktop_thought_handler
            if type(url) == "string"
                and url:find("wrthought://", 1, true) == 1
                and type(handler) == "function" then
                return handler(url)
            end
            return original_goto(reader_link, link, ...)
        end
    end
end

-- Called in the reader context (registered modules receive ReaderUI's
-- CloseDocument event): one final progress upload while the document is
-- still alive, plus a desktop re-show for the (uncommon) case that the
-- file manager survived while reading. The usual close path goes
-- through the showFileManager hook above.
function WeReadDesktop:onCloseDocument()
    if self.progress_uploader
        and G_reader_settings:readSetting("wereaddesktop_progress_sync") ~= false then
        self.progress_uploader:onCloseDocument(self:readerFraction())
    end
    if G_reader_settings:readSetting("wereaddesktop_show_on_start") == false then
        return
    end
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok then
        return
    end
    local fm = FileManager.instance
    -- fm is nil when KOReader is exiting or started straight into the
    -- reader: on "Exit", the FileManager is closed *before* the reader
    -- (its exit handler is synchronous, the reader's is deferred), and
    -- FileManager:onCloseWidget clears FileManager.instance — which is
    -- exactly what keeps us from resurrecting a desktop during shutdown.
    if fm and fm.wereaddesktop then
        fm.wereaddesktop:showDesktop()
    end
end

----------------------------------------------------------------
-- WeRead progress sync. The reader instance captures live positions; either
-- reader or file-manager context can replay durable offline entries.
--
-- The plugin module is instantiated in both the file manager and the
-- reader; in the reader only this section is active. All uploads run
-- on UIManager-deferred tasks and fail silently.
----------------------------------------------------------------

local PENDING_FINISH_SYNC_KEY = "pending_finish_sync"

-- Reader-context setup: build a dedicated bridge (settings + client,
-- no UI) and the two-way progress sync.
function WeReadDesktop:getReaderBridge()
    if not self.reader_bridge then
        self.reader_bridge = WereadBridge:new(self)
    end
    return self.reader_bridge
end

function WeReadDesktop:initProgressSync()
    if G_reader_settings:readSetting("wereaddesktop_progress_sync") == false then
        logger.info("wereaddesktop: progress sync disabled by setting")
        return
    end
    local bridge = self:getReaderBridge()
    if not bridge:isLoggedIn() then
        logger.warn("wereaddesktop: progress sync not started: WeRead login missing")
        return
    end
    logger.info("wereaddesktop: progress sync initialized")
    self.progress_uploader = ProgressUploader:new{
        settings = bridge.settings,
        client = bridge.client,
        scheduler = UIManager,
        get_fraction = function()
            return self:readerFraction()
        end,
        get_page = function()
            return self:readerPage()
        end,
        get_page_count = function()
            return self:readerPageCount()
        end,
        get_toc = function()
            return self:readerToc()
        end,
        is_online = function()
            return self:isNetworkConnected()
        end,
        on_uploaded = function(book_id, position)
            bridge:updateShelfProgress(book_id, position and position.fraction)
        end,
        on_sync_to = function(fraction)
            return self:gotoFraction(fraction)
        end,
        on_sync_to_page = function(page)
            return self:gotoPage(page)
        end,
    }
end

-- Jump the open document to a 1-based page number (used when the cloud
-- progress is ahead and resolved to a TOC page). Works for both paged
-- and rolling documents via the GotoPage event.
function WeReadDesktop:gotoPage(page)
    local document = self.ui and self.ui.document
    page = tonumber(page)
    if not document or not page then
        return false
    end
    local total
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then
            total = tonumber(value)
        end
    end
    page = math.floor(page + 0.5)
    if total and total > 0 then
        page = math.max(1, math.min(total, page))
    end
    if page < 1 then
        return false
    end
    self.ui:handleEvent(Event:new("GotoPage", page))
    self:showTransientInfo(string.format(
        _("已同步到云端最新进度（第 %d 页）"), page), 2)
    return true
end

-- Jump the open document to a whole-book fraction (used when the cloud
-- progress is ahead of the local one). Works for both paged and rolling
-- documents via the GotoPage event.
function WeReadDesktop:gotoFraction(fraction)
    local document = self.ui and self.ui.document
    if not document or type(fraction) ~= "number" then
        return false
    end
    local total
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then
            total = tonumber(value)
        end
    end
    if not total or total <= 0 then
        return false
    end
    local page = math.floor(fraction * total + 0.5)
    page = math.max(1, math.min(total, page))
    self.ui:handleEvent(Event:new("GotoPage", page))
    self:showTransientInfo(string.format(
        _("已同步到云端最新进度 %d%%"), math.floor(fraction * 100 + 0.5)), 2)
    return true
end

-- Current reading position of the open document as a 0..1 fraction
-- (footer percent first, then page/page-count, like the source plugin).
function WeReadDesktop:readerFraction()
    local document = self.ui and self.ui.document
    if not document then
        return nil
    end
    local footer = self.ui.view and self.ui.view.footer
    local percent = footer and tonumber(footer.percent_finished)
    if percent then
        if percent > 1 then
            percent = percent / 100
        end
        return math.max(0, math.min(1, percent))
    end
    local page, total
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then
            page = tonumber(value)
        end
    end
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then
            total = tonumber(value)
        end
    end
    if page and total and total > 0 then
        return math.max(0, math.min(1, page / total))
    end
    return nil
end

-- Current 1-based page of the open document (nil when unavailable).
function WeReadDesktop:readerPage()
    local document = self.ui and self.ui.document
    if not document or type(document.getCurrentPage) ~= "function" then
        return nil
    end
    local ok, value = pcall(document.getCurrentPage, document)
    return ok and tonumber(value) or nil
end

-- Total page count of the open document (nil when unavailable).
function WeReadDesktop:readerPageCount()
    local document = self.ui and self.ui.document
    if not document or type(document.getPageCount) ~= "function" then
        return nil
    end
    local ok, value = pcall(document.getPageCount, document)
    return ok and tonumber(value) or nil
end

-- TOC entries of the open document in document order, each carrying at
-- least a numeric .page field (nil when unavailable). The raw table is
-- returned on purpose: the uploader memoizes its chapter alignment on
-- table identity, and KOReader replaces this table when the layout
-- (and thus the page numbers) changes. The progress sync pairs these
-- with the book's WeRead chapter catalog; both are in book order
-- because the download packs one chapter file (and one TOC entry) per
-- chapter.
function WeReadDesktop:readerToc()
    local toc = self.ui and self.ui.toc
    if not toc then
        return nil
    end
    if type(toc.toc) ~= "table" or #toc.toc == 0 then
        -- Force a fill (normally done at document open); getTocTicks is
        -- the cheapest public filler.
        if type(toc.getTocTicks) == "function" then
            pcall(function()
                toc:getTocTicks(1)
            end)
        end
    end
    local items = toc.toc
    if type(items) ~= "table" or #items == 0 then
        return nil
    end
    for _i, item in ipairs(items) do
        if tonumber(item.page) == nil then
            return nil
        end
    end
    return items
end

-- Non-blocking link-state check (unlike isNetworkOnline, which may do a
-- blocking DNS lookup); used by the reader-context progress sync.
function WeReadDesktop:isNetworkConnected()
    local _wifi_on, connected, NetworkMgr = networkState()
    if not NetworkMgr then
        return self:isNetworkOnline()
    end
    return connected
end

function WeReadDesktop:onReaderReady()
    local path = self.ui.document and self.ui.document.file
    local book_id
    if self.progress_uploader then
        book_id = self.progress_uploader:onReaderReady(path)
    end
    if self.ui.document then
        local path_book_id = type(path) == "string"
            and path:match("/weread/cache/([^/]+)/") or nil
        book_id = book_id or path_book_id
        local is_weread = book_id ~= nil
            or (type(path) == "string"
                and path:find("/weread/cache/", 1, true) ~= nil)
        self.current_weread_book_id = book_id
        self.ui.document._wereaddesktop_footnotes = is_weread
        self.ui.document._wereaddesktop_thought_handler =
            is_weread and function(url)
                return self:openThoughtLink(url)
            end or nil
        self.ui.document._wereaddesktop_finish_handler =
            is_weread and book_id and function(finished)
                return self:onLocalFinishedStatus(finished)
            end or nil
        if is_weread and book_id then
            self:syncPendingFinishedStatus(book_id)
        end
    end
end

function WeReadDesktop:finishStatusBridge()
    return self.reader_bridge or self.weread or self:getReaderBridge()
end

function WeReadDesktop:savePendingFinishedStatus(settings, pending)
    settings:set(PENDING_FINISH_SYNC_KEY, pending)
    settings:flush()
end

-- Persist before attempting the network request so a suspend, close or
-- transient failure cannot lose the user's latest choice.
function WeReadDesktop:onLocalFinishedStatus(finished)
    local book_id = self.current_weread_book_id
    if not book_id then
        return false
    end
    book_id = tostring(book_id)
    finished = finished == true
    local bridge = self:finishStatusBridge()
    local settings = bridge and bridge.settings
    if not settings then
        logger.warn("wereaddesktop: cannot queue finished status:",
            "book_id=", book_id, "settings=missing")
        return false
    end
    if type(settings.refresh) == "function" then
        settings:refresh(PENDING_FINISH_SYNC_KEY)
    end
    local pending = settings:get(PENDING_FINISH_SYNC_KEY, {})
    if type(pending) ~= "table" then
        pending = {}
    end
    local account = settings:get("account", {})
    pending[book_id] = {
        finished = finished,
        updated_at = os.time(),
        user_vid = type(account) == "table"
            and tostring(account.user_vid or "") or "",
    }
    self:savePendingFinishedStatus(settings, pending)
    logger.info("wereaddesktop: queued finished status:",
        "book_id=", book_id, "finished=", tostring(finished))

    if not bridge.isLoggedIn or not bridge:isLoggedIn() then
        logger.warn("wereaddesktop: finished status waiting for login:",
            "book_id=", book_id)
        self:showTransientInfo(
            _("已在本地标记；登录微信读书后将自动同步。"), 3)
        return true
    end
    if not self:isNetworkConnected() then
        logger.info("wereaddesktop: finished status waiting for network:",
            "book_id=", book_id)
        self:showTransientInfo(
            _("已在本地标记；连接网络后将自动同步。"), 3)
        return true
    end
    self:syncPendingFinishedStatus(book_id)
    return true
end

function WeReadDesktop:syncPendingFinishedStatus(book_id)
    local bridge = self:finishStatusBridge()
    if not bridge or not bridge.settings or not bridge.client
        or type(bridge.client.mark_book_finished) ~= "function"
        or not bridge.isLoggedIn or not bridge:isLoggedIn()
        or not self:isNetworkConnected() then
        return false
    end
    local settings = bridge.settings
    if type(settings.refresh) == "function" then
        settings:refresh(PENDING_FINISH_SYNC_KEY)
    end
    local pending = settings:get(PENDING_FINISH_SYNC_KEY, {})
    if type(pending) ~= "table" then
        return false
    end
    local current_account = settings:get("account", {})
    local current_vid = type(current_account) == "table"
        and tostring(current_account.user_vid or "") or ""
    local ids = {}
    if book_id ~= nil then
        ids[1] = tostring(book_id)
    else
        for pending_book_id in pairs(pending) do
            ids[#ids + 1] = tostring(pending_book_id)
        end
    end
    self.finished_status_requests = self.finished_status_requests or {}
    local scheduled = false
    for _index, pending_book_id in ipairs(ids) do
        local entry = pending[pending_book_id]
        if type(entry) == "table"
            and not self.finished_status_requests[pending_book_id] then
            local queued_vid = tostring(entry.user_vid or "")
            if queued_vid ~= "" and current_vid ~= ""
                and queued_vid ~= current_vid then
                pending[pending_book_id] = nil
                self:savePendingFinishedStatus(settings, pending)
                logger.warn("wereaddesktop: discarded finished status for"
                    .. " another account:", "book_id=", pending_book_id)
            else
                scheduled = true
                self.finished_status_requests[pending_book_id] = true
                local target_finished = entry.finished == true
                UIManager:scheduleIn(0.1, function()
                    local call_ok, ok, _result, err = pcall(
                        bridge.client.mark_book_finished,
                        bridge.client,
                        pending_book_id,
                        target_finished
                    )
                    self.finished_status_requests[pending_book_id] = nil
                    if call_ok and ok == true then
                        if type(settings.refresh) == "function" then
                            settings:refresh(PENDING_FINISH_SYNC_KEY)
                        end
                        local latest = settings:get(
                            PENDING_FINISH_SYNC_KEY, {})
                        local current = type(latest) == "table"
                            and latest[pending_book_id] or nil
                        if type(current) == "table"
                            and current.finished == target_finished then
                            latest[pending_book_id] = nil
                            self:savePendingFinishedStatus(settings, latest)
                            if type(bridge.updateShelfFinished) == "function" then
                                bridge:updateShelfFinished(
                                    pending_book_id, target_finished)
                            end
                            logger.info(
                                "wereaddesktop: finished status synced:",
                                "book_id=", pending_book_id,
                                "finished=", tostring(target_finished))
                            self:showTransientInfo(target_finished
                                and _("已同步到微信读书：已读完")
                                or _("已同步到微信读书：继续阅读"), 2)
                        else
                            self:syncPendingFinishedStatus(pending_book_id)
                        end
                    else
                        local reason = call_ok and err or ok
                        logger.warn(
                            "wereaddesktop: finished status sync failed:",
                            "book_id=", pending_book_id,
                            "finished=", tostring(target_finished),
                            "error=", tostring(reason))
                        self:showTransientInfo(
                            _("云端状态同步失败，联网后将自动重试。"), 3)
                    end
                end)
            end
        end
    end
    return scheduled
end

local THOUGHT_CACHE_MAX_AGE = 24 * 60 * 60

function WeReadDesktop:thoughtBookDir(book_id)
    if tostring(book_id) == tostring(self.current_weread_book_id) then
        local path = self.ui.document and self.ui.document.file
        local dir = type(path) == "string" and path:match("^(.*)/[^/]+$")
        if dir then
            return dir
        end
    end
    local bridge = self:getReaderBridge()
    local Content = require("weread.lib.content")
    return Content.book_cache_dir(bridge.settings, book_id)
end

function WeReadDesktop:readThoughtCache(payload)
    local ThoughtDB = require("weread.lib.thought_db")
    local db = ThoughtDB.open(self:thoughtBookDir(payload.book_id))
    if not db then
        return nil
    end
    local ok, cached = pcall(
        ThoughtDB.getRange, db, payload.chapter_uid, payload.range
    )
    ThoughtDB.close(db)
    if not ok then
        logger.warn("wereaddesktop: thought cache read failed:",
            "book_id=", tostring(payload.book_id),
            "chapter_uid=", tostring(payload.chapter_uid),
            "range=", tostring(payload.range),
            "error=", tostring(cached))
        return nil
    end
    return cached
end

function WeReadDesktop:writeThoughtCache(payload, range_review, append)
    local ThoughtDB = require("weread.lib.thought_db")
    local db = ThoughtDB.open(self:thoughtBookDir(payload.book_id))
    if not db then
        return false
    end
    local call_ok, ok = pcall(
        ThoughtDB.putRange, db, payload.chapter_uid, range_review, {
            append = append == true,
            fetched_at = os.time(),
        }
    )
    ThoughtDB.close(db)
    return call_ok and ok == true
end

local function cleanThoughtText(value)
    value = tostring(value or ""):gsub("\r", "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

function WeReadDesktop:formatThoughts(cached)
    local items = cached and cached.items or {}
    if #items == 0 then
        return _("这里暂时没有书友想法。")
    end
    local lines = {}
    local abstract = cleanThoughtText(items[1].abstract)
    if abstract ~= "" then
        lines[#lines + 1] = _("原文")
        lines[#lines + 1] = abstract
        lines[#lines + 1] = ""
    end
    for index, item in ipairs(items) do
        local author = cleanThoughtText(item.author)
        if author == "" then
            author = _("匿名")
        end
        local likes = tonumber(item.likes_count) or 0
        lines[#lines + 1] = string.format(
            "%d. %s · %s %d", index, author, _("赞"), likes
        )
        lines[#lines + 1] = cleanThoughtText(item.content)
        if index < #items then
            lines[#lines + 1] = ""
        end
    end
    return table.concat(lines, "\n")
end

function WeReadDesktop:showThoughts(payload, cached)
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local actions = {}
    if cached and cached.has_more then
        actions[#actions + 1] = {
            text = _("加载更多"),
            callback = function()
                UIManager:close(viewer)
                self:fetchThoughtRange(payload, {
                    append = true,
                    max_idx = cached.max_idx,
                    sync_key = cached.sync_key,
                })
            end,
        }
    end
    local stale = not cached or not cached.fetched_at
        or os.time() - cached.fetched_at > THOUGHT_CACHE_MAX_AGE
    if stale then
        actions[#actions + 1] = {
            text = _("刷新"),
            callback = function()
                UIManager:close(viewer)
                self:fetchThoughtRange(payload)
            end,
        }
    end
    local buttons = nil
    if #actions > 0 then
        buttons = { actions }
    end
    viewer = TextViewer:new{
        modal = true,
        title = _("书友想法"),
        text = self:formatThoughts(cached),
        show_menu = false,
        buttons_table = buttons,
        add_default_buttons = buttons ~= nil,
    }
    self:showOverlay(viewer)
end

function WeReadDesktop:fetchThoughtRange(payload, opts)
    opts = opts or {}
    local key = table.concat({
        payload.book_id, tostring(payload.chapter_uid), payload.range,
    }, ":")
    self.thought_requests = self.thought_requests or {}
    if self.thought_requests[key] then
        self:showTransientInfo(_("正在加载书友想法…"), 1)
        return true
    end
    if not self:isNetworkOnline() then
        self:showInfo(_("加载书友想法失败：无网络连接，请连接 Wi-Fi 后重试。"))
        return true
    end
    local bridge = self:getReaderBridge()
    if not bridge:isLoggedIn() then
        self:showInfo(_("加载书友想法失败：请先登录微信读书。"))
        return true
    end

    self.thought_requests[key] = true
    self:showBusy(_("正在加载书友想法…"))
    UIManager:scheduleIn(0.1, function()
        local call_ok, ok, result, err = pcall(
            bridge.client.get_chapter_reviews_batch,
            bridge.client,
            payload.book_id,
            payload.chapter_uid,
            {
                {
                    range = payload.range,
                    maxIdx = tonumber(opts.max_idx) or 0,
                    count = 20,
                    synckey = tonumber(opts.sync_key) or 0,
                },
            }
        )
        self.thought_requests[key] = nil
        self:closeBusy()
        if not call_ok or not ok then
            local reason = call_ok and err or ok
            logger.warn("wereaddesktop: lazy thought fetch failed:",
                "book_id=", tostring(payload.book_id),
                "chapter_uid=", tostring(payload.chapter_uid),
                "range=", payload.range,
                "error=", tostring(reason))
            self:showInfo(_("加载书友想法失败，请稍后重试。"))
            return
        end
        local range_review
        for _, review in ipairs(
            type(result) == "table" and result.reviews or {}
        ) do
            if review.range == payload.range then
                range_review = review
                break
            end
        end
        range_review = range_review or {
            range = payload.range,
            pageReviews = {},
            hasMore = false,
            maxIdx = 0,
            synckey = 0,
            totalCount = 0,
        }
        self:writeThoughtCache(payload, range_review, opts.append)
        local cached = self:readThoughtCache(payload)
        if not cached then
            cached = {
                items = Annotations.buildThoughtPopupItems(range_review),
                fetched_at = os.time(),
                max_idx = tonumber(range_review.maxIdx) or 0,
                sync_key = tonumber(range_review.synckey) or 0,
                total_count = tonumber(range_review.totalCount) or 0,
                has_more = range_review.hasMore == true
                    or tonumber(range_review.hasMore) == 1,
            }
        end
        logger.info("wereaddesktop: lazy thought loaded:",
            "book_id=", tostring(payload.book_id),
            "chapter_uid=", tostring(payload.chapter_uid),
            "range=", payload.range,
            "items=", tostring(#(cached.items or {})),
            "has_more=", tostring(cached.has_more == true))
        self:showThoughts(payload, cached)
    end)
    return true
end

function WeReadDesktop:openThoughtLink(url)
    local payload = Annotations.parseThoughtURL(url)
    if not payload then
        return false
    end
    local cached = self:readThoughtCache(payload)
    logger.info("wereaddesktop: thought link tapped:",
        "book_id=", tostring(payload.book_id),
        "chapter_uid=", tostring(payload.chapter_uid),
        "range=", payload.range,
        "cache=", cached and "hit" or "miss")
    if cached then
        self:showThoughts(payload, cached)
        return true
    end
    return self:fetchThoughtRange(payload)
end

function WeReadDesktop:readBookReviewCache(book_id)
    local ThoughtDB = require("weread.lib.thought_db")
    local db = ThoughtDB.open(self:thoughtBookDir(book_id))
    if not db then
        return nil
    end
    local ok, cached = pcall(ThoughtDB.getBookReviews, db)
    ThoughtDB.close(db)
    if not ok then
        logger.warn("wereaddesktop: book review cache read failed:",
            "book_id=", tostring(book_id), "error=", tostring(cached))
        return nil
    end
    return cached
end

function WeReadDesktop:writeBookReviewCache(book_id, page, append)
    local ThoughtDB = require("weread.lib.thought_db")
    local db = ThoughtDB.open(self:thoughtBookDir(book_id))
    if not db then
        return false
    end
    local call_ok, ok = pcall(ThoughtDB.putBookReviews, db, page, {
        append = append == true,
        fetched_at = os.time(),
    })
    ThoughtDB.close(db)
    return call_ok and ok == true
end

local function normalizeBookReviewPage(result)
    local page = {
        items = {},
        sync_key = tonumber(result and result.synckey) or 0,
        total_count = tonumber(result and result.reviewsCnt) or 0,
        has_more = result and (result.reviewsHasMore == true
            or tonumber(result.reviewsHasMore) == 1) or false,
        max_idx = 0,
    }
    for sequence, entry in ipairs(
        type(result) == "table" and result.reviews or {}
    ) do
        local wrapper = type(entry.review) == "table" and entry.review or {}
        local review = type(wrapper.review) == "table"
            and wrapper.review or wrapper
        local author = type(review.author) == "table" and review.author or {}
        local index = tonumber(entry.idx) or sequence
        page.max_idx = math.max(page.max_idx, index)
        page.items[#page.items + 1] = {
            item_index = index,
            review_id = tostring(
                wrapper.reviewId or review.reviewId or ("idx-" .. index)
            ),
            author = tostring(author.name or author.nick or "匿名"),
            content = cleanThoughtText(review.content or ""),
            rating = tonumber(review.newRatingLevel) or 0,
            likes_count = tonumber(wrapper.likesCount
                or review.likesCount) or 0,
            created_at = tonumber(review.createTime) or 0,
        }
    end
    return page
end

local BOOK_REVIEW_RATING = {
    [1] = _("推荐本书"),
    [2] = _("认为一般"),
    [3] = _("不推荐"),
}

function WeReadDesktop:formatBookReviews(cached)
    local items = cached and cached.items or {}
    if #items == 0 then
        return _("这里暂时没有书友点评。")
    end
    local lines = {}
    for index, item in ipairs(items) do
        local author = cleanThoughtText(item.author)
        if author == "" then
            author = _("匿名")
        end
        local rating = BOOK_REVIEW_RATING[tonumber(item.rating)]
        local meta = author
        if rating then
            meta = meta .. " · " .. rating
        end
        meta = meta .. string.format(" · %s %d",
            _("赞"), tonumber(item.likes_count) or 0)
        lines[#lines + 1] = string.format("%d. %s", index, meta)
        lines[#lines + 1] = cleanThoughtText(item.content)
        if index < #items then
            lines[#lines + 1] = ""
        end
    end
    return table.concat(lines, "\n")
end

function WeReadDesktop:showBookReviews(book_id, cached)
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local actions = {}
    if cached and cached.has_more then
        actions[#actions + 1] = {
            text = _("加载更多"),
            callback = function()
                UIManager:close(viewer)
                self:fetchBookReviews(book_id, {
                    append = true,
                    max_idx = cached.max_idx,
                    sync_key = cached.sync_key,
                })
            end,
        }
    end
    local stale = not cached or not cached.fetched_at
        or os.time() - cached.fetched_at > THOUGHT_CACHE_MAX_AGE
    if stale then
        actions[#actions + 1] = {
            text = _("刷新"),
            callback = function()
                UIManager:close(viewer)
                self:fetchBookReviews(book_id)
            end,
        }
    end
    local buttons = #actions > 0 and { actions } or nil
    viewer = TextViewer:new{
        modal = true,
        title = _("书友点评"),
        text = self:formatBookReviews(cached),
        show_menu = false,
        buttons_table = buttons,
        add_default_buttons = buttons ~= nil,
    }
    self:showOverlay(viewer)
end

function WeReadDesktop:fetchBookReviews(book_id, opts)
    opts = opts or {}
    self.book_review_requests = self.book_review_requests or {}
    local key = tostring(book_id)
    if self.book_review_requests[key] then
        self:showTransientInfo(_("正在加载书友点评…"), 1)
        return true
    end
    if not self:isNetworkOnline() then
        self:showInfo(_("加载书友点评失败：无网络连接，请连接 Wi-Fi 后重试。"))
        return true
    end
    local bridge = self:getReaderBridge()
    if not bridge:isLoggedIn() then
        self:showInfo(_("加载书友点评失败：请先登录微信读书。"))
        return true
    end

    self.book_review_requests[key] = true
    self:showBusy(_("正在加载书友点评…"))
    UIManager:scheduleIn(0.1, function()
        local call_ok, ok, result, err = pcall(
            bridge.client.get_book_reviews,
            bridge.client,
            book_id,
            {
                max_idx = tonumber(opts.max_idx) or 0,
                sync_key = tonumber(opts.sync_key) or 0,
                count = 20,
            }
        )
        self.book_review_requests[key] = nil
        self:closeBusy()
        if not call_ok or not ok then
            local reason = call_ok and err or ok
            logger.warn("wereaddesktop: book review fetch failed:",
                "book_id=", tostring(book_id),
                "error=", tostring(reason))
            self:showInfo(_("加载书友点评失败，请稍后重试。"))
            return
        end
        local page = normalizeBookReviewPage(result)
        self:writeBookReviewCache(book_id, page, opts.append)
        local cached = self:readBookReviewCache(book_id)
        if not cached then
            cached = page
            cached.fetched_at = os.time()
        end
        logger.info("wereaddesktop: book reviews loaded:",
            "book_id=", tostring(book_id),
            "items=", tostring(#page.items),
            "has_more=", tostring(page.has_more == true))
        self:showBookReviews(book_id, cached)
    end)
    return true
end

function WeReadDesktop:openBookReviews()
    local book_id = self.current_weread_book_id
    if not book_id then
        self:showInfo(_("当前书籍不是通过微读下载的微信读书书籍。"))
        return false
    end
    local cached = self:readBookReviewCache(book_id)
    if cached then
        self:showBookReviews(book_id, cached)
        return true
    end
    return self:fetchBookReviews(book_id)
end

function WeReadDesktop:onPageUpdate()
    if self.progress_uploader
        and G_reader_settings:readSetting("wereaddesktop_progress_sync") ~= false then
        self.progress_uploader:onPageUpdate(self:readerFraction())
    end
end

-- Rolling documents (crengine: EPUB etc.) emit "PosUpdate" on page
-- turns instead of "PageUpdate"; handle both, like the bundled
-- statistics plugin does — otherwise WeRead EPUBs never sync progress
-- while reading.
function WeReadDesktop:onPosUpdate()
    self:onPageUpdate()
end

-- Forward device lifecycle events so reading-time reports exclude time
-- spent in screensaver/suspend. ProgressUploader keeps these idempotent.
function WeReadDesktop:onSuspend()
    if self.progress_uploader then
        self.progress_uploader:onSuspend()
    end
end

function WeReadDesktop:onResume()
    if self.progress_uploader then
        self.progress_uploader:onResume()
    end
end

function WeReadDesktop:refreshDesktop()
    if self.desktop_widget then
        self:refreshWifiAction()
        self.desktop_widget:setData(self:collectData())
    end
end

function WeReadDesktop:onNetworkConnected()
    self:refreshDesktop()
    self:syncPendingFinishedStatus()
    -- Progress is lightweight and safe to sync silently. Historical offline
    -- reading time stays local until the user starts its paced replay.
    self:syncPendingReadingProgress{ progress_only = true }
end

-- Replay every durable reading-progress entry when connectivity returns. An
-- open book reuses its live uploader; closed books use short-lived headless
-- uploaders so the user does not need to reopen each title manually.
function WeReadDesktop:syncPendingReadingProgress(options)
    options = options or {}
    if G_reader_settings:readSetting("wereaddesktop_progress_sync") == false
        or not self:isNetworkConnected() then
        return false
    end
    local bridge = self.reader_bridge or self.weread
    if not bridge or not bridge.settings or not bridge.client
        or not bridge.isLoggedIn or not bridge:isLoggedIn() then
        return false
    end
    local settings = bridge.settings
    if type(settings.refresh) == "function" then
        settings:refresh("books")
    end
    local books = settings:get("books", {})
    local ids = {}
    for book_id, book in pairs(type(books) == "table" and books or {}) do
        if type(book) == "table"
            and type(book.pending_upload_position) == "table" then
            ids[#ids + 1] = tostring(book_id)
        end
    end
    table.sort(ids)
    self.pending_progress_uploaders = self.pending_progress_uploaders or {}
    local scheduled = false
    for _, book_id in ipairs(ids) do
        local active = self.progress_uploader
        if active and tostring(active.book_id or "") == book_id then
            scheduled = active:retryPending(book_id, options) or scheduled
        elseif not self.pending_progress_uploaders[book_id] then
            local uploader
            uploader = ProgressUploader:new{
                settings = settings,
                client = bridge.client,
                scheduler = UIManager,
                is_online = function()
                    return self:isNetworkConnected()
                end,
                heartbeat_interval = false,
                on_uploaded = function(uploaded_book_id, position)
                    if type(bridge.updateShelfProgress) == "function" then
                        bridge:updateShelfProgress(uploaded_book_id,
                            position and position.fraction)
                    end
                end,
                on_finished = function(finished_book_id)
                    finished_book_id = tostring(finished_book_id or book_id)
                    if self.pending_progress_uploaders[finished_book_id]
                        == uploader then
                        self.pending_progress_uploaders[finished_book_id] = nil
                    end
                    self:refreshDesktop()
                end,
            }
            self.pending_progress_uploaders[book_id] = uploader
            if uploader:retryPending(book_id, options) then
                scheduled = true
            else
                self.pending_progress_uploaders[book_id] = nil
            end
        end
    end
    return scheduled
end

-- Manually drain queued reading time. Books are processed one at a time and
-- separated by the same 61-second accounting window used between chunks;
-- parallel book queues would otherwise make the server credit only one. The
-- coordinator snapshots the backlog at start, while time read during this run
-- stays in the normal pending bucket for a later pass.
function WeReadDesktop:startPendingReadingTimeUpload()
    if self.pending_time_upload_active then
        self:showTransientInfo(_("离线阅读时长正在上报中"), 2)
        return false
    end
    if not self:isNetworkConnected() then
        self:showInfo(_("无法上报：请先连接 Wi-Fi。"))
        return false
    end
    local bridge = self.reader_bridge or self.weread
    if not bridge or not bridge.settings or not bridge.client
        or not bridge.isLoggedIn or not bridge:isLoggedIn() then
        self:showInfo(_("无法上报：请先登录微信读书。"))
        return false
    end
    local begin_ok, replay_token, ids, begin_err = pcall(
        ProgressUploader.beginTimeReplay, bridge.settings)
    if not begin_ok then
        logger.err("wereaddesktop: offline-time coordinator failed:",
            tostring(replay_token))
        self:showInfo(_("离线阅读时长上报未能启动，可稍后重试。"))
        return false
    end
    if not replay_token then
        if begin_err == "already_active" then
            self:showTransientInfo(_("离线阅读时长正在上报中"), 2)
            return false
        end
        if begin_err ~= "empty" then
            self:showInfo(_("离线阅读时长上报未能启动，可稍后重试。"))
            return false
        end
        self:showTransientInfo(_("没有待上报的离线阅读时长"), 2)
        return false
    end

    self.pending_time_upload_active = true
    self.pending_time_upload_queue = ids
    self.pending_time_upload_token = replay_token
    local standby_held = false
    if type(bridge.acquireStandbyGuard) == "function" then
        local ok, err = pcall(bridge.acquireStandbyGuard, bridge)
        standby_held = ok
        if not ok then
            logger.warn("wereaddesktop: offline-time standby guard failed:",
                tostring(err))
        end
    end
    local finished = false
    local function finish(message, completed)
        if finished then
            return
        end
        finished = true
        self.pending_time_upload_active = false
        self.pending_time_upload_queue = nil
        self.pending_time_upload_token = nil
        local end_ok, ended = pcall(
            ProgressUploader.endTimeReplay, replay_token, os.time())
        if not end_ok or not ended then
            logger.err("wereaddesktop: offline-time coordinator release failed:",
                tostring(ended))
        end
        if standby_held then
            standby_held = false
            pcall(bridge.releaseStandbyGuard, bridge)
        end
        self:refreshDesktop()
        if completed then
            local remaining = bridge:getPendingUploadSummary()
            if (tonumber(remaining.elapsed) or 0) > 0 then
                message = string.format(
                    _("本轮离线时长已上报；阅读期间新增时长已保留，可稍后继续（%s）"),
                    self:syncStatusLabel(remaining))
            else
                message = _("离线阅读时长已全部上报")
            end
        end
        if message then
            self:showTransientInfo(message, 3)
        end
    end
    local uploadNext
    local function runUploadNext()
        local ok, err = xpcall(uploadNext, debug.traceback)
        if not ok then
            logger.err("wereaddesktop: offline-time upload failed:",
                tostring(err))
            finish(_("离线阅读时长上报已暂停，可稍后继续"))
        end
    end
    uploadNext = function()
        if not self.pending_time_upload_active then
            return
        end
        if not self:isNetworkConnected() then
            finish(_("离线阅读时长上报已暂停，联网后可继续"))
            return
        end
        local book_id = table.remove(self.pending_time_upload_queue, 1)
        if not book_id then
            finish(nil, true)
            return
        end
        local uploader
        uploader = ProgressUploader:new{
            settings = bridge.settings,
            client = bridge.client,
            scheduler = UIManager,
            is_online = function()
                return self:isNetworkConnected()
            end,
            heartbeat_interval = false,
            time_bucket = "replay",
            on_uploaded = function(uploaded_book_id, position)
                if type(bridge.updateShelfProgress) == "function" then
                    bridge:updateShelfProgress(uploaded_book_id,
                        position and position.fraction)
                end
            end,
            on_finished = function()
                local ok, err = xpcall(function()
                    local current = bridge.settings:get_book(book_id)
                    if type(current) == "table"
                        and (tonumber(current.pending_replay_elapsed) or 0) > 0 then
                        finish(_("离线阅读时长上报已暂停，可稍后继续"))
                        return
                    end
                    if #self.pending_time_upload_queue > 0 then
                        pcall(self.refreshDesktop, self)
                        UIManager:scheduleIn(61, runUploadNext)
                    else
                        finish(nil, true)
                    end
                end, debug.traceback)
                if not ok then
                    logger.err("wereaddesktop: offline-time completion failed:",
                        tostring(err))
                    finish(_("离线阅读时长上报已暂停，可稍后继续"))
                end
            end,
        }
        local ok, started = pcall(uploader.retryPending, uploader, book_id,
            { include_pending_time = true })
        if not ok then
            logger.err("wereaddesktop: offline-time retry failed:",
                tostring(started))
        end
        if not ok or not started then
            finish(_("离线阅读时长上报未能启动，可稍后重试"))
        end
    end
    runUploadNext()
    return true
end

function WeReadDesktop:onNetworkDisconnected()
    self:refreshDesktop()
end

----------------------------------------------------------------
-- Shelf search and local ordering. Keep this presentation state outside
-- the persisted cloud shelf so a temporary filter never changes account data.
----------------------------------------------------------------

local SHELF_SORTS = {
    { key = "time_desc", label = _("最近阅读") },
    { key = "title_asc", label = _("书名") },
    { key = "progress_desc", label = _("阅读进度") },
    { key = "unfinished", label = _("未读完") },
}

local function shelf_text(book)
    return tostring(book and (book.text or book.title or "") or "")
end

function WeReadDesktop:shelfSortOrder()
    local shelf = self.weread and self.weread.settings
        and self.weread.settings:get("shelf", {}) or {}
    local key = type(shelf) == "table" and shelf.sort_order or nil
    for _, entry in ipairs(SHELF_SORTS) do
        if entry.key == key then
            return key
        end
    end
    return SHELF_SORTS[1].key
end

function WeReadDesktop:shelfSortLabel()
    local key = self:shelfSortOrder()
    for _, entry in ipairs(SHELF_SORTS) do
        if entry.key == key then
            return entry.label
        end
    end
    return SHELF_SORTS[1].label
end

function WeReadDesktop:cycleShelfSort()
    if not self.weread then
        return
    end
    local current = self:shelfSortOrder()
    local next_key = SHELF_SORTS[1].key
    for index, entry in ipairs(SHELF_SORTS) do
        if entry.key == current then
            next_key = SHELF_SORTS[index % #SHELF_SORTS + 1].key
            break
        end
    end
    local shelf = self.weread.settings:get("shelf", {})
    if type(shelf) ~= "table" then
        shelf = {}
    end
    shelf.sort_order = next_key
    self.weread.settings:set("shelf", shelf)
    self.weread.settings:flush()
    self:showTransientInfo(_("书架排序：") .. self:shelfSortLabel(), 2)
    self:refreshDesktop()
end

function WeReadDesktop:showShelfSearch(current)
    if not self.weread then
        return
    end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        modal = true,
        title = _("搜索本地书架"),
        input = current or "",
        buttons = {
            {
                {
                    text = _("清除"),
                    callback = function()
                        UIManager:close(dialog)
                        self.shelf_query = nil
                        self:refreshDesktop()
                    end,
                },
                {
                    text = _("搜索"),
                    is_enter_default = true,
                    callback = function()
                        local query = tostring(dialog:getInputText() or "")
                            :gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(dialog)
                        self.shelf_query = query ~= "" and query or nil
                        self:refreshDesktop()
                    end,
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadDesktop:filteredShelfBooks(books)
    local result = {}
    local query = self.shelf_query
    query = query and query:lower() or nil
    for _, book in ipairs(books or {}) do
        local haystack = (shelf_text(book) .. " "
            .. tostring(book.authors or "") .. " "
            .. tostring(book.book_id or "")):lower()
        if not query or haystack:find(query, 1, true) then
            result[#result + 1] = book
        end
    end
    local sort_order = self:shelfSortOrder()
    table.sort(result, function(left, right)
        if sort_order == "title_asc" then
            return shelf_text(left) < shelf_text(right)
        elseif sort_order == "progress_desc" then
            local lp = tonumber(left.progress) or 0
            local rp = tonumber(right.progress) or 0
            if lp ~= rp then
                return lp > rp
            end
        elseif sort_order == "unfinished" then
            local lf = left.finished == true
            local rf = right.finished == true
            if lf ~= rf then
                return not lf
            end
        end
        local lt = tonumber(left.last_read_time or left.read_update_time) or 0
        local rt = tonumber(right.last_read_time or right.read_update_time) or 0
        if lt ~= rt then
            return lt > rt
        end
        return shelf_text(left) < shelf_text(right)
    end)
    return result
end

function WeReadDesktop:formatStorageSummary(summary)
    summary = summary or {}
    local lines = {
        _("本地缓存"),
        string.format(_("%d 本书 · %s · %d 个文件"),
            tonumber(summary.book_count) or 0,
            formatStorageBytes(summary.bytes),
            tonumber(summary.files) or 0),
        "",
    }
    for _, book in ipairs(summary.books or {}) do
        lines[#lines + 1] = string.format("%s · %s",
            shelf_text(book),
            formatStorageBytes(book.bytes))
    end
    if #summary.books == 0 then
        lines[#lines + 1] = _("暂无本地下载缓存。")
    end
    return table.concat(lines, "\n")
end

function WeReadDesktop:showStorageManager()
    if not self.weread then
        return
    end
    local TextViewer = require("ui/widget/textviewer")
    local ok, summary = pcall(self.weread.getStorageSummary, self.weread)
    if not ok then
        logger.warn("wereaddesktop: storage summary failed:", tostring(summary))
        self:showInfo(_("读取缓存信息失败，请稍后重试。"))
        return
    end
    self:showOverlay(TextViewer:new{
        modal = true,
        title = _("微读缓存"),
        text = self:formatStorageSummary(summary),
        show_menu = false,
    })
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remain = seconds % 60
    if hours > 0 then
        if minutes > 0 then
            return string.format(_("%d小时%d分钟"), hours, minutes)
        end
        return string.format(_("%d小时"), hours)
    end
    if minutes > 0 then
        return string.format(_("%d分钟"), minutes)
    end
    return string.format(_("%d秒"), remain)
end

function WeReadDesktop:syncStatusLabel(summary)
    if self.pending_time_upload_active then
        return _("正在上报")
    end
    if not summary or (tonumber(summary.elapsed) or 0) <= 0 then
        return _("无待上报")
    end
    return string.format(_("待上报 %s"), formatDuration(summary.elapsed))
end

function WeReadDesktop:showSyncStatus()
    if not self.weread then
        return
    end
    local summary = self.weread:getPendingUploadSummary()
    if (tonumber(summary.elapsed) or 0) <= 0 then
        self:showTransientInfo(_("没有待上报的离线阅读时长；阅读进度会在联网后自动同步。"), 3)
        return
    end
    local chunks = tonumber(summary.replay_chunks)
        or math.ceil((tonumber(summary.elapsed) or 0) / 60)
    local estimate = math.max(0, chunks - 1) * 61
        + math.ceil(ProgressUploader.timeReplayStartDelay(os.time()))
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        modal = true,
        dismissable = false,
        title = string.format(
            _("%d 本书共 %s待上报。微信接口需要分段处理，预计约 %s完成。请保持 Wi-Fi 连接；期间可以继续阅读，新增时长会单独保留，避免重复上报。"),
            tonumber(summary.time_count) or tonumber(summary.count) or 0,
            formatDuration(summary.elapsed), formatDuration(estimate)),
        buttons = {
            {
                {
                    text = _("开始后台上报"),
                    callback = function()
                        UIManager:close(dialog)
                        if self:startPendingReadingTimeUpload() then
                            self:showTransientInfo(
                                _("已开始上报；设备会保持唤醒，可以继续阅读"), 3)
                        end
                    end,
                },
            },
            {
                {
                    text = _("清除待上报时长"),
                    callback = function()
                        UIManager:close(dialog)
                        if self.pending_time_upload_active then
                            self:showInfo(_("上报正在进行，完成或暂停后再清除。"))
                            return
                        end
                        local ConfirmBox = require("ui/widget/confirmbox")
                        self:showOverlay(ConfirmBox:new{
                            modal = true,
                            text = _("确定清除全部待上报的离线阅读时长吗？阅读进度不会被清除，并仍会在联网后自动同步。"),
                            ok_text = _("清除"),
                            ok_callback = function()
                                local cleared_count, elapsed =
                                    self.weread:clearPendingUploadElapsed()
                                self:showTransientInfo(string.format(
                                    _("已清除 %d 本书、%s待上报时长"),
                                    cleared_count, formatDuration(elapsed)), 3)
                                self:refreshDesktop()
                            end,
                            cancel_text = _("取消"),
                        })
                    end,
                },
            },
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    self:showOverlay(dialog)
end

-- The detail endpoint has changed field names a few times. Keep the UI
-- product-facing and map the known aliases instead of dumping the response
-- table (which exposes JSON-like keys and protocol metadata to users).
local STAT_FIELDS = {
    {
        label = _("阅读时长"),
        kind = "duration",
        keys = { "readtime", "readingtime", "readtimeseconds",
            "readingtimeseconds", "readtimeminutes" },
    },
    {
        label = _("累计阅读时长"),
        kind = "duration",
        keys = { "totalreadtime", "allreadtime", "cumulativereadtime" },
    },
    {
        label = _("阅读天数"),
        kind = "days",
        keys = { "readdaynum", "readdaycount", "readdays",
            "readingdays", "daycount", "days" },
    },
    {
        label = _("阅读书籍"),
        kind = "books",
        keys = { "readbooknum", "readbookcount", "readingbooknum",
            "readingbookcount", "bookcount" },
    },
    {
        label = _("读完书籍"),
        kind = "books",
        keys = { "finishedbooknum", "finishedbookcount", "finishbooknum",
            "finishbookcount", "finishedbooks" },
    },
    {
        label = _("连续阅读"),
        kind = "days",
        keys = { "streak", "continuousreadingdays",
            "consecutivereadingdays", "consecutivedays" },
    },
}

local STAT_WRAPPERS = { "data", "result", "detail", "readingdata" }

local function statKey(value)
    return tostring(value):gsub("[_%-%s]", ""):lower()
end

local function unwrapStats(value)
    if type(value) ~= "table" then
        return {}
    end
    for _, key in ipairs(STAT_WRAPPERS) do
        local wrapped = value[key]
        if type(wrapped) == "table" then
            return wrapped
        end
    end
    return value
end

local function findStatValue(data, aliases)
    local wanted = {}
    for _, alias in ipairs(aliases) do
        wanted[alias] = true
    end
    for key, value in pairs(data) do
        if wanted[statKey(key)] and type(value) ~= "table" then
            return value, statKey(key)
        end
    end
    return nil
end

local function formatStatValue(value, field_kind, source_key)
    local number = tonumber(value)
    if not number then
        return tostring(value or "")
    end
    if field_kind == "duration" then
        local key = source_key or ""
        if key:find("millisecond", 1, true)
            or key:find("millis", 1, true) then
            number = number / 1000
        elseif key:find("minute", 1, true) then
            number = number * 60
        end
        return formatDuration(number)
    elseif field_kind == "days" then
        return string.format(_("%d天"), math.floor(number + 0.5))
    elseif field_kind == "books" then
        return string.format(_("%d本"), math.floor(number + 0.5))
    end
    return tostring(value)
end

local function appendStatSection(value, title, lines)
    local data = unwrapStats(value)
    lines[#lines + 1] = title
    local shown = 0
    for _, field in ipairs(STAT_FIELDS) do
        local raw, source_key = findStatValue(data, field.keys)
        if raw ~= nil then
            lines[#lines + 1] = string.format("  %s：%s", field.label,
                formatStatValue(raw, field.kind, source_key))
            shown = shown + 1
        end
    end
    if shown == 0 then
        lines[#lines + 1] = "  " .. _("暂无可展示的数据")
    end
end

function WeReadDesktop:formatReadStats(weekly, overall)
    local lines = { _("微信读书阅读统计"), "" }
    appendStatSection(weekly, _("本周"), lines)
    lines[#lines + 1] = ""
    appendStatSection(overall, _("累计"), lines)
    return table.concat(lines, "\n")
end

function WeReadDesktop:showReadStats(weekly, overall)
    local TextViewer = require("ui/widget/textviewer")
    self:showOverlay(TextViewer:new{
        modal = true,
        title = _("阅读统计"),
        text = self:formatReadStats(weekly, overall),
        show_menu = false,
    })
end

function WeReadDesktop:openReadStats()
    if not self.weread or not self.weread:isLoggedIn() then
        self:showInfo(_("请先扫码登录微信读书"))
        return
    end
    self:showBusy(_("正在加载阅读统计…"))
    self:runOnlineTask(_("阅读统计"), function()
        local ok, weekly, overall = pcall(function()
            return self.weread.client:get_read_stats("weekly"),
                self.weread.client:get_read_stats("overall")
        end)
        self:closeBusy()
        if not ok or type(weekly) ~= "table" or type(overall) ~= "table" then
            logger.warn("wereaddesktop: reading stats failed:",
                tostring(ok and "empty_response" or weekly))
            self:showInfo(_("阅读统计加载失败，请稍后重试。"))
            return
        end
        self:showReadStats(weekly, overall)
    end)
end

----------------------------------------------------------------
-- 定时熄屏 (autosuspend): a desktop settings-tab shortcut for the
-- timeout of KOReader's bundled autosuspend plugin ("Auto power
-- save"). The plugin runs globally — desktop included — and is
-- enabled by default with a 15-minute timeout; here we only expose
-- the timeout value on the desktop settings tab.
----------------------------------------------------------------

-- Tappable cycle for the settings row: off -> 5/15/30/60 min -> off.
local AUTOSUSPEND_PRESETS = { -1, 300, 900, 1800, 3600 }
local AUTOSUSPEND_DEFAULT = 900 -- autosuspend plugin's built-in default

-- Screensaver types offered by the settings row, in cycle order (the
-- official screensaver menu re-reads the setting on every screen-off,
-- so no live notification is needed).
local SCREENSAVER_TYPES = {
    { key = "cover", label = _("书籍封面") },
    { key = "document_cover", label = _("文档封面") },
    { key = "random_image", label = _("随机图片") },
    { key = "bookstatus", label = _("书籍状态") },
    { key = "readingprogress", label = _("阅读进度") },
    { key = "disable", label = _("禁用") },
}

-- Screen rotation modes (frontend/ui/data/optionsutil.lua):
-- 0 upright, 1 CW, 2 upside down, 3 CCW.
local ROTATION_LABELS = {
    [0] = _("竖屏"),
    [1] = _("右转 90°"),
    [2] = _("倒置"),
    [3] = _("左转 90°"),
}

function WeReadDesktop:autosuspendSeconds()
    return tonumber(G_reader_settings:readSetting(
        "auto_suspend_timeout_seconds")) or AUTOSUSPEND_DEFAULT
end

function WeReadDesktop:autosuspendLabel()
    local disabled = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled.autosuspend then
        return _("插件已禁用")
    end
    local secs = self:autosuspendSeconds()
    if secs <= 0 then
        return _("关")
    end
    if secs % 3600 == 0 then
        return string.format(_("%d 小时"), secs / 3600)
    end
    return string.format(_("%d 分钟"), math.max(1, math.floor(secs / 60)))
end

-- Cycle the autosuspend timeout and apply it to the running plugin
-- instance (without poking it, the new value only applies after a
-- restart).
function WeReadDesktop:cycleAutosuspend()
    local current = self:autosuspendSeconds()
    local next_secs = AUTOSUSPEND_PRESETS[1]
    for i, value in ipairs(AUTOSUSPEND_PRESETS) do
        if value == current then
            next_secs = AUTOSUSPEND_PRESETS[i % #AUTOSUSPEND_PRESETS + 1]
            break
        end
    end
    G_reader_settings:saveSetting("auto_suspend_timeout_seconds", next_secs)
    local ok, PluginLoader = pcall(require, "pluginloader")
    local instance = ok and PluginLoader
        and type(PluginLoader.getPluginInstance) == "function"
        and PluginLoader:getPluginInstance("autosuspend")
    if instance then
        instance.auto_suspend_timeout_seconds = next_secs
        pcall(function()
            instance:_unschedule()
            instance:_start()
        end)
    end
    self:showTransientInfo(
        _("定时熄屏：") .. self:autosuspendLabel(), 2)
    self:refreshDesktop()
end

----------------------------------------------------------------
-- Device quick settings on the desktop settings tab. Every entry
-- goes through the same public interface the official KOReader menu
-- uses (Device methods, broadcast events, plain settings keys) — see
-- the official menus referenced in each function.
----------------------------------------------------------------

function WeReadDesktop:hasFrontlight()
    local ok, Device = pcall(require, "device")
    return ok and type(Device.hasFrontlight) == "function"
        and Device:hasFrontlight() or false
end

-- Official path: 设置 → 前光 broadcasts "ShowFlDialog"; this opens the
-- same stock brightness/warmth dialog.  FrontLightWidget is non-modal,
-- so UIManager:show inserts it *below* the desktop (the topmost modal);
-- the stack-snapshot workaround finds the newly-inserted non-desktop
-- entries and brings them above the desktop. (A simple "scan from the
-- previous stack height upwards" scans one index too far, because the
-- new widget replaces the position the desktop previously occupied — so
-- scan starts from the old height, not one past it.)
function WeReadDesktop:showFrontlightDialog()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device.showLightDialog) ~= "function" then
        return
    end
    local before = #UIManager._window_stack
    Device:showLightDialog()
    for i = before, #UIManager._window_stack do
        local w = UIManager._window_stack[i].widget
        if w ~= self.desktop_widget then
            self:bringToTopOfDesktop(w)
        end
    end
end

function WeReadDesktop:nightModeEnabled()
    return G_reader_settings:readSetting("night_mode") == true
end

-- Official path: 设置 → 夜间模式 dispatches "ToggleNightMode" (the
-- handler writes the setting and repaints); just flipping the key
-- would not repaint.
function WeReadDesktop:toggleNightMode()
    UIManager:broadcastEvent(Event:new("ToggleNightMode"))
    self:refreshDesktop()
end

function WeReadDesktop:wifiEnabled()
    local wifi_on = networkState()
    return wifi_on
end

-- Mirror KOReader's official 设置 → 网络 → Wi-Fi 连接 three-state
-- behavior, including the interactive flag needed by device backends.
function WeReadDesktop:toggleWifi()
    local wifi_on, connected, NetworkMgr = networkState()
    if not NetworkMgr then
        return
    end
    local done = function()
        self:refreshDesktop()
    end
    local ok_toggle, err
    if wifi_on and connected then
        ok_toggle, err = pcall(NetworkMgr.toggleWifiOff,
            NetworkMgr, done, true)
    elseif wifi_on and type(NetworkMgr.promptWifi) == "function" then
        ok_toggle, err = pcall(NetworkMgr.promptWifi,
            NetworkMgr, done, false, true)
    else
        ok_toggle, err = pcall(NetworkMgr.toggleWifiOn,
            NetworkMgr, done, false, true)
    end
    if not ok_toggle then
        logger.warn("wereaddesktop: Wi-Fi toggle failed:", tostring(err))
    end
    self:refreshDesktop()
end

function WeReadDesktop:rotationLabel()
    local ok, Device = pcall(require, "device")
    local mode = ok and Device.screen and Device.screen:getRotationMode() or 0
    return ROTATION_LABELS[tonumber(mode) or 0] or ROTATION_LABELS[0]
end

-- Official path: 设置 → 屏幕 → 旋转 broadcasts "SetRotationMode".
-- The desktop is closed first: it has no SetDimensions handler, so it
-- would not relayout on rotation (the stock menus close too).
function WeReadDesktop:cycleRotation()
    local ok, Device = pcall(require, "device")
    if not ok or not Device.screen then
        return
    end
    local mode = (tonumber(Device.screen:getRotationMode()) or 0) + 1
    mode = mode % 4
    if self.desktop_widget then
        UIManager:close(self.desktop_widget)
        self.desktop_widget = nil
    end
    UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
end

function WeReadDesktop:screensaverLabel()
    local current = G_reader_settings:readSetting("screensaver_type") or "cover"
    for _i, entry in ipairs(SCREENSAVER_TYPES) do
        if entry.key == current then
            return entry.label
        end
    end
    return current
end

-- Official path: 设置 → 屏保 writes screensaver_type; the screensaver
-- re-reads it every time it shows, so nothing needs notification.
function WeReadDesktop:cycleScreensaver()
    local current = G_reader_settings:readSetting("screensaver_type") or "cover"
    local next_key = SCREENSAVER_TYPES[1].key
    for i, entry in ipairs(SCREENSAVER_TYPES) do
        if entry.key == current then
            next_key = SCREENSAVER_TYPES[i % #SCREENSAVER_TYPES + 1].key
            break
        end
    end
    G_reader_settings:saveSetting("screensaver_type", next_key)
    self:showTransientInfo(_("屏保：") .. self:screensaverLabel(), 2)
    self:refreshDesktop()
end

function WeReadDesktop:clockLabel()
    if G_reader_settings:readSetting("twelve_hour_clock") == true then
        return _("12 小时制")
    end
    return _("24 小时制")
end

-- Official path: 设置 → 时间和日期 writes twelve_hour_clock and
-- broadcasts "TimeFormatChanged".
function WeReadDesktop:toggleClockFormat()
    local twelve = G_reader_settings:readSetting("twelve_hour_clock") == true
    G_reader_settings:saveSetting("twelve_hour_clock", not twelve)
    UIManager:broadcastEvent(Event:new("TimeFormatChanged"))
    self:refreshDesktop()
end

-- One-line device status for the settings tab: battery (with charging
-- state) and free storage, via the same public reads the stock UI
-- uses (powerd:getCapacity, util.diskUsage).
function WeReadDesktop:deviceStatus()
    local parts = {}
    local ok, Device = pcall(require, "device")
    if ok and Device.getPowerDevice then
        local ok_cap, status = pcall(function()
            local powerd = Device:getPowerDevice()
            local text = string.format(_("电量 %d%%"), powerd:getCapacity())
            if powerd:isCharging() and not powerd:isCharged() then
                text = text .. _("（充电中）")
            end
            return text
        end)
        if ok_cap and status then
            table.insert(parts, status)
        end
    end
    local ok_util, util = pcall(require, "util")
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_util and ok_ds and util.diskUsage then
        local ok_du, usage = pcall(util.diskUsage, DataStorage:getDataDir())
        if ok_du and type(usage) == "table" and usage.total and usage.available then
            table.insert(parts, string.format(
                _("存储 %.1f/%.1f GB 可用"),
                usage.available / 1e9, usage.total / 1e9))
        end
    end
    return table.concat(parts, " · ")
end

function WeReadDesktop:updateChannelRiskLabel(channel)
    local Updater = require("updater")
    channel = Updater.normalize_update_channel(channel)
    if channel == "alpha" then
        return _("Alpha 实验版：可能无法启动或影响正常使用，不建议在重要设备上使用。")
    end
    if channel == "beta" then
        return _("Beta 测试版：新功能先行体验，偶尔可能存在问题。")
    end
    return _("稳定版：适合日常使用。")
end

function WeReadDesktop:chooseUpdateChannel()
    local Updater = require("updater")
    local current = Updater.get_update_channel()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local choices = {
        {
            channel = "stable",
            text = _("稳定版：适合日常使用"),
        },
        {
            channel = "beta",
            text = _("Beta 测试版：新功能先行体验，偶尔可能有问题"),
        },
        {
            channel = "alpha",
            text = _("Alpha 实验版：可能无法启动，不建议在重要设备上使用"),
        },
    }
    local buttons = {}
    for _, choice in ipairs(choices) do
        local selected_channel = choice.channel
        local selected = selected_channel == current
        local choice_text = choice.text
        table.insert(buttons, {
            {
                text = (selected and "✓ " or "") .. choice_text,
                callback = function()
                    UIManager:close(dialog)
                    G_reader_settings:saveSetting(
                        "wereaddesktop_update_channel", selected_channel)
                    G_reader_settings:flush()
                    self:showTransientInfo(
                        _("更新频道：") .. Updater.update_channel_label(
                            selected_channel), 2)
                    self:refreshDesktop()
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("取消"),
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })
    dialog = ButtonDialog:new{
        modal = true,
        dismissable = false,
        title = _("选择更新频道"),
        buttons = buttons,
    }
    self:showOverlay(dialog)
end

-- 微读 self-update (GitHub Releases): check, offer, download + install,
-- then ask for a KOReader restart. Works without a WeRead login — only
-- the bridge's generic HTTP client is used.
function WeReadDesktop:checkPluginUpdate()
    local Updater = require("updater")
    local channel = Updater.get_update_channel()
    local client = self.weread and self.weread.client
    if not client then
        self:showInfo(_("更新服务暂不可用，请重启 KOReader 后重试。"))
        return
    end
    self:showBusy(_("正在检查更新…"))
    self:runOnlineTask(_("检查更新"), function()
        local latest, err = Updater.fetch_latest(client, channel)
        self:closeBusy()
        if not latest then
            if err == "repo_not_configured" then
                self:showInfo(_("尚未配置发布仓库，无法检查更新。"))
            elseif err == "no_matching_release" then
                self:showInfo(string.format(
                    _("当前频道为%s，没有找到可安装的发布版本。"),
                    Updater.update_channel_label(channel)))
            else
                self:showInfo(_("检查更新失败：") .. tostring(err))
            end
            return
        end
        if not Updater.is_newer(latest.version) then
            self:showTransientInfo(string.format(
                _("当前为%s v%s，没有可升级版本（不会降级）。"),
                Updater.update_channel_label(channel),
                Updater.current_version()), 3)
            return
        end
        local text = string.format(_("发现新版本 v%s（%s，当前 v%s）"),
            latest.version,
            Updater.update_channel_label(latest.channel),
            Updater.current_version())
        if latest.channel == "alpha" then
            text = text .. "\n\n" .. self:updateChannelRiskLabel("alpha")
        end
        if latest.notes ~= "" then
            text = text .. "\n\n" .. latest.notes
        end
        if not latest.asset_url then
            self:showInfo(text .. "\n\n" ..
                _("该版本未附带插件安装包，请到 GitHub 发布页手动下载更新。"))
            return
        end
        local ConfirmBox = require("ui/widget/confirmbox")
        self:showOverlay(ConfirmBox:new{
            modal = true,
            text = text .. "\n\n" .. _("是否下载并安装？安装后需要重启 KOReader。"),
            ok_text = _("立即更新"),
            ok_callback = function()
                self:showBusy(_("正在下载并安装更新…"))
                self:runOnlineTask(_("下载更新"), function()
                    -- The plugin loader stores the plugin root on the
                    -- module; its parent is the plugins directory.
                    local plugins_dir = (type(self.path) == "string"
                        and self.path:match("^(.*)/[^/]+$")) or "plugins"
                    local work_dir =
                        require("datastorage"):getDataDir() .. "/cache"
                    local ok, err2 = Updater.install(client,
                        latest.asset_url, plugins_dir, work_dir)
                    self:closeBusy()
                    if ok then
                        UIManager:askForRestart(
                            _("微读已更新，重启 KOReader 后生效。"))
                    else
                        self:showInfo(_("更新失败：") .. tostring(err2))
                    end
                end)
            end,
            cancel_text = _("取消"),
        })
    end)
end

----------------------------------------------------------------
-- WeRead integration: QRLogin host callbacks and shelf actions.
----------------------------------------------------------------

function WeReadDesktop:showInfo(text)
    -- "full": this often follows closeBusy() on e-ink, where a partial
    -- refresh can leave the message unpainted behind the desktop.
    self:showOverlay(InfoMessage:new{ modal = true, text = text }, "full")
end

function WeReadDesktop:showTransientInfo(text, timeout)
    self:showOverlay(InfoMessage:new{
        modal = true,
        text = text,
        timeout = timeout or 2,
    })
end

function WeReadDesktop:showBusy(text)
    self:closeBusy()
    self.busy_message = InfoMessage:new{
        modal = true,
        text = text,
        dismissable = false,
    }
    self:showOverlay(self.busy_message)
end

function WeReadDesktop:closeBusy()
    if self.busy_message then
        UIManager:close(self.busy_message)
        self.busy_message = nil
    end
end

function WeReadDesktop:refreshUI()
    if UIManager.forceRePaint then
        pcall(function()
            UIManager:forceRePaint()
        end)
    end
end

function WeReadDesktop:showInputDialog(dialog)
    self:showOverlay(dialog, "full")
    if dialog.onShowKeyboard then
        pcall(function()
            dialog:onShowKeyboard()
        end)
    end
end

-- Show any secondary surface above the fullscreen desktop. KOReader's window
-- manager intentionally places non-modal widgets below a modal desktop, and
-- a few stock widgets do not consistently request a full repaint on e-ink.
-- Keeping this seam here makes TextViewer, InfoMessage and confirmation/input
-- dialogs behave the same in both desktop and reader contexts.
function WeReadDesktop:showOverlay(widget, refresh_mode)
    UIManager:show(widget, refresh_mode or "full")
    self:bringToTopOfDesktop(widget)
    return widget
end

-- The desktop widget is modal, so any non-modal widget shown afterwards
-- (FrontLightWidget, InputDialog, etc.) lands *below* it and is
-- invisible. This helper moves a widget that UIManager just inserted
-- below the desktop to the top of the window stack, the same way the
-- existing menu button's settings entry fix works.
function WeReadDesktop:bringToTopOfDesktop(widget)
    local stack = UIManager._window_stack
    if type(stack) == "table" then
        for i, entry in ipairs(stack) do
            if entry.widget == widget then
                table.remove(stack, i)
                table.insert(stack, entry)
                break
            end
        end
    end
    if type(UIManager.setDirty) == "function" then
        UIManager:setDirty(widget, "full")
    end
    self:refreshUI()
end

function WeReadDesktop:isNetworkOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isOnline then
        return true
    end
    local ok_online, online = pcall(function()
        return NetworkMgr:isOnline()
    end)
    if not ok_online then
        return true
    end
    return online == true
end

function WeReadDesktop:showOffline(label)
    self:closeBusy()
    self:showInfo(label .. _("失败：无网络连接，请连接 Wi-Fi 后重试。"))
end

-- Run a blocking network task off the immediate UI path; errors are
-- caught and shown instead of crashing the plugin. The full traceback
-- goes to the log; the user only sees the short error message.
function WeReadDesktop:runOnlineTask(label, callback, delay)
    if not self:isNetworkOnline() then
        self:showOffline(label)
        return false
    end
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            logger.warn("wereaddesktop:", label, "failed:", err)
            self:closeBusy()
            -- tostring(err) starts with the error message; the traceback
            -- tail after the first newline stays in the log only.
            local message = tostring(err):match("^([^\n]*)") or ""
            self:showInfo(label .. _("失败：") .. message)
        end
    end)
    return true
end

-- Menu items re-evaluate their text_func when opened; nothing to push.
function WeReadDesktop:refreshLoginMenu()
    self:refreshUI()
end

function WeReadDesktop:startWereadLogin()
    if not self.weread then
        return
    end
    logger.info("wereaddesktop: starting weread QR login")
    self.weread:startLogin(function(ok, _err)
        logger.info("wereaddesktop: weread login flow done, ok =", ok)
        if ok then
            self.weread.session_expired = false
            self.weread_relogin_prompted = false
            -- Login flow already runs on a deferred task; chain the shelf
            -- fetch + cover predownload, then refresh the desktop.
            UIManager:scheduleIn(0.1, function()
                self:refreshWereadShelf(true)
            end)
        end
    end)
end

function WeReadDesktop:logoutWeread()
    if not self.weread then
        return
    end
    self.weread:logout()
    self.shelf_query = nil
    self:showTransientInfo(_("已退出微信读书登录"), 2)
    self:refreshDesktop()
end

-- Open a downloaded EPUB from the desktop (called by the bridge's
-- download pipeline): close the desktop widget first.
function WeReadDesktop:openBookFile(path)
    if self.desktop_widget then
        UIManager:close(self.desktop_widget)
        self.desktop_widget = nil
    end
    self.ui:openFile(path)
end

-- Confirmation before starting a full-book download. Not dismissable:
-- a stray tap anywhere on screen would otherwise close the dialog
-- (ButtonDialog defaults to TapClose on the whole screen), which reads
-- as "the dialog flashed and vanished".
function WeReadDesktop:confirmWereadDownload(book, chapters)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        modal = true,
        dismissable = false,
        title = string.format(
            _("《%s》需要下载后才能阅读，共 %d 章。"),
            book.text or "", #chapters),
        buttons = {
            {
                {
                    text = _("开始下载"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Progress, cancellation, error dialogs and the
                        -- final open are all owned by the download
                        -- pipeline inside the bridge.
                        self.weread:downloadBook(book, chapters)
                    end,
                },
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    self:showOverlay(dialog) -- full repaint: e-ink can swallow the
    -- dialog's refresh when it follows a busy-message close in the same tick
end

-- Entry point for tapping a WeRead shelf book: open the cached EPUB when
-- present, otherwise fetch the chapter list and offer to download.
function WeReadDesktop:openWereadBook(book, close_desktop)
    if not self.weread then
        return
    end
    local cached = self.weread:isBookDownloaded(book.book_id)
    if cached then
        close_desktop()
        self.ui:openFile(cached)
        return
    end
    if not self.weread:isLoggedIn() then
        self:showInfo(_("请先扫码登录微信读书"))
        return
    end
    self:showBusy(_("正在获取章节目录…"))
    self:runOnlineTask(_("获取章节目录"), function()
        self.weread:fetchChapterList(book, false, function(chapters, err)
            self:closeBusy()
            if not chapters then
                self:showInfo(_("获取章节目录失败：") .. tostring(err))
                return
            end
            if #chapters == 0 then
                self:showInfo(_("这本书没有可下载的章节，可能需要购买后才能阅读。"))
                return
            end
            self:confirmWereadDownload(book, chapters)
        end)
    end)
end

-- Long-press on a shelf book: download options. For books not yet
-- downloaded this falls back to the normal tap flow; for downloaded
-- books it offers a fill-missing run (re-download only the chapters
-- missing from the parts cache) and a full re-download.
function WeReadDesktop:showBookDownloadOptions(book)
    if not self.weread then
        return
    end
    if not self.weread:isLoggedIn() then
        self:showInfo(_("请先扫码登录微信读书"))
        return
    end
    if not self.weread:isBookDownloaded(book.book_id) then
        self:openWereadBook(book, function() end)
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function fetchThen(mode)
        UIManager:close(dialog)
        self:showBusy(_("正在获取章节目录…"))
        self:runOnlineTask(_("获取章节目录"), function()
            self.weread:fetchChapterList(book, false, function(chapters, err)
                self:closeBusy()
                if not chapters then
                    self:showInfo(_("获取章节目录失败：") .. tostring(err))
                    return
                end
                if #chapters == 0 then
                    self:showInfo(_("这本书没有可下载的章节，可能需要购买后才能阅读。"))
                    return
                end
                if mode == "fill" then
                    -- Nothing missing: the downloader says so itself.
                    self.weread:downloadBook(book, chapters, nil, {
                        fill_missing = true,
                        open_on_complete = false,
                    })
                else
                    self.weread:downloadBook(book, chapters)
                end
            end)
        end)
    end
    dialog = ButtonDialog:new{
        modal = true,
        dismissable = false,
        title = string.format(_("《%s》"), book.text or ""),
        buttons = {
            {
                {
                    text = _("补齐缺失章节"),
                    callback = function()
                        fetchThen("fill")
                    end,
                },
                {
                    text = _("重新下载整本"),
                    callback = function()
                        fetchThen("full")
                    end,
                },
            },
            {
                {
                    text = _("删除本地下载"),
                    callback = function()
                        UIManager:close(dialog)
                        local ConfirmBox = require("ui/widget/confirmbox")
                        self:showOverlay(ConfirmBox:new{
                            modal = true,
                            text = string.format(
                                _("确定删除《%s》的本地 EPUB、章节缓存和书友想法缓存吗？"),
                                book.text or ""),
                            ok_text = _("删除"),
                            ok_callback = function()
                                local ok, err = self.weread:deleteBook(book.book_id)
                                if ok then
                                    self:showTransientInfo(_("已删除本地下载"), 2)
                                    self:refreshDesktop()
                                else
                                    self:showInfo(_("删除本地下载失败：") .. tostring(err))
                                end
                            end,
                            cancel_text = _("取消"),
                        })
                    end,
                },
            },
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    self:showOverlay(dialog)
end

-- Prompt a QR re-login when the web session is known to be dead (once
-- per run; the menu entry stays available after dismissal).
function WeReadDesktop:maybePromptRelogin()
    if self.weread and self.weread:isLoggedIn()
        and self.weread.session_expired and not self.weread_relogin_prompted then
        self.weread_relogin_prompted = true
        UIManager:scheduleIn(0.5, function()
            self:showTransientInfo(_("微信读书登录已过期，请重新扫码"), 3)
            self:startWereadLogin()
        end)
    end
end

-- Download missing covers one scheduled task at a time: ensureCover is
-- blocking, so a plain loop over a whole shelf would freeze the UI for
-- seconds. Calls done() (still inside a scheduled task) after the last
-- cover has been attempted.
function WeReadDesktop:downloadCovers(books, done)
    local i = 0
    local function step()
        i = i + 1
        if i > #books then
            done()
            return
        end
        self.weread:ensureCover(books[i], function()
            UIManager:scheduleIn(0, step)
        end)
    end
    step()
end

-- Fetch the shelf (blocking) and predownload covers, then repaint the
-- desktop. Callers must invoke this from a deferred/scheduled task.
-- opts.silent: no busy spinner / no error popup (background auto-refresh
-- with a cache already on screen).
function WeReadDesktop:refreshWereadShelf(force_refresh, opts)
    if not self.weread then
        return
    end
    if not self.weread:isLoggedIn() then
        self:showTransientInfo(_("请先扫码登录微信读书"), 2)
        return
    end
    if self.weread_refreshing then
        if not (opts and opts.silent) then
            self:showTransientInfo(_("书架正在刷新中…"), 2)
        end
        return
    end
    self.weread_refreshing = true
    local silent = opts and opts.silent
    if not silent then
        self:showBusy(_("正在刷新微信读书书架…"))
    end
    logger.info("wereaddesktop: fetching weread shelf, force =", force_refresh,
        "silent =", silent)
    self.weread:fetchShelf(force_refresh, function(books, err)
        self.weread_refreshing = false
        if not books then
            logger.warn("wereaddesktop: shelf fetch failed:", err)
            if not silent then
                self:closeBusy()
                self:showInfo(_("书架刷新失败：") .. tostring(err))
            end
            -- Silent failure: keep showing the cached shelf.
            return
        end
        logger.info("wereaddesktop: shelf fetched,", #books, "books; downloading covers")
        self:downloadCovers(books, function()
            -- Persist cover_path filled in by ensureCover.
            self.weread:saveShelf(books)
            logger.info("wereaddesktop: covers done, refreshing desktop")
            if not silent then
                self:closeBusy()
            end
            self:refreshDesktop()
            self:maybePromptRelogin()
            if G_reader_settings:readSetting("wereaddesktop_debug_screenshot") then
                UIManager:scheduleIn(1, function()
                if self.desktop_widget then
                    self.ui.screenshot:onScreenshot()
                end
            end)
            end
        end)
    end)
end

-- Load the store home feed (blocking inside runOnlineTask) and hand it
-- to the desktop through collectData. First visit only; the result is
-- cached for the session.
function WeReadDesktop:loadStoreFeed()
    if not self.weread or not self.weread:isLoggedIn() then
        return
    end
    if self.store_feed_loading then
        return
    end
    self.store_feed_loading = true
    self:showBusy(_("正在加载书城…"))
    self:runOnlineTask(_("加载书城"), function()
        self.weread:getStoreFeed(function(sections, err)
            self.store_feed_loading = false
            self:closeBusy()
            if not sections then
                self.store_error = tostring(err)
                self:refreshDesktop()
                return
            end
            self.store_error = nil
            local all_books = {}
            for _, s in ipairs(sections) do
                for _, book in ipairs(s.books) do
                    table.insert(all_books, book)
                end
            end
            self:downloadCovers(all_books, function()
                self.store_feed = sections
                self:refreshDesktop()
            end)
        end)
    end)
end

-- Search the store. Without a keyword, prompt for one first; the actual
-- search runs off the UI path and the results land via collectData.
function WeReadDesktop:searchStoreBooks(keyword)
    if not self.weread or not self.weread:isLoggedIn() then
        return
    end
    if not keyword then
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            modal = true,
            title = _("搜索微信读书书城"),
            input = "",
            buttons = {
                {
                    {
                        text = _("取消"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                    {
                        text = _("搜索"),
                        is_enter_default = true,
                        callback = function()
                            local kw = dialog:getInputText()
                            UIManager:close(dialog)
                            if kw and kw ~= "" then
                                self:searchStoreBooks(kw)
                            end
                        end,
                    },
                },
            },
        }
        self:showInputDialog(dialog)
        return
    end
    self:showBusy(_("正在搜索…"))
    self:runOnlineTask(_("搜索书城"), function()
        self.weread:searchStore(keyword, function(books, err)
            self:closeBusy()
            if not books then
                self.store_search = { keyword = keyword, error = tostring(err) }
                self:refreshDesktop()
            else
                self:downloadCovers(books, function()
                    self.store_search = { keyword = keyword, books = books }
                    self:refreshDesktop()
                end)
            end
        end)
    end)
end

-- Desktop data: the WeRead shelf when logged in (an empty shelf until
-- the first fetch lands), otherwise just the login prompt. Network
-- refresh is triggered only from the menu / login flow; collectData
-- stays sync.
function WeReadDesktop:collectData()
    if self.weread and self.weread:isLoggedIn() then
        local books = self:filteredShelfBooks(
            self.weread:getCachedShelf() or {})
        for _, book in ipairs(books) do
            if not book.cover_path then
                book.cover_path = self.weread:findCachedCover(book.book_id)
            end
        end
        local storage_summary
        local ok_storage, result = pcall(
            self.weread.getStorageSummary, self.weread)
        if ok_storage then
            storage_summary = result
        end
        local pending_summary
        local ok_pending, pending = pcall(
            self.weread.getPendingUploadSummary, self.weread)
        if ok_pending then
            pending_summary = pending
        end
        local Updater = require("updater")
        local update_channel = Updater.get_update_channel()
        return {
            weread = true,
            account_name = self.weread:getAccountName(),
            account_vid = self.weread:getAccountVid(),
            books = books,
            shelf_query = self.shelf_query,
            shelf_sort_label = self:shelfSortLabel(),
            storage_label = storage_summary and string.format(
                _("%d 本 · %s"),
                tonumber(storage_summary.book_count) or 0,
                formatStorageBytes(storage_summary.bytes)) or nil,
            sync_status_label = self:syncStatusLabel(pending_summary),
            -- Store tab state (nil until the user visits the store).
            store_feed = self.store_feed,
            store_error = self.store_error,
            store_search = self.store_search,
            sync_progress =
                G_reader_settings:readSetting("wereaddesktop_progress_sync") ~= false,
            auto_start =
                G_reader_settings:readSetting("wereaddesktop_show_on_start") ~= false,
            autosuspend_label = self:autosuspendLabel(),
            -- Device quick settings (see the implementations below).
            device_status = self:deviceStatus(),
            has_frontlight = self:hasFrontlight(),
            night_mode = self:nightModeEnabled(),
            wifi_on = self:wifiEnabled(),
            rotation_label = self:rotationLabel(),
            screensaver_label = self:screensaverLabel(),
            clock_label = self:clockLabel(),
            plugin_version = require("wereaddesktop_version"),
            update_channel = update_channel,
            update_channel_label = Updater.update_channel_label(update_channel),
            update_risk_label = self:updateChannelRiskLabel(update_channel),
        }
    end
    return { login_prompt = true }
end

-- Top-bar actions are rebuilt by BookshelfWidget:setData(), but the action
-- table itself lives outside data. Add/remove the Wi-Fi indicator before a
-- rebuild so it follows the current connection state.
function WeReadDesktop:refreshWifiAction()
    local widget = self.desktop_widget
    local actions = widget and widget.actions
    if type(actions) ~= "table" then
        return
    end
    local wifi_index
    for i, action in ipairs(actions) do
        if action.wereaddesktop_wifi_status or action.icon == "wifi" then
            wifi_index = i
            break
        end
    end
    local connected = self:isNetworkConnected()
    if not connected and wifi_index then
        table.remove(actions, wifi_index)
        return
    end
    if connected and not wifi_index then
        local insert_at = #actions + 1
        for i, action in ipairs(actions) do
            if action.icon == "exit" then
                insert_at = i
                break
            end
        end
        table.insert(actions, insert_at, {
            icon = "wifi",
            wereaddesktop_wifi_status = true,
            callback = function()
                self:showTransientInfo(_("Wi-Fi 已连接"), 1)
            end,
        })
    end
end

function WeReadDesktop:showDesktop()
    if self.desktop_widget then
        return
    end
    local ui = self.ui
    local function close()
        if self.desktop_widget then
            UIManager:close(self.desktop_widget)
            self.desktop_widget = nil
        end
    end
    local actions = {
        {
            icon = "appbar.filebrowser",
            callback = function()
                close()
                ui:onHome()
            end,
        },
        {
            icon = "appbar.settings",
            callback = function()
                -- Keep the desktop underneath: closing the menu returns
                -- straight back to it instead of the file manager.
                ui.menu:onShowMenu()
                local container = ui.menu.menu_container
                if container then
                    -- The desktop is modal and UIManager:show stacks
                    -- non-modal widgets *below* modal ones, so the menu
                    -- lands under the desktop and only becomes visible
                    -- when the desktop closes. Move it to the top.
                    for i, entry in ipairs(UIManager._window_stack) do
                        if entry.widget == container then
                            table.remove(UIManager._window_stack, i)
                            table.insert(UIManager._window_stack, entry)
                            break
                        end
                    end
                    -- Full repaint: e-ink can swallow the menu's own
                    -- show refresh when it follows the desktop paint.
                    UIManager:setDirty(container, "full")
                end
                self:refreshUI()
            end,
        },
    }
    -- Wi-Fi status indicator between settings and exit; only shown while
    -- connected. refreshWifiAction keeps it current after the build.
    if self:isNetworkConnected() then
        table.insert(actions, {
            icon = "wifi",
            wereaddesktop_wifi_status = true,
            callback = function()
                self:showTransientInfo(_("Wi-Fi 已连接"), 1)
            end,
        })
    end
    table.insert(actions, {
        icon = "exit",
        callback = function()
            close()
            UIManager:broadcastEvent(Event:new("Exit"))
        end,
    })
    local desktop_data = self:collectData()
    self.desktop_widget = BookshelfWidget:new{
        data = desktop_data,
        actions = actions,
        on_open_book = function(book)
            -- WeRead book: open the downloaded EPUB or download it.
            self:openWereadBook(book, close)
        end,
        on_book_hold = function(book)
            -- Long-press: 补齐缺失章节 / 重新下载整本.
            self:showBookDownloadOptions(book)
        end,
        on_login = function()
            self:startWereadLogin()
        end,
        on_store_feed = function()
            self:loadStoreFeed()
        end,
        on_store_search = function(keyword)
            self:searchStoreBooks(keyword)
        end,
        on_store_search_back = function()
            self.store_search = nil
            self:refreshDesktop()
        end,
        on_shelf_search = function(current)
            self:showShelfSearch(current)
        end,
        on_toggle_sync = function()
            local enabled =
                G_reader_settings:readSetting("wereaddesktop_progress_sync") ~= false
            G_reader_settings:saveSetting("wereaddesktop_progress_sync", not enabled)
            self:refreshDesktop()
        end,
        on_toggle_autostart = function()
            local enabled =
                G_reader_settings:readSetting("wereaddesktop_show_on_start") ~= false
            G_reader_settings:saveSetting("wereaddesktop_show_on_start", not enabled)
            self:refreshDesktop()
        end,
        on_set_autosuspend = function()
            self:cycleAutosuspend()
        end,
        on_cycle_shelf_sort = function()
            self:cycleShelfSort()
        end,
        on_storage = function()
            self:showStorageManager()
        end,
        on_sync_status = function()
            self:showSyncStatus()
        end,
        on_read_stats = function()
            self:openReadStats()
        end,
        on_frontlight = function()
            self:showFrontlightDialog()
        end,
        on_toggle_night_mode = function()
            self:toggleNightMode()
        end,
        on_toggle_wifi = function()
            self:toggleWifi()
        end,
        on_cycle_rotation = function()
            self:cycleRotation()
        end,
        on_cycle_screensaver = function()
            self:cycleScreensaver()
        end,
        on_toggle_clock = function()
            self:toggleClockFormat()
        end,
        on_update_channel = function()
            self:chooseUpdateChannel()
        end,
        on_check_update = function()
            self:checkPluginUpdate()
        end,
        on_refresh_shelf = function()
            self:runOnlineTask(_("刷新书架"), function()
                self:refreshWereadShelf(true)
            end)
        end,
        on_relogin = function()
            self:startWereadLogin()
        end,
        on_logout = function()
            self:logoutWeread()
        end,
        on_about = function()
            self:showInfo(_("微读 · 微信读书桌面\n书架与书城数据来自微信读书（weread.qq.com），通过官方 App 的同一网关获取，仅供个人阅读使用。"))
        end,
        on_close = function()
            self.desktop_widget = nil
        end,
    }
    UIManager:show(self.desktop_widget)
    -- Login gating: first run (or after a logout) leads straight to the
    -- QR dialog; a dead web session (kicked by another device) prompts a
    -- re-login — the menu entry stays available either way.
    if self.weread and not self.weread:isLoggedIn()
        and not self.weread_login_autoshown then
        self.weread_login_autoshown = true
        UIManager:scheduleIn(0.5, function()
            self:startWereadLogin()
        end)
    end
    self:maybePromptRelogin()
    -- Refresh the shelf in the background on every show: the cloud shelf
    -- may have new books, and other devices push their reading progress
    -- to it. With a cache on disk the desktop paints instantly and
    -- repaints silently when the refresh lands; only the very first
    -- fetch (no cache) shows the busy spinner.
    if self.weread and self.weread:isLoggedIn() and self:isNetworkOnline() then
        self:runOnlineTask(_("刷新书架"), function()
            self:refreshWereadShelf("background", {
                silent = self.weread:getCachedShelf() ~= nil,
            })
        end, 0.5)
    end
    -- Hidden debug helper: auto-screenshot the desktop 2s after it
    -- shows, so UI tweaks can be verified from the screenshots folder.
    if G_reader_settings:readSetting("wereaddesktop_debug_screenshot") then
        UIManager:scheduleIn(2, function()
            if self.desktop_widget then
                self.ui.screenshot:onScreenshot()
            end
        end)
    end
end

-- Single entry point in KOReader's main menu: opens the desktop. All
-- settings live on the desktop's own settings tab.
function WeReadDesktop:addToMainMenu(menu_items)
    if self.ui.document then
        menu_items.wereadbookreviews = {
            text = _("书友点评"),
            sorting_hint = "tools",
            enabled_func = function()
                return self.current_weread_book_id ~= nil
            end,
            callback = function()
                self:openBookReviews()
            end,
        }
        return
    end
    menu_items.wereaddesktop = {
        text = _("微读"),
        sorting_hint = "tools",
        callback = function()
            self:showDesktop()
        end,
    }
end

return WeReadDesktop
