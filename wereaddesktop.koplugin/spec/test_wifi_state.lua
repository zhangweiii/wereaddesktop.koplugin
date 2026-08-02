--[[--
Regression checks for desktop Wi-Fi state handling.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_wifi_state.lua
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
local ui_manager = {
    _window_stack = {},
    nextTick = function(_, fn) fn() end,
    scheduleIn = function(_, _delay, fn) fn() end,
    setDirty = noop,
    show = noop,
    close = noop,
    broadcastEvent = noop,
}
package.preload["ui/uimanager"] = function() return ui_manager end
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

local network = {
    wifi_on = true,
    connected = false,
    query_calls = 0,
    toggle_on_calls = 0,
    toggle_off_calls = 0,
    prompt_calls = 0,
}
function network:queryNetworkState()
    self.query_calls = self.query_calls + 1
end
function network:isWifiOn() return self.wifi_on end
function network:isConnected() return self.connected end
function network:getWifiState() return self.wifi_on end
function network:getConnectionState() return self.connected end
function network:toggleWifiOn(callback, _long_press, interactive)
    self.toggle_on_calls = self.toggle_on_calls + 1
    self.last_interactive = interactive
    if callback then callback() end
end
function network:toggleWifiOff(callback, interactive)
    self.toggle_off_calls = self.toggle_off_calls + 1
    self.last_interactive = interactive
    if callback then callback() end
end
function network:promptWifi(callback, _long_press, interactive)
    self.prompt_calls = self.prompt_calls + 1
    self.last_interactive = interactive
    self.dialog = {}
    table.insert(ui_manager._window_stack, #ui_manager._window_stack,
        { widget = self.dialog })
    self.callback = callback
end
package.preload["ui/network/manager"] = function() return network end

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
instance.ui = {}
instance.desktop_widget = {
    actions = {},
    setData = noop,
}
network.desktop_widget = instance.desktop_widget
ui_manager._window_stack = { { widget = instance.desktop_widget } }
instance.collectData = function()
    return { weread = true }
end
instance.showTransientInfo = noop

-- KOReader's official menu queries current state first. When the radio is
-- on but no network is connected it asks whether to connect or turn it off;
-- it must not silently turn the radio off.
instance:toggleWifi()
check("toggle queries the real network state", network.query_calls > 0)
check("radio-on but disconnected opens KOReader's Wi-Fi choice",
    network.prompt_calls == 1 and network.toggle_off_calls == 0)
check("direct Wi-Fi action is marked interactive", network.last_interactive == true)
check("Wi-Fi choice is above the desktop",
    ui_manager._window_stack[#ui_manager._window_stack].widget
        == network.dialog)

network.wifi_on = false
network.connected = false
instance:toggleWifi()
check("radio-off state turns Wi-Fi on",
    network.toggle_on_calls == 1 and network.last_interactive == true)

network.wifi_on = true
network.connected = true
instance:toggleWifi()
check("connected state turns Wi-Fi off",
    network.toggle_off_calls == 1 and network.last_interactive == true)

-- The top-right icon is part of the action list, so refreshing only data is
-- insufficient: it must be removed and inserted as connectivity changes.
local widget = {
    actions = {
        { icon = "appbar.settings" },
        { icon = "wifi" },
        { icon = "exit" },
    },
    setData = function(self, data) self.data = data end,
}
instance.desktop_widget = widget
network.connected = false
instance:refreshDesktop()
local function has_wifi_action()
    for _, action in ipairs(widget.actions) do
        if action.icon == "wifi" then return true end
    end
    return false
end
check("refresh removes Wi-Fi icon after disconnect", not has_wifi_action())

network.connected = true
instance:refreshDesktop()
check("refresh inserts Wi-Fi icon after connect", has_wifi_action())

network.connected = false
local has_disconnect_handler = type(instance.onNetworkDisconnected) == "function"
if has_disconnect_handler then instance:onNetworkDisconnected() end
check("network events refresh desktop state", has_disconnect_handler and not has_wifi_action())

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
