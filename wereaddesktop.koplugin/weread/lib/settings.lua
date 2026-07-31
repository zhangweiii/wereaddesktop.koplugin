local DataStorage = require("datastorage")
local BookStore = require("weread.lib.book_store")
local Cookie = require("weread.lib.cookie")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings
Settings.AUTH_SCHEMA_VERSION = 1

local defaults = {
    auth_schema_version = Settings.AUTH_SCHEMA_VERSION,
    api_key = "",
    cookies = {},
    wr_ticket = "",
    wr_wrpa = "",
    account = {
        name = "",
        user_vid = "",
        login_method = "",
        login_time = 0,
    },
    books = {},
    downloads = {},
    sync = {
        pull_on_open = false,
        upload_on_close = false,
        ask_on_conflict = true,
        upload_interval_minutes = 0,
    },
    cache = {
        download_book_images = true,
        download_underlines_and_thoughts = false,
        show_annotations = true,
        -- When true, taps in the left/right edge zones never open thought popups
        -- (and native #wrthought link follow is suppressed there too).
        ignore_edge_thought_taps = true,
        -- Fraction of screen width on each side treated as the page-turn edge zone.
        edge_tap_ratio = 0.20,
        max_size_mb = 1024,
    },
    read_report = {
        enabled = false,
        mode = "manual",
        book_id = "",
        book_title = "",
        interval_seconds = 30,
        report_on_open = true,
    },
    advanced = {
        developer_logs = false,
    },
    shelf = {
        sort_order = "time_desc",
    },
    pending_finish_sync = {},
    download_dir = "",
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function ensure_dir(path)
    if not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

local function clear_auth_store(settings)
    settings:_set_dirty("api_key", "")
    settings:_set_dirty("cookies", {})
    settings:_set_dirty("wr_ticket", "")
    settings:_set_dirty("wr_wrpa", "")
    settings:_set_dirty("account", deepcopy(defaults.account))
end

function Settings:new()
    local data_dir = DataStorage:getFullDataDir() .. "/weread"
    ensure_dir(data_dir)
    local obj = setmetatable({
        data_dir = data_dir,
        default_cache_dir = data_dir .. "/cache",
        settings_file = DataStorage:getSettingsDir() .. "/weread.lua",
        -- Top-level keys / book records modified through this instance;
        -- flush() merges only these onto the current disk state (see
        -- there), so it must be initialized before any set/flush.
        _dirty = {},
        _dirty_books = {},
        _removed_books = {},
    }, self)
    obj.store = LuaSettings:open(obj.settings_file)
    -- cache_dir is the download root; defaults to <data_dir>/cache unless overridden.
    local download_dir = obj.store:readSetting("download_dir", "")
    obj.cache_dir = (type(download_dir) == "string" and download_dir ~= "") and download_dir or obj.default_cache_dir
    ensure_dir(obj.cache_dir)
    local cache = obj.store:readSetting("cache", deepcopy(defaults.cache))
    local cache_changed = false
    if cache.download_book_images == nil then
        cache.download_book_images = cache.download_images ~= false
        cache_changed = true
    end
    if cache.download_underlines_and_thoughts == nil then
        cache.download_underlines_and_thoughts = false
        cache_changed = true
    end
    if cache.show_annotations == nil then
        cache.show_annotations = true
        cache_changed = true
    end
    if cache.ignore_edge_thought_taps == nil then
        cache.ignore_edge_thought_taps = true
        cache_changed = true
    end
    if cache.edge_tap_ratio == nil then
        cache.edge_tap_ratio = 0.20
        cache_changed = true
    end
    if cache.download_images ~= nil then
        cache.download_images = nil
        cache_changed = true
    end
    if cache.download_mp_images ~= nil then
        cache.download_mp_images = nil
        cache_changed = true
    end
    if cache_changed then
        obj:_set_dirty("cache", cache)
        obj:flush()
    end
    local legacy_changed = false
    for _, key in ipairs({
        "config_auth_fingerprint",
        "config_preferences_fingerprint",
        "config_loaded",
        "curl_payload",
    }) do
        if obj.store:readSetting(key, nil) ~= nil then
            obj:_set_dirty(key, nil)
            legacy_changed = true
        end
    end
    local stored_auth_version = tonumber(obj.store:readSetting("auth_schema_version", 0)) or 0
    if stored_auth_version < Settings.AUTH_SCHEMA_VERSION then
        -- Authentication before schema v1 may have come from legacy manual
        -- flows and has no reliable QR account provenance.
        -- Invalidate only credentials; books, downloads and user preferences
        -- remain intact and the UI will guide the user through a fresh QR login.
        clear_auth_store(obj)
        obj:_set_dirty("auth_schema_version", Settings.AUTH_SCHEMA_VERSION)
        legacy_changed = true
    end
    if legacy_changed then
        obj:flush()
    end
    return obj
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    if key ~= "books" then
        return self.store:readSetting(key, deepcopy(default))
    end
    local indexes = self.store:readSetting("books", {})
    local books = {}
    for book_id, index in pairs(indexes or {}) do
        books[book_id] = BookStore.load(self, book_id, index)
    end
    return books
end

-- Record a top-level write through this instance. flush() only writes
-- back keys recorded here; everything else keeps the on-disk value, so
-- two live instances (file manager + reader contexts, or the weread
-- plugin sharing this file) never roll each other's changes back with a
-- stale full-table dump.
function Settings:_set_dirty(key, value)
    if value == nil then
        self.store:delSetting(key)
    else
        self.store:saveSetting(key, value)
    end
    self._dirty[key] = true
end

function Settings:set(key, value)
    if key == "books" and type(value) == "table" then
        local previous = self.store:readSetting("books", {})
        local indexes = {}
        for book_id, book in pairs(value) do
            local ok, index_or_err = BookStore.save(self, book_id, book)
            if not ok then
                error("Could not save book data: " .. tostring(index_or_err))
            end
            indexes[book_id] = index_or_err
            self._dirty_books[book_id] = true
            self._removed_books[book_id] = nil
        end
        for book_id in pairs(previous or {}) do
            if indexes[book_id] == nil then
                self._removed_books[book_id] = true
            end
        end
        value = indexes
    end
    self:_set_dirty(key, value)
end

-- Re-read one top-level key from disk into memory, unless this instance
-- has an unflushed local change to it. Used by callers whose data is
-- also written by another context (e.g. the shelf cache updated by the
-- reader-side progress sync).
function Settings:refresh(key)
    if self._dirty[key] then
        return
    end
    local disk = LuaSettings:open(self.settings_file).data
    if disk[key] == nil then
        self.store:delSetting(key)
    else
        self.store:saveSetting(key, disk[key])
    end
end

function Settings:flush()
    -- Merge locally modified keys onto the *current* disk state instead
    -- of dumping the whole in-memory view: the FM- and reader-context
    -- instances each hold a full snapshot of this file, and a naive
    -- flush by one would revert the other's committed writes.
    local disk = LuaSettings:open(self.settings_file).data
    for key in pairs(self._dirty) do
        if key == "books" and type(disk.books) == "table"
            and type(self.store.data.books) == "table" then
            -- Actual book data lives in per-book BookStore files (already
            -- written by set()); the in-file value is only a
            -- book_id -> { cache_dir } index. Merge it per book so one
            -- context's download is not reverted by the other context's
            -- progress save.
            for book_id in pairs(self._dirty_books) do
                disk.books[book_id] = self.store.data.books[book_id]
            end
            for book_id in pairs(self._removed_books) do
                disk.books[book_id] = nil
            end
        else
            disk[key] = self.store.data[key]
        end
    end
    self.store:reset(disk)
    self._dirty = {}
    self._dirty_books = {}
    self._removed_books = {}
    self.store:flush()
end

function Settings:update_auth(credentials, options)
    credentials = credentials or {}
    options = options or {}
    local changed = false

    if type(credentials.cookies) == "table" then
        local cookies = credentials.cookies
        if options.replace_cookies ~= true then
            cookies = Cookie.merge(self:get("cookies", {}), cookies)
        else
            cookies = deepcopy(cookies)
        end
        self:set("cookies", cookies)
        changed = true
    end

    for _, key in ipairs({ "api_key", "wr_ticket", "wr_wrpa" }) do
        local value = credentials[key]
        if type(value) == "string" then
            self:set(key, value)
            changed = true
        end
    end
    if type(credentials.account) == "table" then
        self:set("account", deepcopy(credentials.account))
        changed = true
    end

    if changed and options.flush ~= false then
        self:flush()
    end
    return changed
end

function Settings:merge_set_cookie(set_cookie, options)
    if not set_cookie or set_cookie == "" then
        return false
    end
    local cookies = Cookie.merge_set_cookie(self:get("cookies", {}), set_cookie)
    return self:update_auth({ cookies = cookies }, {
        replace_cookies = true,
        flush = not options or options.flush ~= false,
    })
end

function Settings:reset_account()
    clear_auth_store(self)
    self:flush()
end

function Settings:is_cookie_configured()
    return Cookie.has_login_cookie(self:get("cookies", {})) == true
end

function Settings:is_api_configured()
    return self:get("api_key", "") ~= ""
end

return Settings
