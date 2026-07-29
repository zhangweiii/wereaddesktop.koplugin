--[[--
Self-update for the WeRead desktop plugin via GitHub Releases.

check:  GET api.github.com/repos/<repo>/releases/latest, compare the
        tag against wereaddesktop_version.lua.
install: download the release's .tar.gz asset (built by
        tools/release.sh, with wereaddesktop.koplugin/ at its root) and
        extract it with KOReader's libarchive binding into a staging
        directory. After validating the staged plugin, replace the live
        directory with rollback protection. Plugins are only loaded at
        startup, so the caller asks for a restart.

All HTTP goes through the injected WeRead client (its request/
request_follow are generic HTTPS with explicit redirect handling, not
tied to weread.qq.com). No KOReader-internal hacks.
--]]--

local logger = require("weread.lib.logger").scoped("Updater")
local lfs = require("libs/libkoreader-lfs")
local VERSION = require("wereaddesktop_version")

local Updater = {}
local PLUGIN_NAME = "wereaddesktop.koplugin"
local PLUGIN_PREFIX = PLUGIN_NAME .. "/"
local STAGING_NAME = ".wereaddesktop_update_staging"
local BACKUP_NAME = ".wereaddesktop_update_backup"
local REQUIRED_FILES = {
    "main.lua",
    "_meta.lua",
    "wereaddesktop_version.lua",
}

-- "owner/repo" publishing the releases. Override at runtime with the
-- wereaddesktop_update_repo setting (e.g. for testing a fork).
local GITHUB_REPO = "zhangweiii/wereaddesktop.koplugin"

function Updater.current_version()
    return VERSION
end

function Updater.repo()
    local repo = G_reader_settings:readSetting("wereaddesktop_update_repo")
    if type(repo) == "string" and repo:match("^[%w%.%-%_]+/[%w%.%-%_]+$") then
        return repo
    end
    return GITHUB_REPO
end

-- "v1.2.3" / "1.2" -> { 1, 2, 3 }
local function parse_version(value)
    local parts = {}
    for number in tostring(value or ""):gmatch("%d+") do
        table.insert(parts, tonumber(number))
    end
    return parts
end

