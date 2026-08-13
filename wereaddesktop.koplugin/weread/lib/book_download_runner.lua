-- Single-book background download runner.
--
-- LuaSocket blocks KOReader's UI loop, so the existing chapter downloader
-- runs in a low-priority subprocess. The child writes a small atomic JSON
-- status file; the parent polls it and owns all UI, standby and cancellation.

local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local Content = require("weread.lib.content")
local logger = require("weread.lib.logger")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local Runner = {}
Runner.__index = Runner

local function load_ffi_util()
    local ok, ffi_util = pcall(require, "ffi/util")
    return ok and ffi_util or nil
end

local function encode(value)
    if not ok_json then error("JSON module is not available") end
    if json.encode then return json.encode(value) end
    return json:encode(value)
end

local function decode(value)
    if not ok_json then error("JSON module is not available") end
    if json.decode then return json.decode(value) end
    return json:decode(value)
end

local function write_state(path, state)
    local ok, payload = pcall(encode, state)
    if not ok then return false, payload end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then return false, err end
    local wrote, write_err = file:write(payload)
    local closed = file:close()
    if not wrote or not closed then
        os.remove(tmp_path)
        return false, write_err or "close_failed"
    end
    local renamed, rename_err = os.rename(tmp_path, path)
    if not renamed then
        os.remove(tmp_path)
        return false, rename_err
    end
    return true
end

