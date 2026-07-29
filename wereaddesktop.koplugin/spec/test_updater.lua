--[[--
Unit test for updater.lua (微读 self-update via GitHub Releases):
version comparison and latest-release parsing with a mocked HTTP
client. No network.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_updater.lua
--]]--

package.path = package.path .. ";./?.lua"

-- updater.lua reads the optional repo override from KOReader's global
-- settings object.
G_reader_settings = {
    store = {},
    readSetting = function(self, key)
        return self.store[key]
    end,
}

local Updater = require("updater")

local failures = 0
local function check(label, cond)
    if cond then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

-- Fake client: returns canned GitHub API responses; json_decode is a
-- tiny JSON stand-in fed with already-decoded tables.
local function make_client(release)
    return {
        last_url = nil,
        request_follow = function(self, opts)
            self.last_url = opts.url
            if not release then
                return nil, 404
            end
            return release.__raw, 200
        end,
        json_decode = function()
            return release
        end,
    }
end

----------------------------------------------------------------
-- Version comparison.
----------------------------------------------------------------
check("compare: equal versions", Updater.compare("0.1.0", "0.1.0") == 0)
check("compare: newer patch", Updater.compare("0.2.0", "0.1.0") == 1)
check("compare: older", Updater.compare("0.1.0", "1.0.0") == -1)
check("compare: v-prefix and short forms",
    Updater.compare("v0.1.0", "0.1") == 0
    and Updater.compare("0.10.0", "0.9.9") == 1)
check("is_newer against the bundled version",
    Updater.is_newer("999.0.0") == true
    and Updater.is_newer(Updater.current_version()) == false)

----------------------------------------------------------------
-- fetch_latest: repo configuration, parsing, asset discovery.
----------------------------------------------------------------
do
    -- No override: the baked-in default repo is used.
    local client = make_client{ __raw = "{}", tag_name = "v9.9.9" }
    local latest = Updater.fetch_latest(client)
    check("default repo is zhangweiii/wereaddesktop.koplugin",
        client.last_url
        == "https://api.github.com/repos/zhangweiii/wereaddesktop.koplugin/releases/latest"
        and latest and latest.version == "9.9.9")

    G_reader_settings.store.wereaddesktop_update_repo = "someone/koui"
    local release = {
        __raw = '{"tag_name":"v0.2.0"}',
        tag_name = "v0.2.0",
        body = "修复进度同步",
        html_url = "https://github.com/someone/koui/releases/tag/v0.2.0",
        assets = {
            { name = "checksums.txt", browser_download_url = "https://x/sums" },
            { name = "wereaddesktop.koplugin-v0.2.0.tar.gz",
                browser_download_url = "https://x/pkg.tar.gz" },
        },
    }
    client = make_client(release)
    latest, err = Updater.fetch_latest(client)
    check("fetch_latest hits the repo's releases endpoint",
        client.last_url
        == "https://api.github.com/repos/someone/koui/releases/latest")
    check("fetch_latest parses tag/notes/page",
        latest and latest.version == "0.2.0"
        and latest.notes == "修复进度同步"
        and latest.page_url == release.html_url)
    check("fetch_latest picks the .tar.gz asset",
        latest and latest.asset_url == "https://x/pkg.tar.gz")

    -- Release without a tarball asset: asset_url stays nil.
    client = make_client{
        __raw = "{}", tag_name = "v0.2.0",
        assets = { { name = "notes.txt", browser_download_url = "https://x/n" } },
    }
    latest = Updater.fetch_latest(client)
    check("release without tarball asset -> asset_url nil",
        latest and latest.asset_url == nil)

    -- HTTP failure propagates as an error.
    client = make_client(nil)
    latest, err = Updater.fetch_latest(client)
    check("HTTP failure -> nil + error", latest == nil and err == "http_404")

    G_reader_settings.store.wereaddesktop_update_repo = nil
end

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
