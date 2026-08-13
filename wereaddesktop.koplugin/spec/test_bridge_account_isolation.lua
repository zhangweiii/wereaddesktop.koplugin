-- Account-isolation regression tests for wereadbridge.lua.

package.path = package.path .. ";./?.lua"

local noop = function() end
local settings
local login_mode = "active"
local qr_instances = {}

package.preload["datastorage"] = function()
    return { getFullDataDir = function() return "/tmp/weread-bridge-test" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        mkdir = function() return true end,
        dir = function() return function() return nil end end,
    }
end
package.preload["ffi/sha2"] = function()
    return { md5 = function(value) return tostring(value) end }
end
package.preload["weread.lib.client"] = function()
    return { new = function() return {} end }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.downloader"] = function() return {} end
package.preload["weread.lib.storage"] = function()
    return { summary = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        is_mp_book = function() return false end,
    }
end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return { info = noop, warn = noop, err = noop }
        end,
    }
end

local QRLogin = {}
QRLogin.__index = QRLogin
function QRLogin:new(host, client, login_settings)
    local instance = setmetatable({
        host = host,
        client = client,
        settings = login_settings,
        flow_active = false,
        cancel_count = 0,
    }, self)
    qr_instances[#qr_instances + 1] = instance
    return instance
end
function QRLogin:cancel()
    self.cancel_count = self.cancel_count + 1
    self.flow_active = false
end
function QRLogin:start()
    self:cancel()
    if login_mode == "active" then
        self.flow_active = true
    end
end
package.preload["weread.lib.qr_login"] = function() return QRLogin end

local function make_settings()
    local object = {
        data = {
            account = { user_vid = "account-a" },
            api_key = "key",
            cookies = {},
            books = {},
        },
        flushes = 0,
    }
    function object:get(key, default)
        local value = self.data[key]
        return value == nil and default or value
    end
    function object:set(key, value)
        self.data[key] = value
    end
    function object:refresh() end
    function object:flush()
        self.flushes = self.flushes + 1
    end
    function object:update_auth(credentials)
        if type(credentials.account) == "table" then
            self.data.account = credentials.account
        end
        return true
    end
    function object:reset_account()
        self.data.account = { user_vid = "" }
        self.data.api_key = ""
        self.data.cookies = {}
    end
    function object:is_api_configured()
        return self.data.api_key ~= ""
    end
    function object:is_cookie_configured()
        return false
    end
    return object
end

package.preload["weread.lib.settings"] = function()
    return { new = function() return settings end }
end

settings = make_settings()
local Bridge = require("wereadbridge")
local bridge = Bridge:new({})

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

-- Starting a second login cancels and finalizes the first flow.
local first_result
bridge:startLogin(function(ok) first_result = ok end)
local first_qr = qr_instances[#qr_instances]
local second_result
bridge:startLogin(function(ok) second_result = ok end)
local second_qr = qr_instances[#qr_instances]
check("second login cancels the previous QR flow",
    first_qr ~= second_qr and first_qr.cancel_count == 2
    and first_result == false and second_result == nil)

-- A successful account switch clears account-scoped caches.
settings.data.wereaddesktop_shelf = { { book_id = "a" } }
settings.data.wereaddesktop_shelf_user_vid = "account-a"
settings.data.wereaddesktop_shelf_fetched_at = 1
bridge.pending_summary = { elapsed = 10 }
bridge.pending_summary_at = os.time()
bridge.pending_summary_vid = "account-a"
settings:update_auth({ account = { user_vid = "account-b" } })
check("successful account switch completes only the active login",
    second_result == true and bridge.qr_login == nil)
check("successful account switch clears shelf and pending-summary caches",
    settings.data.wereaddesktop_shelf == nil
    and settings.data.wereaddesktop_shelf_user_vid == nil
    and settings.data.wereaddesktop_shelf_fetched_at == nil
    and bridge.pending_summary == nil)

-- Cached shelf and pending summaries are keyed by the current account.
settings.data.account = { user_vid = "account-a" }
settings.data.wereaddesktop_shelf = { { book_id = "a" } }
settings.data.wereaddesktop_shelf_user_vid = "account-a"
check("shelf cache is visible to its owner", bridge:getCachedShelf()[1].book_id == "a")
settings.data.account = { user_vid = "account-b" }
check("shelf cache is hidden from another account", bridge:getCachedShelf() == nil)

settings.data.books = {
    a = {
        pending_upload_user_vid = "account-a",
        pending_upload_position = {},
        pending_upload_elapsed = 10,
    },
    b = {
        pending_upload_user_vid = "account-b",
        pending_upload_position = {},
        pending_upload_elapsed = 20,
    },
    legacy = {
        pending_upload_position = {},
        pending_upload_elapsed = 30,
    },
}
local summary_b = bridge:getPendingUploadSummary()
check("pending summary includes only the current account",
    summary_b.count == 1 and summary_b.elapsed == 20)
local cleared, elapsed = bridge:clearPendingUploadElapsed()
check("pending clear preserves foreign and unowned queues",
    cleared == 1 and elapsed == 20
    and settings.data.books.a.pending_upload_elapsed == 10
    and settings.data.books.legacy.pending_upload_elapsed == 30)

-- Offline start finalizes synchronously and restores update_auth.
login_mode = "offline"
local original_update_auth = settings.update_auth
local offline_result
bridge:startLogin(function(ok) offline_result = ok end)
check("offline login restores the auth method and reports failure",
    offline_result == false and settings.update_auth == original_update_auth
    and bridge.qr_login == nil)

-- Per-download choices survive the bridge between the desktop and engine.
local downloader_options
bridge._pending_book = { book_id = "book-1" }
bridge.downloader = {
    start = function(_, _book, _chapters, _suffix, options)
        downloader_options = options
        return true
    end,
}
bridge:downloadBook({ book_id = "book-1" }, {}, nil, {
    include_comments = true,
    open_on_complete = false,
})
check("bridge forwards the per-download comment choice",
    downloader_options and downloader_options.include_comments == true
    and downloader_options.open_on_complete == false)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
