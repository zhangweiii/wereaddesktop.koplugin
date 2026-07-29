--[[--
Self-update for the WeRead desktop plugin via GitHub Releases.

check:  GET api.github.com/repos/<repo>/releases/latest, compare the
        tag against wereaddesktop_version.lua.
install: download the release's .tar.gz asset (built by
        tools/release.sh, with wereaddesktop.koplugin/ at its root) and
        unpack it over the plugins directory using KOReader's bundled
        ./tar — the same binary the KOReader OTA update uses. Plugins
        are only loaded at startup, so the caller asks for a restart.

All HTTP goes through the injected WeRead client (its request/
request_follow are generic HTTPS with explicit redirect handling, not
tied to weread.qq.com). No KOReader-internal hacks.
--]]--

local logger = require("weread.lib.logger").scoped("Updater")
local VERSION = require("wereaddesktop_version")

local Updater = {}

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

-- Download the release tarball and unpack it over plugins_dir.
-- Returns true, or nil + error string.
function Updater.install(client, asset_url, plugins_dir, work_dir)
    if not asset_url then
        return nil, "no_asset"
    end
    local ltn12 = require("ltn12")
    local tmp = (work_dir or ".") .. "/wereaddesktop_update.tar.gz"
    local file, ferr = io.open(tmp, "wb")
    if not file then
        return nil, tostring(ferr)
    end
    local _body, code = client:request_follow{
        url = asset_url,
        sink = ltn12.sink.file(file),
        timeout = { 15, 300 },
        diagnostic_api = "github_release_asset",
    }
    if tonumber(code) ~= 200 then
        os.remove(tmp)
        return nil, "http_" .. tostring(code or "error")
    end
    logger.info("installing update tarball into", plugins_dir)
    local ok = os.execute(string.format("./tar -xzf %q -C %q", tmp, plugins_dir))
    os.remove(tmp)
    if ok ~= true and ok ~= 0 then
        return nil, "extract_failed"
    end
    return true
end

return Updater