-- -1 when a < b, 0 when equal, 1 when a > b (numeric, dotted).
function Updater.compare(a, b)
    local pa, pb = parse_version(a), parse_version(b)
    for i = 1, math.max(#pa, #pb) do
        local na, nb = pa[i] or 0, pb[i] or 0
        if na ~= nb then
            return na < nb and -1 or 1
        end
    end
    return 0
end

-- Fetch the latest release metadata. Returns
-- { version=, notes=, asset_url=|nil, page_url=|nil } or nil, err.
function Updater.fetch_latest(client)
    local repo = Updater.repo()
    if not repo then
        return nil, "repo_not_configured"
    end
    local body, code = client:request_follow{
        url = "https://api.github.com/repos/" .. repo .. "/releases/latest",
        timeout = { 15, 30 },
        diagnostic_api = "github_latest_release",
    }
    if tonumber(code) ~= 200 then
        return nil, "http_" .. tostring(code or "error")
    end
    local ok, data = pcall(function()
        return client:json_decode(body)
    end)
    if not ok or type(data) ~= "table" then
        return nil, "bad_response"
    end
    local latest = tostring(data.tag_name or data.name or ""):gsub("^%s*v", "")
    if latest == "" then
        return nil, "no_version"
    end
    local asset_url
    for _i, asset in ipairs(data.assets or {}) do
        if type(asset.name) == "string" and asset.name:match("%.tar%.gz$")
            and type(asset.browser_download_url) == "string" then
            asset_url = asset.browser_download_url
            break
        end
    end
    return {
        version = latest,
        notes = tostring(data.body or ""),
        asset_url = asset_url,
        page_url = data.html_url,
    }
end

function Updater.is_newer(latest_version)
    return Updater.compare(latest_version, VERSION) > 0
end

local function close_archive(reader)
    if reader then reader:close() end
end

local function path_mode(path)
    local attributes = lfs.symlinkattributes or lfs.attributes
    return attributes(path, "mode")
end

local function remove_tree(path)
    local mode = path_mode(path)
    if mode == nil then return true end
    if mode ~= "directory" then
        return os.remove(path)
    end

    local listed, list_err = pcall(function()
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local removed, remove_err = remove_tree(path .. "/" .. name)
                if not removed then error(remove_err or "remove failed") end
            end
        end
    end)
    if not listed then return nil, tostring(list_err) end
    return lfs.rmdir(path)
end

local function cleanup_path(path, label)
    local removed, remove_err = remove_tree(path)
    if not removed then
        logger.warn("cannot clean " .. label .. ":",
            path, tostring(remove_err))
    end
    return removed, remove_err
end

-- Extract with KOReader's libarchive binding. Unlike the bundled GNU tar,
-- this handles gzip internally and does not depend on the process cwd,
-- an external gzip executable, or shell exit-code conventions.
local function extract_archive(archive_path, plugins_dir)
    local loaded, Archiver = pcall(require, "ffi/archiver")
    if not loaded then
        logger.err("KOReader archiver unavailable:", tostring(Archiver))
        return nil, "archiver_unavailable"
    end

    local reader = Archiver.Reader:new()
    if not reader:open(archive_path) then
        logger.err("cannot open update archive:", tostring(reader.err))
        close_archive(reader)
        return nil, "archive_open_failed"
    end

    local entries = {}
    local required = {}
    for _, name in ipairs(REQUIRED_FILES) do
        required[PLUGIN_PREFIX .. name] = false
    end
    for entry in reader:iterate() do
        local original_path = tostring(entry.path or "")
        local path = original_path:gsub("^%./+", "")
        local is_plugin_root = path == PLUGIN_NAME
            or path == PLUGIN_PREFIX
        local is_plugin_entry = path:sub(1, #PLUGIN_PREFIX)
            == PLUGIN_PREFIX
        local has_parent_ref = path == ".."
            or path:match("^%.%./") ~= nil
            or path:match("/%.%./") ~= nil
            or path:match("/%.%.$") ~= nil
        if (not is_plugin_root and not is_plugin_entry)
            or has_parent_ref then
            close_archive(reader)
            return nil, "bad_tarball_layout"
        end
        if entry.mode ~= "file" and entry.mode ~= "directory" then
            close_archive(reader)
            return nil, "unsupported_tarball_entry"
        end
        if entry.mode == "file" and required[path] ~= nil then
            required[path] = true
        end
        table.insert(entries, {
            archive_path = original_path,
            destination = plugins_dir .. "/" .. path,
        })
    end
    if reader.err then
        logger.err("cannot read update archive:", tostring(reader.err))
        close_archive(reader)
        return nil, "archive_read_failed"
    end
    for _, found in pairs(required) do
        if not found then
            close_archive(reader)
            return nil, "bad_tarball_layout"
        end
    end

    for _, entry in ipairs(entries) do
        if not reader:extractToPath(
            entry.archive_path, entry.destination) then
            logger.err("cannot extract update entry:",
                entry.archive_path, tostring(reader.err))
            close_archive(reader)
            return nil, "extract_failed:" .. entry.archive_path
        end
    end
    close_archive(reader)
    return true
end

local function validate_staged_plugin(staged_plugin)
    for _, name in ipairs(REQUIRED_FILES) do
        if path_mode(staged_plugin .. "/" .. name) ~= "file" then
            return nil, "install_validation_failed:" .. name
        end
    end
    return true
end

local function recover_previous_install(target, backup, staging_root)
    if path_mode(backup) ~= nil then
        if path_mode(target) ~= nil then
            local removed, remove_err = remove_tree(backup)
            if not removed then return nil, remove_err end
        else
            local restored, restore_err = os.rename(backup, target)
            if not restored then return nil, restore_err end
        end
    end
    local removed, remove_err = remove_tree(staging_root)
    if not removed then return nil, remove_err end
    return true
end

local function install_archive(archive_path, plugins_dir)
    local staging_root = plugins_dir .. "/" .. STAGING_NAME
    local staged_plugin = staging_root .. "/" .. PLUGIN_NAME
    local target = plugins_dir .. "/" .. PLUGIN_NAME
    local backup = plugins_dir .. "/" .. BACKUP_NAME

    local recovered, recover_err = recover_previous_install(
        target, backup, staging_root)
    if not recovered then
        logger.err("cannot recover previous update:", tostring(recover_err))
        return nil, "install_recovery_failed"
    end

    local made, mkdir_err = lfs.mkdir(staging_root)
    if not made then
        logger.err("cannot create update staging directory:",
            tostring(mkdir_err))
        return nil, "install_staging_failed"
    end

    local extracted, extract_err = extract_archive(
        archive_path, staging_root)
    if not extracted then
        cleanup_path(staging_root, "failed update staging directory")
        return nil, extract_err
    end

    local valid, validation_err = validate_staged_plugin(staged_plugin)
    if not valid then
        cleanup_path(staging_root, "invalid update staging directory")
        return nil, validation_err
    end

    local had_target = path_mode(target) ~= nil
    if had_target then
        local backed_up, backup_err = os.rename(target, backup)
        if not backed_up then
            cleanup_path(staging_root, "update staging directory")
            logger.err("cannot back up current plugin:", tostring(backup_err))
            return nil, "install_backup_failed"
        end
    end

    local swapped, swap_err = os.rename(staged_plugin, target)
    if not swapped then
        local rollback_ok = true
        local rollback_err
        if had_target then
            rollback_ok, rollback_err = os.rename(backup, target)
        end
        cleanup_path(staging_root, "update staging directory")
        if not rollback_ok then
            logger.err("cannot roll back plugin update:",
                tostring(rollback_err))
            return nil, "install_rollback_failed"
        end
        logger.err("cannot activate staged plugin:", tostring(swap_err))
        return nil, "install_swap_failed"
    end

    cleanup_path(staging_root, "empty update staging directory")
    if had_target then
        cleanup_path(backup, "previous plugin backup")
    end
    return true
end

-- Download the release tarball, stage and validate it, then replace the
-- plugin directory with rollback protection.
-- Returns true, or nil + error string.
function Updater.install(client, asset_url, plugins_dir, work_dir)
    if not asset_url then
        return nil, "no_asset"
    end
    local tmp = (work_dir or ".") .. "/wereaddesktop_update.tar.gz"
    local file, ferr = io.open(tmp, "wb")
    if not file then
        return nil, tostring(ferr)
    end
    -- request_follow reuses the sink across redirects. Close at the end of
    -- each response, then reopen with "wb" when the next response starts so
    -- a 302 response body cannot be prepended to the final gzip payload.
    local function download_sink(chunk)
        if chunk == nil then
            if file then
                local close_ok, close_err = file:close()
                file = nil
                if not close_ok then return nil, close_err end
            end
            return 1
        end
        if not file then
            file, ferr = io.open(tmp, "wb")
            if not file then return nil, tostring(ferr) end
        end
        return file:write(chunk)
    end
    local _body, code = client:request_follow{
        url = asset_url,
        sink = download_sink,
        timeout = { 15, 300 },
        diagnostic_api = "github_release_asset",
    }
    if file then file:close() end
    if tonumber(code) ~= 200 then
        os.remove(tmp)
        return nil, "http_" .. tostring(code or "error")
    end
    logger.info("installing update tarball into", plugins_dir)
    local installed, install_err = install_archive(tmp, plugins_dir)
    os.remove(tmp)
    return installed, install_err
end

return Updater
