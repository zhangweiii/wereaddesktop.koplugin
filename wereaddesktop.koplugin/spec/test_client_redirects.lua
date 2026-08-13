--[[--
Client redirect regression test: credentials and per-origin headers
(Authorization, Cookie, Origin, Referer — matched case-insensitively)
must be stripped when request_follow crosses origins, and kept on
same-origin redirects.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_client_redirects.lua
--]]--

package.path = package.path .. ";./?.lua"

local noop = function() end
local recorded = {}
local timeout_calls = {}
local response_headers = {}

package.preload["ltn12"] = function()
    return { source = { string = function() end } }
end
package.preload["weread.lib.logger"] = function()
    return { info = noop, warn = noop, err = noop }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_, block_timeout, total_timeout)
            timeout_calls[#timeout_calls + 1] = {
                block = block_timeout,
                total = total_timeout,
            }
        end,
        reset_timeout = noop,
        table_sink = function() return noop end,
    }
end
package.preload["socket.http"] = function()
    return {
        request = function(req_opts)
            recorded[#recorded + 1] = {
                url = req_opts.url,
                headers = req_opts.headers,
            }
            if req_opts.url:find("limited", 1, true) then
                for _, chunk in ipairs({ "1234", "5678" }) do
                    if not req_opts.sink(chunk) then
                        return nil, "sink stopped", {}, "sink stopped"
                    end
                end
                req_opts.sink(nil)
                return 1, 200, {}, "200 OK"
            end
            local redirect = req_opts.url:find("redirect", 1, true) ~= nil
            if redirect then
                return nil, 302, { Location = recorded.redirect_target },
                    "302 Found"
            end
            return nil, 200, response_headers, "200 OK"
        end,
    }
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
    }
end
package.preload["json"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end

local Client = require("weread.lib.client")

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local function header_names(headers)
    local names = {}
    for key in pairs(headers or {}) do
        names[#names + 1] = tostring(key):lower()
    end
    return names
end

local function has_credential_headers(headers)
    local names = header_names(headers)
    for _, banned in ipairs({
        "authorization", "cookie", "origin", "referer",
    }) do
        for _, name in ipairs(names) do
            if name == banned then
                return true
            end
        end
    end
    return false
end

local client = Client:new{
    get = function() return "" end,
    merge_set_cookie = function(_, _set_cookie, options)
        recorded.cookie_flush = options.flush
    end,
}

----------------------------------------------------------------
-- Every request has a finite wall-clock limit. A per-block timeout alone
-- can run forever on a weak connection that keeps trickling bytes.
----------------------------------------------------------------
client:request{
    url = "https://weread.qq.com/web/test-timeout",
    method = "GET",
}
check("default HTTP request has a finite total timeout",
    timeout_calls[#timeout_calls]
        and timeout_calls[#timeout_calls].block > 0
        and timeout_calls[#timeout_calls].total > 0)

response_headers = { ["Set-Cookie"] = "wr_skey=child" }
client.persist_response_cookies = false
client:request{
    url = "https://weread.qq.com/web/test-child-cookie",
    method = "GET",
}
check("forked clients merge response cookies without flushing settings",
    recorded.cookie_flush == false)
client.persist_response_cookies = nil
response_headers = {}

----------------------------------------------------------------
-- Cross-origin redirect strips credentials in any header casing.
----------------------------------------------------------------
recorded.redirect_target = "https://cdn.example.com/asset.png"
recorded = { redirect_target = recorded.redirect_target }
client:request_follow{
    url = "https://weread.qq.com/redirect",
    method = "GET",
    headers = {
        ["Authorization"] = "Bearer secret",
        ["Cookie"] = "wr_skey=abc",
        ["Origin"] = "https://weread.qq.com",
        ["Referer"] = "https://weread.qq.com/web/reader/secretbook",
        ["X-Extra"] = "kept",
    },
}

check("cross-origin redirect sends exactly two requests",
    #recorded == 2)
check("first (same-origin) request keeps credentials",
    has_credential_headers(recorded[1].headers) == true)
check("cross-origin request strips Authorization/Cookie/Origin/Referer",
    has_credential_headers(recorded[2].headers) == false)
check("cross-origin request keeps unrelated headers",
    recorded[2].headers and recorded[2].headers["X-Extra"] == "kept")

----------------------------------------------------------------
-- Same-origin redirect keeps the headers (including Referer).
----------------------------------------------------------------
recorded.redirect_target = "https://weread.qq.com/web/reader/next"
recorded = { redirect_target = recorded.redirect_target }
client:request_follow{
    url = "https://weread.qq.com/redirect",
    method = "GET",
    headers = {
        ["Referer"] = "https://weread.qq.com/web/reader/book1",
        ["Cookie"] = "wr_skey=abc",
    },
}

check("same-origin redirect keeps credentials",
    #recorded == 2
        and has_credential_headers(recorded[2].headers) == true
        and recorded[2].headers["Referer"]
            == "https://weread.qq.com/web/reader/book1")

----------------------------------------------------------------
-- Limited binary downloads stop at the sink instead of buffering an
-- arbitrarily large response.
----------------------------------------------------------------
local limited = client:get_binary_limited(
    "https://cdn.example.com/limited", 8)
check("limited binary download returns content within the cap",
    limited == "12345678")
local oversized, _code, _headers, limit_err = client:get_binary_limited(
    "https://cdn.example.com/limited", 7)
check("limited binary download aborts content above the cap",
    oversized == nil and limit_err == "max_bytes_exceeded")

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
