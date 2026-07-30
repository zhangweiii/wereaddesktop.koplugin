--[[--
WeRead finished-status client regression test.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_finish_status_client.lua
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
        reader_url = function(book_id)
            return "https://weread.qq.com/web/reader/" .. tostring(book_id)
        end,
    }
end
package.preload["json"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end

local Client = require("weread.lib.client")
local client = Client:new{
    get = function() return "" end,
}

local calls = {}
client.gateway = function()
    error("HTTP 499: gateway does not expose /book/markStatus")
end
client.post_json = function(_, url, params, opts)
    calls[#calls + 1] = {
        url = url,
        params = params,
        opts = opts,
    }
    return {}
end

local finish_ok = client:mark_book_finished("3300050599", true)
local cancel_ok = client:mark_book_finished("3300050599", false)

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

check("marking finished uses the official web markStatus route",
    finish_ok == true
    and calls[1]
    and calls[1].url == "https://weread.qq.com/web/book/markStatus"
    and calls[1].params.bookId == "3300050599"
    and calls[1].params.status == 4
    and calls[1].params.isCancel == 0
    and calls[1].params.finishInfo == 1
    and calls[1].opts.diagnostic_api == "mark_book_finished")
check("marking reading again cancels the cloud finished state",
    cancel_ok == true
    and calls[2]
    and calls[2].url == "https://weread.qq.com/web/book/markStatus"
    and calls[2].params.bookId == "3300050599"
    and calls[2].params.status == 4
    and calls[2].params.isCancel == 1
    and calls[2].params.finishInfo == 0)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
