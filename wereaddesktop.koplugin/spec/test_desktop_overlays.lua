-- Regression harness for desktop overlays and reading-stat presentation.
-- Run from the plugin directory:
--     luajit spec/test_desktop_overlays.lua

package.path = package.path .. ";./?.lua"

local noop = function() end
local stack = {}
local restart_calls = 0

package.preload["desktop"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/textviewer"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/uimanager"] = function()
    local manager = {
        _window_stack = stack,
        show = function(self, widget)
            local entry = { widget = widget }
            if widget.modal == true then
                table.insert(self._window_stack, entry)
            else
                -- A non-modal widget is inserted below the desktop's modal
                -- surface in the KOReader stack model.
                table.insert(self._window_stack,
                    math.max(1, #self._window_stack), entry)
            end
        end,
        close = noop,
        setDirty = noop,
        forceRePaint = noop,
        scheduleIn = function(_, _delay, fn) fn() end,
        broadcastEvent = noop,
        askForRestart = function()
            restart_calls = restart_calls + 1
        end,
    }
    return manager
end
package.preload["updater"] = function()
    return {
        install = function()
            return true
        end,
    }
end
package.preload["datastorage"] = function()
    return {
        getDataDir = function() return "/data" end,
    }
end
package.preload["progressuploader"] = function()
    return {
        new = function(_, options) return options end,
        timeReplayStartDelay = function() return 0 end,
    }
end
package.preload["wereadbridge"] = function()
    return {
        new = function()
            return { isLoggedIn = function() return true end }
        end,
    }
end
package.preload["weread.lib.storage"] = function()
    return { format_bytes = function(bytes) return tostring(bytes) .. " B" end }
end
package.preload["weread.lib.annotations"] = function() return {} end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local WidgetContainer = {}
    WidgetContainer.__index = WidgetContainer
    function WidgetContainer:extend(options)
        options = options or {}
        setmetatable(options, { __index = self })
        options.__index = options
        return options
    end
    function WidgetContainer:new(options)
        options = options or {}
        setmetatable(options, self)
        return options
    end
    return WidgetContainer
end
package.preload["logger"] = function()
    return { warn = noop, info = noop, err = noop, dbg = noop }
end
package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end

G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = noop,
    delSetting = noop,
    flush = noop,
}

local WeReadDesktop = require("main")
local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local instance = WeReadDesktop:new{}
instance.desktop_widget = { modal = true }
stack[1] = { widget = instance.desktop_widget }

instance:showReadStats(
    { readTime = 3720, readDayNum = 3, readBookNum = 2, finishedBookNum = 1 },
    { totalReadTime = 7200, readBookCount = 4, finishedBookCount = 2 }
)
local stats_viewer
for _, entry in ipairs(stack) do
    if entry.widget ~= instance.desktop_widget then
        stats_viewer = entry.widget
    end
end
check("reading stats overlay is modal", stats_viewer.modal == true)
check("reading stats overlay is above desktop",
    stack[#stack].widget == stats_viewer)
check("reading stats uses product labels", stats_viewer.text:find("阅读时长", 1, true) ~= nil)
check("reading stats formats duration", stats_viewer.text:find("1小时2分钟", 1, true) ~= nil)
check("reading stats hides raw JSON keys", stats_viewer.text:find("readTime", 1, true) == nil)
check("reading stats hides JSON punctuation", stats_viewer.text:find("{", 1, true) == nil)
local wrapped_text = instance:formatReadStats(
    { data = { readTime = 60, readDayCount = 1 } }, {})
check("reading stats unwraps service response", wrapped_text:find("1分钟", 1, true) ~= nil)

instance.weread = {
    getStorageSummary = function()
        return { book_count = 1, bytes = 2048, files = 2, books = {} }
    end,
}
instance:showStorageManager()
local storage_viewer
for _, entry in ipairs(stack) do
    if entry.widget ~= instance.desktop_widget
        and entry.widget ~= stats_viewer then
        storage_viewer = entry.widget
    end
end
check("storage overlay is modal", storage_viewer.modal == true)
check("storage overlay is above desktop",
    stack[#stack].widget == storage_viewer)

for index = #stack, 1, -1 do
    table.remove(stack, index)
end
stack[1] = { widget = instance.desktop_widget }
instance:showInfo("test")
local info_viewer = stack[#stack].widget
check("info overlay is modal", info_viewer.modal == true)
check("info overlay is above desktop",
    stack[#stack].widget == info_viewer)

instance:showInputDialog({ modal = true })
local input_dialog = stack[#stack].widget
check("input overlay is above desktop",
    input_dialog ~= instance.desktop_widget
        and stack[#stack].widget == input_dialog)

local cleared = false
instance.refreshDesktop = noop
instance.weread = {
    getPendingUploadSummary = function()
        return { count = 1, time_count = 1, elapsed = 125, replay_chunks = 3 }
    end,
    clearPendingUploadElapsed = function()
        cleared = true
        return 1, 125
    end,
}
instance:showSyncStatus()
local sync_dialog = stack[#stack].widget
check("offline-time dialog shows the queued duration",
    sync_dialog.title:find("2分钟", 1, true) ~= nil)
check("offline-time dialog allows coordinated reading",
    sync_dialog.title:find("期间可以继续阅读", 1, true) ~= nil
    and sync_dialog.title:find("新增时长会单独保留", 1, true) ~= nil)
check("offline-time dialog offers manual upload and clear actions",
    sync_dialog.buttons[1][1].text == "开始后台上报"
    and sync_dialog.buttons[2][1].text == "清除待上报时长")
sync_dialog.buttons[2][1].callback()
local clear_dialog = stack[#stack].widget
check("clearing offline time requires confirmation",
    clear_dialog.ok_text == "清除"
    and clear_dialog.text:find("阅读进度不会被清除", 1, true) ~= nil)
clear_dialog.ok_callback()
check("confirmed offline-time clear reaches the bridge", cleared == true)

instance:confirmAdvancedUpdate{
    asset_url = "http://127.0.0.1/u.tar.gz",
    source = "local",
}
local update_confirm = stack[#stack].widget
check("update confirmation uses a compatible info icon",
    update_confirm.icon == "notice-info")

instance.weread = { client = {} }
instance.path = "/plugins/wereaddesktop.koplugin"
instance:installPluginUpdate("http://127.0.0.1/u.tar.gz", "local")
check("local update asks KOReader to restart after install",
    restart_calls == 1)

local refresh_order = {}
local shelf_books = {
    { book_id = "1", cover_url = "https://cdn/1.jpg" },
    { book_id = "2", cover_url = "https://cdn/2.jpg" },
}
instance.weread = {
    isLoggedIn = function() return true end,
    getAccountVid = function() return "account-1" end,
    fetchShelf = function(_, _, callback)
        callback(shelf_books)
    end,
    saveShelf = function(_, books)
        refresh_order[#refresh_order + 1] = "save:" .. tostring(#books)
        return true
    end,
}
instance.showBusy = noop
instance.closeBusy = function()
    refresh_order[#refresh_order + 1] = "close_busy"
end
instance.refreshDesktop = function()
    refresh_order[#refresh_order + 1] = "refresh"
end
instance.maybePromptRelogin = noop
instance.queueCoverDownloads = function(_, books)
    refresh_order[#refresh_order + 1] = "queue:" .. tostring(#books)
    check("shelf refresh lock is released before background covers",
        instance.weread_refreshing == false)
end
instance:refreshWereadShelf(true)
check("shelf is saved and shown before covers are queued",
    table.concat(refresh_order, ",")
        == "save:2,close_busy,refresh,queue:2")

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
