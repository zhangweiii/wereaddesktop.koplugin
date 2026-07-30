--[[--
Whole-book review client regression test.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_book_reviews_client.lua
--]]--

package.path = package.path .. ";./?.lua"

local noop = function() end
package.preload["ltn12"] = function()
    return { source = { string = function() end } }
end
package.preload["weread.lib.logger"] = function()
    return { info = noop, warn = noop, err = noop }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = noop,
        reset_timeout = noop,
        table_sink = function() return noop end,
    }
end
package.preload["socket.http"] = function()
    return { request = noop }
end
package.preload["weread.lib.cookie"] = function()
    return {
        to_header = function() return "" end,
        merge_set_cookie = function(value) return value end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return {
        USER_AGENT = "test",
        SKILL_VERSION = "test",
        urlencode = tostring,
    }
end
package.preload["json"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end

local Client = require("weread.lib.client")
local client = Client:new{
    get = function() return "" end,
}

local captured
client.gateway = function(_, api_name, params)
    captured = { api_name = api_name, params = params }
    return {
        synckey = 456,
        reviewsCnt = 120,
        reviewsHasMore = 1,
        reviews = {
            {
                idx = 21,
                review = {
                    likesCount = 8,
                    review = {
                        reviewId = "review-1",
                        author = { name = "甲" },
                        content = "整本书点评",
                        newRatingLevel = 1,
                    },
                },
            },
        },
    }
end

local ok, result = client:get_book_reviews("3300050599", {
    max_idx = 20,
    sync_key = 123,
})

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

check("uses the verified best-review gateway route",
    ok and captured and captured.api_name == "/review/list/best")
check("passes one-page cursor parameters",
    captured
    and captured.params.bookId == "3300050599"
    and captured.params.count == 20
    and captured.params.maxIdx == 20
    and captured.params.synckey == 123)
check("returns the review page unchanged",
    result and result.reviews and result.reviews[1].idx == 21)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
