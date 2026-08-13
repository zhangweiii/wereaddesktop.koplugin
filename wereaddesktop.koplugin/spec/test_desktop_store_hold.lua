-- Regression harness: store books expose the same long-press download action
-- as shelf books, including recommendation rows and search results.

package.path = package.path .. ";./?.lua"

local function class(defaults)
    local object = defaults or {}
    object.__index = object
    function object:extend(values)
        values = values or {}
        setmetatable(values, { __index = self })
        values.__index = values
        return values
    end
    function object:new(values)
        values = values or {}
        setmetatable(values, self)
        if values.init then values:init() end
        return values
    end
    function object:getSize()
        return { w = self.width or (self.dimen and self.dimen.w) or 20,
            h = self.height or (self.dimen and self.dimen.h) or 20 }
    end
    function object:free() end
    return object
end

local Generic = class()
for _, name in ipairs({
    "ui/widget/button",
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/iconbutton",
    "ui/widget/iconwidget",
    "ui/widget/imagewidget",
    "ui/widget/container/leftcontainer",
    "ui/widget/linewidget",
    "ui/widget/overlapgroup",
    "ui/widget/container/rightcontainer",
    "ui/widget/textwidget",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
}) do
    package.preload[name] = function() return Generic end
end
package.preload["ui/widget/container/inputcontainer"] = function()
    return class{ ges_events = {} }
end
package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_BLACK = 0, COLOR_WHITE = 1, COLOR_GRAY_5 = 5,
        COLOR_GRAY_9 = 9, COLOR_GRAY_C = 12, COLOR_GRAY_E = 14,
    }
end
package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_, value) return value end,
            getSize = function() return { w = 600, h = 800 } end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getRotationMode = function() return 0 end,
        },
        isTouchDevice = function() return false end,
        hasKeys = function() return false end,
    }
end
package.preload["ui/font"] = function()
    return { getFace = function() return {} end }
end
package.preload["ui/geometry"] = function() return Generic end
package.preload["ui/gesturerange"] = function() return Generic end
package.preload["ui/size"] = function() return { line = { thin = 1 } } end
package.preload["ui/uimanager"] = function()
    return { _window_stack = {}, setDirty = function() end }
end
package.preload["gettext"] = function() return function(value) return value end end

local BookshelfWidget = require("desktop")
local held = {}

local function store_cells(widget)
    local found = {}
    local seen = {}
    local function visit(value)
        if type(value) ~= "table" or seen[value] then return end
        seen[value] = true
        if type(value.book) == "table" and value.book.text then
            found[#found + 1] = value
        end
        for _, child in pairs(value) do visit(child) end
    end
    visit(widget)
    return found
end

local function build(data)
    return BookshelfWidget:new{
        data = data,
        actions = {},
        on_book_hold = function(book)
            held[#held + 1] = book.book_id
        end,
    }
end

local feed = build{
    weread = true,
    tab = "store",
    store_feed = {
        { title = "推荐", books = { { book_id = "feed", text = "推荐书" } } },
    },
}
local feed_cell = store_cells(feed)[1]
local search = build{
    weread = true,
    tab = "store",
    store_search = {
        keyword = "测试",
        books = { { book_id = "search", text = "搜索书" } },
    },
}
local search_cell = store_cells(search)[1]

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

check("store recommendation books expose long-press",
    feed_cell and type(feed_cell.hold_callback) == "function")
check("store search books expose long-press",
    search_cell and type(search_cell.hold_callback) == "function")
feed_cell.hold_callback()
search_cell.hold_callback()
check("store long-press forwards the original book",
    held[1] == "feed" and held[2] == "search")

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