local function read_state(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local payload = file:read("*a")
    file:close()
    local ok, state = pcall(decode, payload)
    return ok and type(state) == "table" and state or nil
end

local function safe_error(err)
    local text = tostring(err or "unknown_error"):gsub("[%c]+", " ")
    return #text > 300 and text:sub(1, 300) .. "..." or text
end

local function safe_call(label, callback, ...)
    if type(callback) ~= "function" then return end
    local ok, err = pcall(callback, ...)
    if not ok then
        logger.warn("book download runner " .. label .. " failed:", err)
    end
end

local function merge_download_record(settings, book_id, download_record)
    if type(download_record) ~= "table" then
        error("download_record_missing")
    end
    if type(settings) ~= "table"
        or type(settings.get_book) ~= "function"
        or type(settings.save_book) ~= "function" then
        error("download_settings_unavailable")
    end
    local current = settings:get_book(book_id) or { book_id = book_id }
    for _, key in ipairs({
        "title", "author", "cover", "cached_file", "cached_chapters",
        "reader_url", "cache_dir",
    }) do
        if download_record[key] ~= nil then
            current[key] = download_record[key]
        end
    end
    settings:save_book(book_id, current)
    if type(settings.flush) == "function" then
        settings:flush()
    end
end

local function prevent_os_standby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = true
    end
end

local function allow_os_standby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = false
    end
end

function Runner:new(options)
    options = options or {}
    return setmetatable({
        bridge = assert(options.bridge, "book download runner bridge is required"),
        ui_manager = options.ui_manager or UIManager,
        ffi_util = options.ffi_util or load_ffi_util(),
        clock = options.clock or os.time,
        poll_interval = options.poll_interval or 0.5,
        read_state = options.read_state or read_state,
        write_state = options.write_state or write_state,
        sleep = options.sleep,
        on_state = options.on_state,
        on_complete = options.on_complete,
        active = nil,
        poll_task = nil,
        standby_guard = false,
    }, self)
end

function Runner:_statePath(book_id)
    local safe_id = tostring(book_id or ""):gsub("[^%w%._-]", "_")
    local dir = self.bridge.settings.cache_dir .. "/" .. safe_id
    local made, err = Content.ensure_dir_tree(dir)
    if not made then return nil, err or "mkdir_failed" end
    return dir .. "/download-status.json"
end

function Runner:_beginStandby()
    if self.standby_guard then return end
    self.standby_guard = true
    self.ui_manager:preventStandby()
    prevent_os_standby()
end

function Runner:_endStandby()
    if not self.standby_guard then return end
    self.standby_guard = false
    self.ui_manager:allowStandby()
    allow_os_standby()
end

function Runner:_unschedulePoll()
    if self.poll_task and self.ui_manager.unschedule then
        self.ui_manager:unschedule(self.poll_task)
    end
    self.poll_task = nil
end

function Runner:_schedulePoll()
    self:_unschedulePoll()
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    self.ui_manager:scheduleIn(self.poll_interval, task)
end

function Runner:_write(entry, state)
    state.book_id = entry.book_id
    state.book_title = entry.book_title
    state.updated_at = self.clock()
    local ok, err = self.write_state(entry.state_path, state)
    if not ok then
        logger.warn("book download status write failed:", tostring(err))
    end
    return ok
end

function Runner:_runChild(entry)
    local bridge = self.bridge
    local queue = {}
    local completed = false
    local last_progress = 0

    local function finish(ok, path, err, metadata)
        if completed then return end
        completed = true
        self:_write(entry, {
            status = ok and "complete" or "failed",
            progress = ok and entry.total or last_progress,
            total = entry.total,
            path = ok and path or nil,
            error = ok and nil or safe_error(err),
            failed_chapters = metadata and metadata.failed_count or 0,
            download_record = ok and metadata
                and metadata.download_record or nil,
        })
    end

    bridge.downloader = nil
    local downloader = bridge:_getDownloader()
    downloader.schedule_step = function(fn, delay)
        queue[#queue + 1] = { fn = fn, delay = delay or 0 }
    end
    downloader.show_info = function() end
    downloader.show_transient = function() end
    downloader.refresh_ui = function() end
    downloader.refresh_shelf = function() end
    downloader.open_file = function() end
    downloader.show_overlay = function() return nil end
    if bridge.client then
        -- Keep response cookies usable within this child, but never flush its
        -- fork-time authentication snapshot over the parent's live settings.
        bridge.client.persist_response_cookies = false
    end
    downloader.run_online_task = function(_label, fn)
        fn()
        return true
    end

    local ok, started_or_err = pcall(bridge.downloadBook, bridge,
        entry.book, entry.chapters, function(path, err, metadata)
            finish(path ~= nil, path, err, metadata)
        end, {
            fill_missing = entry.options.fill_missing == true,
            include_comments = entry.options.include_comments == true,
            open_on_complete = false,
            headless = true,
            on_progress = function(title, progress, total)
                last_progress = math.max(last_progress, tonumber(progress) or 0)
                self:_write(entry, {
                    status = "running",
                    title = title,
                    progress = last_progress,
                    total = tonumber(total) or entry.total,
                })
            end,
        })
    if not ok then
        finish(false, nil, started_or_err)
        return
    end
    if started_or_err == false and not completed then
        finish(false, nil, "download_not_started")
        return
    end

    local socket_ok, socket = pcall(require, "socket")
    while not completed and #queue > 0 do
        local item = table.remove(queue, 1)
        if item.delay > 0 then
            if type(self.sleep) == "function" then
                self.sleep(item.delay)
            elseif socket_ok and socket.sleep then
                socket.sleep(item.delay)
            end
        end
        item.fn()
    end
    if not completed then
        finish(false, nil, "download_worker_stopped")
    end
end

function Runner:start(book, chapters, options)
    if self.active then return false, "download_in_progress" end
    if not self.ffi_util
        or type(self.ffi_util.runInSubProcess) ~= "function"
        or type(self.ffi_util.isSubProcessDone) ~= "function" then
        return false, "subprocess_unavailable"
    end
    local book_id = type(book) == "table" and tostring(book.book_id or "") or ""
    if book_id == "" or type(chapters) ~= "table" or #chapters == 0 then
        return false, "invalid_download"
    end
    local state_path, path_err = self:_statePath(book_id)
    if not state_path then return false, path_err end
    local entry = {
        book = book,
        book_id = book_id,
        book_title = tostring(book.text or book.title or ""),
        chapters = chapters,
        total = #chapters,
        options = options or {},
        state_path = state_path,
        cancelled = false,
        state_signature = nil,
    }
    local initial = {
        status = "running",
        title = "准备下载",
        progress = 0,
        total = entry.total,
    }
    if not self:_write(entry, initial) then
        return false, "status_write_failed"
    end

    self:_beginStandby()
    local ok, pid, spawn_err = pcall(self.ffi_util.runInSubProcess,
        function() self:_runChild(entry) end)
    if not ok or not pid then
        self:_endStandby()
        self:_write(entry, {
            status = "failed", progress = 0, total = entry.total,
            error = safe_error(ok and spawn_err or pid),
        })
        return false, "subprocess_start_failed"
    end
    entry.pid = pid
    entry.state = initial
    entry.state_signature = self:_stateSignature(initial)
    self.active = entry
    -- The child inherited the pending library record at fork time; the parent
    -- must discard its copy so a later download cannot accidentally reuse it.
    self.bridge._pending_book = nil
    safe_call("state callback", self.on_state, initial, entry)
    self:_schedulePoll()
    return true
end

function Runner:_stateSignature(state)
    if type(state) ~= "table" then return "" end
    local total = math.max(1, tonumber(state.total) or 1)
    local percent = math.floor(100 * (tonumber(state.progress) or 0) / total)
    -- The cover only renders status + percentage. Ignoring stage-title-only
    -- changes avoids unnecessary full-grid repaints on e-ink screens.
    return table.concat({ state.status or "", percent }, "|")
end

function Runner:_poll()
    local active = self.active
    if not active then return end
    local state = self.read_state(active.state_path)
    if type(state) == "table" then
        local signature = self:_stateSignature(state)
        if signature ~= active.state_signature then
            active.state_signature = signature
            active.state = state
            safe_call("state callback", self.on_state, state, active)
        end
    end
    local ok, done = pcall(self.ffi_util.isSubProcessDone, active.pid)
    if not ok then
        done = true
        state = { status = "failed", error = "subprocess_poll_failed" }
    end
    if not done then
        self:_schedulePoll()
        return
    end

    self.active = nil
    self:_endStandby()
    -- The first read above can race with the child's final atomic rename:
    -- once waitpid reports exit, always read the terminal file again.
    if ok then
        state = self.read_state(active.state_path) or state or {}
    end
    if active.cancelled then
        state = {
            book_id = active.book_id,
            book_title = active.book_title,
            status = "cancelled",
            progress = state.progress or 0,
            total = active.total,
        }
        self:_write(active, state)
    elseif state.status ~= "complete" and state.status ~= "failed" then
        state.status = "failed"
        state.error = state.error or "download_worker_exited"
        self:_write(active, state)
    end
    if state.status == "complete" then
        local merged, merge_err = pcall(merge_download_record,
            self.bridge.settings, active.book_id, state.download_record)
        if not merged then
            state.status = "failed"
            state.error = safe_error(merge_err)
            self:_write(active, state)
        end
    end
    active.state = state
    safe_call("state callback", self.on_state, state, active)
    safe_call("completion callback", self.on_complete,
        state.status == "complete", state, active)
end

function Runner:isActive(book_id)
    if not self.active then return false end
    return book_id == nil
        or self.active.book_id == tostring(book_id)
end

function Runner:getState()
    if not self.active then return nil end
    return self.active.state or self.read_state(self.active.state_path)
end

function Runner:cancel(book_id)
    local active = self.active
    if not active or (book_id ~= nil
        and active.book_id ~= tostring(book_id)) then
        return false
    end
    if active.cancelled then return true end
    active.cancelled = true
    if type(self.ffi_util.terminateSubProcess) == "function" then
        pcall(self.ffi_util.terminateSubProcess, active.pid)
    end
    self:_write(active, {
        status = "cancelling",
        progress = active.state and active.state.progress or 0,
        total = active.total,
    })
    self:_schedulePoll()
    return true
end

function Runner:shutdown()
    if not self.active then
        self:_unschedulePoll()
        self:_endStandby()
        return
    end
    local active = self.active
    self:cancel(active.book_id)
    self:_unschedulePoll()
    self.active = nil
    self:_endStandby()
    -- SIGKILL is asynchronous. Reap without invoking UI callbacks because
    -- the owning desktop/plugin is already closing.
    if type(self.ffi_util.isSubProcessDone) == "function" then
        local function reap()
            local ok, done = pcall(
                self.ffi_util.isSubProcessDone, active.pid)
            if ok and not done then
                self.ui_manager:scheduleIn(self.poll_interval, reap)
            end
        end
        self.ui_manager:scheduleIn(self.poll_interval, reap)
    end
end

return Runner
