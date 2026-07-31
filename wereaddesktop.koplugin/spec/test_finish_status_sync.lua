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
local progress_retry_calls = {}
local store
package.preload["progressuploader"] = function()
    local stub = {
        beginTimeReplay = function(settings)
            local ids = {}
            local books = settings:get("books", {})
            for book_id, book in pairs(books) do
                local elapsed = (tonumber(book.pending_upload_elapsed) or 0)
                    + (tonumber(book.pending_replay_elapsed) or 0)
                if elapsed > 0 then
                    book.pending_replay_elapsed = elapsed
                    book.pending_upload_elapsed = nil
                    ids[#ids + 1] = tostring(book_id)
                end
            end
            settings:set("books", books)
            settings:flush()
            return #ids > 0 and 1 or nil, ids
        end,
        endTimeReplay = function() return true end,
        new = function(_, opts)
            opts.retryPending = function(_, book_id, retry_options)
                progress_retry_calls[#progress_retry_calls + 1] = {
                    book_id = tostring(book_id),
                    options = retry_options,
                    time_bucket = opts.time_bucket,
                }
                if retry_options and retry_options.include_pending_time then
                    local book = store and store.books
                        and store.books[tostring(book_id)]
                    if book then
                        book.pending_replay_elapsed = nil
                        book.pending_upload_position = nil
                    end
                end
                if opts.on_finished then
                    opts.on_finished(book_id)
                end
                return true
            end
            return opts
        end,
    }
    return stub
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

store = {
    account = { user_vid = "10001" },
    books = {
        ["3300050599"] = {
            book_id = "3300050599",
            pending_upload_position = { book_id = "3300050599", percent = 42 },
            pending_upload_elapsed = 12,
        },
    },
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
local standby_acquired, standby_released = 0, 0
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
    acquireStandbyGuard = function()
        standby_acquired = standby_acquired + 1
    end,
    releaseStandbyGuard = function()
        standby_released = standby_released + 1
    end,
    getPendingUploadSummary = function()
        local elapsed, count = 0, 0
        for _, book in pairs(store.books) do
            local value = (tonumber(book.pending_upload_elapsed) or 0)
                + (tonumber(book.pending_replay_elapsed) or 0)
            if value > 0 then
                count = count + 1
                elapsed = elapsed + value
            end
        end
        return { elapsed = elapsed, count = count, time_count = count }
    end,
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

check("reader implements reconnect progress retry",
    type(instance.syncPendingReadingProgress) == "function")
if type(instance.syncPendingReadingProgress) == "function" then
    instance:onNetworkConnected()
end
check("network reconnect starts headless pending progress upload",
    #progress_retry_calls == 1
    and progress_retry_calls[1].book_id == "3300050599"
    and progress_retry_calls[1].options.progress_only == true)

check("manual offline-time upload starts",
    instance:startPendingReadingTimeUpload() == true)
check("manual offline-time upload opts in to paced time replay",
    #progress_retry_calls == 2
    and progress_retry_calls[2].options.include_pending_time == true
    and progress_retry_calls[2].time_bucket == "replay")
check("manual offline-time upload holds and releases the standby guard",
    standby_acquired == 1 and standby_released == 1)
check("successful manual offline-time upload clears the queued time",
    store.books["3300050599"].pending_upload_elapsed == nil
    and store.books["3300050599"].pending_replay_elapsed == nil)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
