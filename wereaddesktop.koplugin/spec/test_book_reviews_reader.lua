--[[--
Reader-context regression test for lazy whole-book reviews.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_book_reviews_reader.lua
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

local cache
local writes = {}
package.preload["weread.lib.thought_db"] = function()
    return {
        open = function() return {} end,
        close = noop,
        getRange = function() return nil end,
        putRange = function() return true end,
        getBookReviews = function() return cache end,
        putBookReviews = function(_, page, opts)
            local items = opts.append and cache and cache.items or {}
            for _, item in ipairs(page.items or {}) do
                items[#items + 1] = item
            end
            cache = {
                items = items,
                fetched_at = opts.fetched_at,
                max_idx = page.max_idx,
                sync_key = page.sync_key,
                total_count = page.total_count,
                has_more = page.has_more,
            }
            writes[#writes + 1] = opts.append == true
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
    get_book_reviews = function(_, book_id, opts)
        calls[#calls + 1] = { book_id = book_id, opts = opts }
        local next_page = opts.max_idx > 0
        return true, {
            synckey = 456,
            reviewsCnt = 21,
            reviewsHasMore = next_page and 0 or 1,
            reviews = {
                {
                    idx = next_page and 40 or 20,
                    review = {
                        likesCount = next_page and 3 or 8,
                        review = {
                            reviewId = next_page and "r2" or "r1",
                            author = { name = next_page and "乙" or "甲" },
                            content = next_page and "第二页点评" or "第一页点评",
                            newRatingLevel = 1,
                        },
                    },
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

instance:openBookReviews()
check("cache miss fetches one page of whole-book reviews",
    #calls == 1 and calls[1].book_id == "3300050599"
    and calls[1].opts.count == 20 and calls[1].opts.max_idx == 0)
check("first page is cached and rendered",
    #writes == 1 and writes[1] == false
    and shown[#shown].title == "书友点评"
    and shown[#shown].text:find("第一页点评", 1, true) ~= nil)

instance:openBookReviews()
check("second open is served from cache", #calls == 1)

instance:fetchBookReviews("3300050599", {
    append = true,
    max_idx = 20,
    sync_key = 456,
})
check("load more uses the review cursor",
    #calls == 2 and calls[2].opts.max_idx == 20
    and calls[2].opts.sync_key == 456)
check("load more appends instead of replacing",
    #writes == 2 and writes[2] == true
    and shown[#shown].text:find("第一页点评", 1, true) ~= nil
    and shown[#shown].text:find("第二页点评", 1, true) ~= nil)

local menu = {}
instance:addToMainMenu(menu)
check("reader menu exposes a separate whole-book review entry",
    menu.wereadbookreviews
    and menu.wereadbookreviews.text == "书友点评")

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
