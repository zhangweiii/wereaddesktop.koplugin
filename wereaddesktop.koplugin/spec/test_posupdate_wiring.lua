--[[--
Event-wiring test: KOReader's rolling reader (crengine, EPUB) emits
"PosUpdate" on every page turn; only paged documents (PDF etc.) emit
"PageUpdate". WeReadDesktop must forward BOTH to the progress uploader —
the bundled statistics plugin handles onPageUpdate/onPosUpdate the same
way. Loading main.lua with stubbed KOReader UI modules, building a
reader-context instance (self.ui.document ~= nil) with a fake
progress_uploader, and dispatching events the way WidgetContainer's
handleEvent does (call self["on"..name] only when the method exists).

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_posupdate_wiring.lua
--]]--

package.path = package.path .. ";./?.lua"

-- Minimal stubs for every KOReader module main.lua pulls in.
local noop = function() end

package.preload["desktop"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, t) return t end }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function(_, _delay, fn) fn() end,
        show = noop, close = noop, broadcastEvent = noop,
    }
end
package.preload["progressuploader"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["wereadbridge"] = function()
    return {
        new = function()
            return { isLoggedIn = function() return false end }
        end,
    }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local WidgetContainer = {}
    WidgetContainer.__index = WidgetContainer
    function WidgetContainer:extend(o)
        o = o or {}
        setmetatable(o, { __index = self })
        o.__index = o
        return o
    end
    function WidgetContainer:new(o)
        o = o or {}
        setmetatable(o, self)
        return o
    end
    return WidgetContainer
end
package.preload["logger"] = function()
    return { warn = noop, info = noop, err = noop, dbg = noop }
end
package.preload["gettext"] = function()
    return function(s) return s end
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end
package.preload["apps/reader/modules/readerlink"] = function()
    return {
        showLinkBox = function(self, _link, allow_footnote_popup)
            self.last_allow_footnote_popup = allow_footnote_popup
            return true
        end,
        onGotoLink = function(self, link)
            self.last_original_link = link and link.xpointer
            return true
        end,
    }
end
package.preload["apps/reader/modules/readerstatus"] = function()
    return {
        markBook = function(self)
            local summary = self.ui.doc_settings.summary
            summary.status = summary.status == "complete"
                and "reading" or "complete"
            return summary.status
        end,
    }
end

-- Global reader settings: everything unset (progress sync defaults on).
G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = noop,
    delSetting = noop,
    flush = noop,
}

local WeReadDesktop = require("main")

local failures = 0
local function check(label, cond)
    if cond then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

-- Dispatch an event exactly like KOReader's EventListener/WidgetContainer
-- handleEvent: the handler is looked up by name and silently skipped
-- when the module does not define it.
local function dispatch(instance, event_name, ...)
    local handler = instance["on" .. event_name]
    if type(handler) == "function" then
        handler(instance, ...)
        return true
    end
    return false
end

-- Settings migration: pre-rename "kodesktop_*" reader settings are moved
-- to "wereaddesktop_*" once by init().
do
    local plain_stub = G_reader_settings
    local store = {
        kodesktop_debug_screenshot = true,
        kodesktop_progress_sync = false,
    }
    G_reader_settings = {
        readSetting = function(_, key) return store[key] end,
        saveSetting = function(_, key, value) store[key] = value end,
        delSetting = function(_, key) store[key] = nil end,
        flush = noop,
    }
    local mig = WeReadDesktop:new{}
    mig.ui = { document = { file = "/x.epub" } }
    mig:init()
    check("legacy kodesktop_* settings migrated to wereaddesktop_*",
        store.wereaddesktop_debug_screenshot == true
        and store.kodesktop_debug_screenshot == nil
        and store.wereaddesktop_progress_sync == false
        and store.kodesktop_progress_sync == nil
        and store.wereaddesktop_migrated == true)
    G_reader_settings = plain_stub
end

-- Reader-context instance: a document is open, no footer (fallback to
-- page/page-count fraction), 80 of 100 pages read.
local instance = WeReadDesktop:new{}
instance.ui = {
    doc_settings = {
        summary = {
            status = "reading",
        },
    },
    document = {
        file = "/cache/12345/book.epub",
        getCurrentPage = function() return 80 end,
        getPageCount = function() return 100 end,
    },
}
-- init() runs the reader-context branch (initProgressSync); the bridge
-- stub is not logged in, so no real uploader replaces our fake.
instance:init()

local calls = {
    ready = 0,
    page_update = 0,
    close = 0,
    suspend = 0,
    resume = 0,
    thought_link = nil,
    last_fraction = nil,
    finished = {},
}
instance.progress_uploader = {
    onReaderReady = function(_, _path)
        calls.ready = calls.ready + 1
        return "12345"
    end,
    onPageUpdate = function(_, fraction)
        calls.page_update = calls.page_update + 1
        calls.last_fraction = fraction
    end,
    onCloseDocument = function(_, _fraction) calls.close = calls.close + 1 end,
    onSuspend = function() calls.suspend = calls.suspend + 1 end,
    onResume = function() calls.resume = calls.resume + 1 end,
}
instance.openThoughtLink = function(_, url)
    calls.thought_link = url
    return true
end
instance.onLocalFinishedStatus = function(_, finished)
    calls.finished[#calls.finished + 1] = finished
end

-- Sanity: the reader-context wiring itself works.
dispatch(instance, "ReaderReady")
check("ReaderReady reaches the uploader", calls.ready == 1)
local ReaderStatus = require("apps/reader/modules/readerstatus")
local reader_status = { ui = instance.ui }
ReaderStatus.markBook(reader_status)
check("marking a WeRead book complete reaches cloud-status sync",
    calls.finished[1] == true)
ReaderStatus.markBook(reader_status)
check("marking it reading again reaches cloud-status cancellation",
    calls.finished[2] == false)
local ReaderLink = require("apps/reader/modules/readerlink")
local reader_link = { ui = instance.ui }
ReaderLink.showLinkBox(reader_link, { xpointer = "/footnote" }, false)
check("WeRead documents force native footnote popup detection",
    reader_link.last_allow_footnote_popup == true)
ReaderLink.onGotoLink(reader_link, {
    xpointer = "wrthought://12345/59/369-376",
})
check("WeRead thought links are intercepted instead of followed",
    calls.thought_link == "wrthought://12345/59/369-376"
    and reader_link.last_original_link == nil)
ReaderLink.onGotoLink(reader_link, { xpointer = "https://example.com/" })
check("unrelated links keep KOReader's original behavior",
    reader_link.last_original_link == "https://example.com/")

dispatch(instance, "PageUpdate")
check("PageUpdate reaches the uploader", calls.page_update == 1)
check("fraction comes from the open document", calls.last_fraction == 0.8)

-- The bug: EPUB page turns emit PosUpdate, which WeReadDesktop must handle
-- exactly like PageUpdate (statistics.koplugin does the same).
dispatch(instance, "PosUpdate")
check("PosUpdate reaches the uploader (EPUB page turns sync progress)",
    calls.page_update == 2)

dispatch(instance, "Suspend")
dispatch(instance, "Resume")
check("Suspend/Resume reach the uploader (sleep time is excluded)",
    calls.suspend == 1 and calls.resume == 1)

dispatch(instance, "CloseDocument")
check("CloseDocument reaches the uploader", calls.close == 1)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
