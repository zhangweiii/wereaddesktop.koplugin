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
local logger = require("logger")
local _ = require("gettext")

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

function WeReadDesktop:init()
    -- The vendored WeRead protocol layer salts its signatures with
    -- math.random (protocol.lua ts/rn fields).
    math.randomseed(os.time())
    migrateSettings()
    -- In the reader context only the WeRead progress upload runs; the
    -- desktop itself (and its menu/callbacks) stays file-manager-only.
    if self.ui.document then
        self:hookShowFileManager()
        self:initProgressSync()
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
-- WeRead progress sync (reader context, upload only).
--
-- The plugin module is instantiated in both the file manager and the
-- reader; in the reader only this section is active. All uploads run
-- on UIManager-deferred tasks and fail silently.
----------------------------------------------------------------

-- Reader-context setup: build a dedicated bridge (settings + client,
-- no UI) and the two-way progress sync.
function WeReadDesktop:initProgressSync()
    if G_reader_settings:readSetting("wereaddesktop_progress_sync") == false then
        return
    end
    local bridge = WereadBridge:new(self)
    if not bridge:isLoggedIn() then
        return
    end
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
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isConnected then
        return self:isNetworkOnline()
    end
    local ok_connected, connected = pcall(function()
        return NetworkMgr:isConnected()
    end)
    if not ok_connected then
        return true
    end
    return connected == true
end

function WeReadDesktop:onReaderReady()
    if self.progress_uploader then
        self.progress_uploader:onReaderReady(
            self.ui.document and self.ui.document.file)
    end
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

function WeReadDesktop:refreshDesktop()
    if self.desktop_widget then
        self.desktop_widget:setData(self:collectData())
    end
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
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isWifiOn then
        return false
    end
    local ok_on, on = pcall(function()
        return NetworkMgr:isWifiOn()
    end)
    return ok_on and on == true
end

-- Official path: 设置 → 网络 → Wi-Fi 连接 calls the same NetworkMgr
-- methods; the completion callback refreshes the row label.
function WeReadDesktop:toggleWifi()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr then
        return
    end
    local done = function()
        self:refreshDesktop()
    end
    if self:wifiEnabled() then
        pcall(function()
            NetworkMgr:toggleWifiOff(done)
        end)
    else
        pcall(function()
            NetworkMgr:toggleWifiOn(done)
        end)
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

-- 微读 self-update (GitHub Releases): check, offer, download + install,
-- then ask for a KOReader restart. Works without a WeRead login — only
-- the bridge's generic HTTP client is used.
function WeReadDesktop:checkPluginUpdate()
    local Updater = require("updater")
    self:showBusy(_("正在检查更新…"))
    self:runOnlineTask(_("检查更新"), function()
        local latest, err = Updater.fetch_latest(self.weread.client)
        self:closeBusy()
        if not latest then
            if err == "repo_not_configured" then
                self:showInfo(_("尚未配置发布仓库，无法检查更新。"))
            else
                self:showInfo(_("检查更新失败：") .. tostring(err))
            end
            return
        end
        if not Updater.is_newer(latest.version) then
            self:showTransientInfo(string.format(
                _("已是最新版本 v%s"), Updater.current_version()), 2)
            return
        end
        local text = string.format(_("发现新版本 v%s（当前 v%s）"),
            latest.version, Updater.current_version())
        if latest.notes ~= "" then
            text = text .. "\n\n" .. latest.notes
        end
        if not latest.asset_url then
            self:showInfo(text .. "\n\n" ..
                _("该版本未附带插件安装包，请到 GitHub 发布页手动下载更新。"))
            return
        end
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
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
                    local ok, err2 = Updater.install(self.weread.client,
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
    UIManager:show(InfoMessage:new{ text = text }, "full")
end

function WeReadDesktop:showTransientInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

function WeReadDesktop:showBusy(text)
    self:closeBusy()
    self.busy_message = InfoMessage:new{
        text = text,
        dismissable = false,
    }
    UIManager:show(self.busy_message)
    self:refreshUI()
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
    UIManager:show(dialog, "full")
    self:bringToTopOfDesktop(dialog)
    if dialog.onShowKeyboard then
        pcall(function()
            dialog:onShowKeyboard()
        end)
    end
end

-- The desktop widget is modal, so any non-modal widget shown afterwards
-- (FrontLightWidget, InputDialog, etc.) lands *below* it and is
-- invisible. This helper moves a widget that UIManager just inserted
-- below the desktop to the top of the window stack, the same way the
-- existing menu button's settings entry fix works.
function WeReadDesktop:bringToTopOfDesktop(widget)
    local stack = UIManager._window_stack
    for i, entry in ipairs(stack) do
        if entry.widget == widget then
            table.remove(stack, i)
            table.insert(stack, entry)
            break
        end
    end
    UIManager:setDirty(widget, "full")
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
    UIManager:show(dialog, "full") -- full repaint: e-ink can swallow the
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
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog, "full")
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
        UIManager:show(dialog, "full")
        dialog:onShowKeyboard()
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
        local books = self.weread:getCachedShelf() or {}
        for _, book in ipairs(books) do
            if not book.cover_path then
                book.cover_path = self.weread:findCachedCover(book.book_id)
            end
        end
        return {
            weread = true,
            account_name = self.weread:getAccountName(),
            account_vid = self.weread:getAccountVid(),
            books = books,
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
        }
    end
    return { login_prompt = true }
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
    -- connected. Evaluated when the desktop is built.
    if self:isNetworkConnected() then
        table.insert(actions, {
            icon = "wifi",
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
    self.desktop_widget = BookshelfWidget:new{
        data = self:collectData(),
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
            self:refreshWereadShelf(true, {
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
    menu_items.wereaddesktop = {
        text = _("微读"),
        sorting_hint = "tools",
        callback = function()
            self:showDesktop()
        end,
    }
end

return WeReadDesktop
