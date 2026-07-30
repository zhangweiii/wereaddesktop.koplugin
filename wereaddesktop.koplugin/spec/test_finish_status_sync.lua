--[[--
Reader-context regression test for reliable finished-status sync.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_finish_status_sync.lua
--]]--

package.path = package.path .. ";./?.lua"

local noop = function() end
package.preload["desktop"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function(_, _delay, fn) fn() end,
        show = noop,
        close = noop,
        broadcastEvent = noop,
    }
end
package.preload["progressuploader"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["wereadbridge"] = function()
    return { new = function() return {} end }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local WidgetContainer = {}
    WidgetContainer.__index = WidgetContainer
    function WidgetContainer:extend(value)
        value = value or {}
        setmetatable(value, { __index = self })
        value.__index = value
        return value
    end
    function WidgetContainer:new(value)
        value = value or {}
        setmetatable(value, self)
        return value
    end
    return WidgetContainer
end
package.preload["logger"] = function()
    return { warn = noop, info = noop, err = noop, dbg = noop }
end
package.preload["gettext"] = function()
    return function(value) return value end
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

local store = {
    account = { user_vid = "10001" },
}
local settings = {
    get = function(_, key, default)
        local value = store[key]
        if value == nil then return default end
        return value
    end,
    set = function(_, key, value) store[key] = value end,
    refresh = noop,
    flush = noop,
}
local calls = {}
local cached_finished
local bridge = {
    settings = settings,
    client = {
        mark_book_finished = function(_, book_id, finished)
            calls[#calls + 1] = {
                book_id = book_id,
                finished = finished,
            }
            return true, {}
        end,
    },
    isLoggedIn = function() return true end,
    updateShelfFinished = function(_, _book_id, finished)
        cached_finished = finished
    end,
}

local WeReadDesktop = require("main")
local online = true
local instance = WeReadDesktop:new{
    ui = {
        document = {
            file = "/cache/3300050599/book.epub",
        },
    },
    reader_bridge = bridge,
    current_weread_book_id = "3300050599",
}
instance.isNetworkConnected = function() return online end

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

check("reader implements finished-status sync",
    type(instance.onLocalFinishedStatus) == "function"
    and type(instance.syncPendingFinishedStatus) == "function")

if type(instance.onLocalFinishedStatus) == "function" then
    instance:onLocalFinishedStatus(true)
end
check("online finished state reaches WeRead and updates shelf cache",
    #calls == 1
    and calls[1].book_id == "3300050599"
    and calls[1].finished == true
    and cached_finished == true)
check("successful sync removes the durable pending item",
    type(store.pending_finish_sync) == "table"
    and store.pending_finish_sync["3300050599"] == nil)

online = false
if type(instance.onLocalFinishedStatus) == "function" then
    instance:onLocalFinishedStatus(false)
end
check("offline cancellation is queued without a network request",
    #calls == 1
    and store.pending_finish_sync
    and store.pending_finish_sync["3300050599"]
    and store.pending_finish_sync["3300050599"].finished == false)

online = true
if type(instance.syncPendingFinishedStatus) == "function" then
    instance:syncPendingFinishedStatus("3300050599")
end
check("queued cancellation retries after reconnection",
    #calls == 2
    and calls[2].finished == false
    and cached_finished == false
    and store.pending_finish_sync["3300050599"] == nil)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
