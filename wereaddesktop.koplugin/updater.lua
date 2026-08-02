--[[--
Self-update for the WeRead desktop plugin via GitHub Releases.

check:  GET api.github.com/repos/<repo>/releases/latest for stable, or
        /releases?per_page=100 for beta/alpha, then compare the tag against
        wereaddesktop_version.lua.
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
local CHANNEL_LIMIT = {
    stable = 0,
    beta = 1,
    alpha = 2,
}
local CHANNEL_LABELS = {
    stable = "稳定版",
    beta = "Beta 测试版",
    alpha = "Alpha 实验版",
}

function Updater.current_version()
    return VERSION
end

function Updater.normalize_update_channel(channel)
    channel = tostring(channel or ""):lower()
    return CHANNEL_LIMIT[channel] and channel or "stable"
end

function Updater.update_channel_label(channel)
    channel = Updater.normalize_update_channel(channel)
    return CHANNEL_LABELS[channel]
end

function Updater.get_update_channel()
    local settings = rawget(_G, "G_reader_settings")
    if settings and type(settings.readSetting) == "function" then
        local ok, channel = pcall(settings.readSetting, settings,
            "wereaddesktop_update_channel")
        if ok then
            return Updater.normalize_update_channel(channel)
        end
    end
    return "stable"
end

function Updater.repo()
    local repo = G_reader_settings:readSetting("wereaddesktop_update_repo")
    if type(repo) == "string" and repo:match("^[%w%.%-%_]+/[%w%.%-%_]+$") then
        return repo
    end
    return GITHUB_REPO
end

local function has_leading_zero(value)
    return #value > 1 and value:sub(1, 1) == "0"
end

local function parse_semver(value)
    local text = tostring(value or "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    local major, minor, patch = text:match("^v?(%d+)%.(%d+)%.(%d+)$")
    local stage, sequence
    if not major then
        major, minor, patch, stage, sequence = text:match(
            "^v?(%d+)%.(%d+)%.(%d+)%-(%a+)%.(%d+)$")
        if stage ~= "alpha" and stage ~= "beta" then
            return nil
        end
    end
    if not major or has_leading_zero(major)
        or has_leading_zero(minor) or has_leading_zero(patch)
        or (sequence and has_leading_zero(sequence)) then
        return nil
    end
    local parsed = {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        stage = stage,
        sequence = sequence and tonumber(sequence) or nil,
    }
    parsed.version = string.format("%d.%d.%d", parsed.major,
        parsed.minor, parsed.patch)
    if parsed.stage then
        parsed.version = parsed.version .. "-" .. parsed.stage .. "."
            .. tostring(parsed.sequence)
    end
    return parsed
end

function Updater.release_channel(version)
    local parsed = parse_semver(version)
    if not parsed then
        return nil
    end
    return parsed.stage or "stable"
end

local function channel_is_allowed(candidate, requested)
    return CHANNEL_LIMIT[candidate] <= CHANNEL_LIMIT[requested]
end

-- -1 when a < b, 0 when equal, 1 when a > b. Returns nil for an invalid
-- version so callers cannot accidentally treat an arbitrary tag as a release.
function Updater.compare(a, b)
    local pa, pb = parse_semver(a), parse_semver(b)
    if not pa or not pb then
        return nil
    end
    for _, field in ipairs({ "major", "minor", "patch" }) do
        if pa[field] ~= pb[field] then
            return pa[field] < pb[field] and -1 or 1
        end
    end
    if pa.stage == pb.stage then
        if not pa.stage or pa.sequence == pb.sequence then
            return 0
        end
        return pa.sequence < pb.sequence and -1 or 1
    end
    if not pa.stage then
        return 1
    end
    if not pb.stage then
        return -1
    end
    local stage_rank = { alpha = 0, beta = 1 }
    return stage_rank[pa.stage] < stage_rank[pb.stage] and -1 or 1
end

local function expected_asset_name(version)
    return PLUGIN_NAME .. "-v" .. version .. ".tar.gz"
end

local function find_asset(release, version)
    local expected = expected_asset_name(version)
    local legacy_url
    local assets = type(release.assets) == "table" and release.assets or {}
    for _, asset in ipairs(assets) do
        if type(asset) == "table"
            and type(asset.name) == "string"
            and type(asset.browser_download_url) == "string" then
            if asset.name == expected then
                return asset.browser_download_url
            end
            if not legacy_url and asset.name:match("%.tar%.gz$") then
                legacy_url = asset.browser_download_url
            end
        end
    end
    return legacy_url
end

local function next_page_url(headers)
    local link
    if type(headers) == "table" then
        for key, value in pairs(headers) do
            if type(key) == "string" and key:lower() == "link" then
                link = value
                break
            end
        end
    end
    if type(link) == "table" then
        link = link[1]
    end
    if type(link) ~= "string" then
        return nil
    end
    for part in link:gmatch("[^,]+") do
        local url, parameters = part:match(
            "^%s*<([^>]+)>%s*;%s*(.+)%s*$")
        local relations = parameters
            and parameters:match('rel%s*=%s*"([^"]+)"')
        if not relations and parameters then
            relations = parameters:match("rel%s*=%s*([^;%s]+)")
        end
        local has_next = false
        if relations then
            for relation in relations:gmatch("%S+") do
                if relation == "next" then
                    has_next = true
                    break
                end
            end
        end
        if url and has_next then
            return url
        end
    end
end

local function release_candidate(release, requested_channel)
    if type(release) ~= "table" or release.draft == true then
        return nil
    end
    local version = release.tag_name
    local channel = Updater.release_channel(version)
    if not channel or not channel_is_allowed(channel, requested_channel) then
        return nil
    end
    version = parse_semver(version).version
    local asset_url = find_asset(release, version)
    if not asset_url then
        return nil
    end
    return {
        version = version,
        channel = channel,
        notes = tostring(release.body or ""),
        asset_url = asset_url,
        page_url = release.html_url,
    }
end

-- Fetch the newest installable release accepted by the selected channel.
-- Returns { version=, channel=, notes=, asset_url=, page_url= } or nil, err.
function Updater.fetch_latest(client, requested_channel)
    local channel = Updater.normalize_update_channel(
        requested_channel or Updater.get_update_channel())
    local repo = Updater.repo()
    if not repo then
        return nil, "repo_not_configured"
    end
    local endpoint = "/releases/latest"
    if channel ~= "stable" then
        endpoint = "/releases?per_page=100"
    end
    local request_url = "https://api.github.com/repos/" .. repo .. endpoint
    local function request_page(url)
        local body, code, headers = client:request_follow{
            url = url,
            timeout = { 15, 30 },
            diagnostic_api = channel == "stable"
                and "github_latest_release" or "github_releases",
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
        return data, nil, headers
    end
    local data, err, headers = request_page(request_url)
    if not data then
        return nil, err
    end
    if channel == "stable" then
        local latest = release_candidate(data, channel)
        if not latest then
            return nil, "no_matching_release"
        end
        return latest
    end
    local candidates = {}
    local function collect_candidates(releases)
        for _, release in ipairs(releases) do
            local candidate = release_candidate(release, channel)
            if candidate then
                table.insert(candidates, candidate)
            end
        end
    end
    collect_candidates(data)
    local visited = { [request_url] = true }
    local next_url = next_page_url(headers)
    while next_url do
        if visited[next_url] then
            break
        end
        visited[next_url] = true
        local page, page_err, page_headers = request_page(next_url)
        if not page then
            return nil, page_err
        end
        collect_candidates(page)
        next_url = next_page_url(page_headers)
    end
    if #candidates == 0 then
        return nil, "no_matching_release"
    end
    table.sort(candidates, function(left, right)
        return Updater.compare(left.version, right.version) > 0
    end)
    return candidates[1]
end

function Updater.is_newer(latest_version)
    local comparison = Updater.compare(latest_version, VERSION)
    return comparison ~= nil and comparison > 0
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
