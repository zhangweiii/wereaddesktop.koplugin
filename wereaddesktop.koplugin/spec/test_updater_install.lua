--[[--
KOReader-runtime integration test for updater.lua.

Unlike test_updater.lua, this test does not mock archive extraction. It uses
KOReader's real LuaJIT, ffi/archiver, and libarchive to build and install a
tar.gz fixture.

Run from the KOReader directory:
    PLUGIN_DIR=/path/to/wereaddesktop.koplugin \
        ./luajit "$PLUGIN_DIR/spec/test_updater_install.lua"
--]]--

local PLUGIN_DIR = assert(os.getenv("PLUGIN_DIR"),
    "PLUGIN_DIR must point to wereaddesktop.koplugin")
package.path = package.path .. ";" .. PLUGIN_DIR .. "/?.lua"

require("ffi/loadlib")
local Archiver = require("ffi/archiver")
local lfs = require("libs/libkoreader-lfs")

G_reader_settings = {
    readSetting = function() return nil end,
}

local Updater = require("updater")
local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local TMP = os.getenv("TMPDIR") or "/tmp"
local ROOT = TMP .. "/wereaddesktop_install_" .. tostring(os.time())
    .. "_" .. tostring(math.random(100000))
local SOURCE_PLUGIN = ROOT .. "/source/wereaddesktop.koplugin"
local WORK_DIR = ROOT .. "/work"
local PLUGINS_DIR = ROOT .. "/plugins"
local TARGET_PLUGIN = PLUGINS_DIR .. "/wereaddesktop.koplugin"
local ROLLBACK_PLUGINS_DIR = ROOT .. "/rollback_plugins"
local ROLLBACK_TARGET = ROLLBACK_PLUGINS_DIR
    .. "/wereaddesktop.koplugin"
local ARCHIVE_PATH = ROOT .. "/release.tar.gz"

local mkdir_ok = os.execute("mkdir -p "
    .. string.format("%q", SOURCE_PLUGIN) .. " "
    .. string.format("%q", WORK_DIR) .. " "
    .. string.format("%q", TARGET_PLUGIN) .. " "
    .. string.format("%q", ROLLBACK_TARGET))
check("creates isolated integration directories",
    mkdir_ok == true or mkdir_ok == 0)

local function write_file(path, payload)
    local file = assert(io.open(path, "wb"))
    assert(file:write(payload))
    assert(file:close())
end

local main_payload = "return { integration_fixture = true }\n"
write_file(SOURCE_PLUGIN .. "/main.lua", main_payload)
write_file(SOURCE_PLUGIN .. "/_meta.lua",
    "return { name = \"integration fixture\" }\n")
write_file(SOURCE_PLUGIN .. "/wereaddesktop_version.lua",
    'return "9.9.9"\n')

local old_payload = "return { old_plugin = true }\n"
write_file(TARGET_PLUGIN .. "/main.lua", old_payload)
write_file(TARGET_PLUGIN .. "/old-only.lua", "return true\n")
local rollback_payload = "return { rollback_fixture = true }\n"
write_file(ROLLBACK_TARGET .. "/main.lua", rollback_payload)

local writer = Archiver.Writer:new()
check("opens tar.gz fixture with KOReader libarchive",
    writer:open(ARCHIVE_PATH, "tar.gz"))
local add_result = writer:addPath(
    "wereaddesktop.koplugin", SOURCE_PLUGIN, true)
check("adds plugin tree to tar.gz fixture",
    add_result == true or writer.err == nil)
writer:close()

local fixture_reader = Archiver.Reader:new()
local fixture_has_main = false
if fixture_reader:open(ARCHIVE_PATH) then
    for entry in fixture_reader:iterate() do
        if entry.path == "wereaddesktop.koplugin/main.lua" then
            fixture_has_main = true
        end
    end
    fixture_reader:close()
end
check("tar.gz fixture contains the plugin entry", fixture_has_main)

local client = {
    request_follow = function(_self, opts)
        local archive = assert(io.open(ARCHIVE_PATH, "rb"))
        while true do
            local chunk = archive:read(16384)
            if not chunk then break end
            assert(opts.sink(chunk))
        end
        archive:close()
        assert(opts.sink(nil))
        return nil, 200
    end,
}

local installed, install_err = Updater.install(
    client, "fixture://release", PLUGINS_DIR, WORK_DIR)
check("installs tar.gz through the real KOReader extraction path",
    installed == true and install_err == nil)

local installed_main = io.open(
    TARGET_PLUGIN .. "/main.lua", "rb")
local installed_payload = installed_main and installed_main:read("*a")
if installed_main then installed_main:close() end
check("installed plugin contains the fixture payload",
    installed_payload == main_payload)
check("atomic replacement removes files absent from the new release",
    lfs.attributes(TARGET_PLUGIN .. "/old-only.lua", "mode") == nil)
check("successful replacement removes staging and backup directories",
    lfs.attributes(PLUGINS_DIR
        .. "/.wereaddesktop_update_staging", "mode") == nil
    and lfs.attributes(PLUGINS_DIR
        .. "/.wereaddesktop_update_backup", "mode") == nil)

local original_rename = os.rename
local staged_rollback = ROLLBACK_PLUGINS_DIR
    .. "/.wereaddesktop_update_staging/wereaddesktop.koplugin"
os.rename = function(from, to)
    if from == staged_rollback and to == ROLLBACK_TARGET then
        return nil, "simulated activation failure"
    end
    return original_rename(from, to)
end
local rollback_installed, rollback_err = Updater.install(
    client, "fixture://release", ROLLBACK_PLUGINS_DIR, WORK_DIR)
os.rename = original_rename

check("activation failure is reported after rollback",
    rollback_installed == nil and rollback_err == "install_swap_failed")
local rolled_back_main = io.open(ROLLBACK_TARGET .. "/main.lua", "rb")
local rolled_back_payload = rolled_back_main
    and rolled_back_main:read("*a")
if rolled_back_main then rolled_back_main:close() end
check("activation failure restores the previous plugin",
    rolled_back_payload == rollback_payload)
check("rollback removes staging and backup directories",
    lfs.attributes(ROLLBACK_PLUGINS_DIR
        .. "/.wereaddesktop_update_staging", "mode") == nil
    and lfs.attributes(ROLLBACK_PLUGINS_DIR
        .. "/.wereaddesktop_update_backup", "mode") == nil)

os.execute("rm -rf " .. string.format("%q", ROOT))

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
