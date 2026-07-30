--[[--
Reader-context regression test for one-range lazy thought loading.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_lazy_thought_reader.lua
--]]--

package.path = package.path .. ";./?.lua"

local noop = function() end
local shown = {}

package.preload["desktop"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/textviewer"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function(_, _delay, fn) fn() end,
        show = function(_, widget) shown[#shown + 1] = widget end,
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
    return { isOnline = function() return true end }
end
package.preload["weread.lib.content"] = function()
    return {
        book_cache_dir = function(_, book_id)
            return "/cache/" .. tostring(book_id)
        end,
    }
end

local Annotations = require("weread.lib.annotations")
local cache = {}
local writes = {}
package.preload["weread.lib.thought_db"] = function()
    return {
        open = function() return {} end,
        close = noop,
        getRange = function(_, chapter_uid, range_str)
            return cache[tostring(chapter_uid) .. ":" .. range_str]
        end,
        putRange = function(_, chapter_uid, range_review, opts)
            local key = tostring(chapter_uid) .. ":" .. range_review.range
            local old = opts.append and cache[key] or nil
            local items = old and old.items or {}
            for _, item in ipairs(
                Annotations.buildThoughtPopupItems(range_review)
            ) do
                items[#items + 1] = item
            end
            cache[key] = {
                items = items,
                fetched_at = opts.fetched_at,
                max_idx = range_review.maxIdx,
                sync_key = range_review.synckey,
                total_count = range_review.totalCount,
                has_more = range_review.hasMore == true,
            }
            writes[#writes + 1] = {
                append = opts.append,
                range = range_review.range,
            }
            return true
        end,
    }
end

G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = noop,
    delSetting = noop,
    flush = noop,
}

local calls = {}
local client = {
    get_chapter_reviews_batch = function(_, book_id, chapter_uid, batch)
        calls[#calls + 1] = {
            book_id = book_id,
            chapter_uid = chapter_uid,
            batch = batch,
        }
        local offset = batch[1].maxIdx
        return true, {
            reviews = {
                {
                    range = batch[1].range,
                    pageReviews = {
                        {
                            review = {
                                author = { nick = offset == 0 and "甲" or "乙" },
                                content = offset == 0 and "第一条想法" or "第二页想法",
                                abstract = offset == 0 and "原文摘录" or nil,
                            },
                            likesCount = offset == 0 and 8 or 3,
                        },
                    },
                    maxIdx = offset == 0 and 20 or 40,
                    synckey = 123,
                    totalCount = 21,
                    hasMore = offset == 0,
                },
            },
        }
    end,
}

local WeReadDesktop = require("main")
local instance = WeReadDesktop:new{
    ui = {
        document = {
            file = "/cache/3300050599/book.epub",
        },
    },
    current_weread_book_id = "3300050599",
    reader_bridge = {
        settings = { cache_dir = "/cache" },
        client = client,
        isLoggedIn = function() return true end,
    },
}

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local url = "wrthought://3300050599/59/369-376"
instance:openThoughtLink(url)
check("cache miss fetches exactly one range",
    #calls == 1 and #calls[1].batch == 1
    and calls[1].batch[1].range == "369-376"
    and calls[1].batch[1].count == 20)
check("first page is cached and rendered",
    #writes == 1 and writes[1].append == false
    and shown[#shown].title == "书友想法"
    and shown[#shown].text:find("第一条想法", 1, true) ~= nil)

instance:openThoughtLink(url)
check("second tap is served from cache", #calls == 1)

instance:fetchThoughtRange({
    book_id = "3300050599",
    chapter_uid = 59,
    range = "369-376",
}, {
    append = true,
    max_idx = 20,
    sync_key = 123,
})
check("load more requests the next page only",
    #calls == 2 and calls[2].batch[1].maxIdx == 20
    and calls[2].batch[1].synckey == 123)
check("load more appends instead of replacing",
    #writes == 2 and writes[2].append == true
    and shown[#shown].text:find("第一条想法", 1, true) ~= nil
    and shown[#shown].text:find("第二页想法", 1, true) ~= nil)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
