--[[--
Full-screen WeRead home widget: the cloud bookshelf grid (paged), a
store tab (search + recommendation feed) and a settings tab sharing a
bottom tab bar, like the home screen of a dedicated e-reader device.
Not logged in: a QR login prompt is shown instead.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Screen = Device.screen

-- Text height probe for a given face (freed immediately).
local function textHeight(face, sample)
    local probe = TextWidget:new{ text = sample or "Ag中", face = face }
    local h = probe:getSize().h
    probe:free()
    return h
end

-- Bordered placeholder cover with the book title, used whenever no real
-- cover is available.
local function buildPlaceholderCover(text, max_w, max_h)
    local padding = Screen:scaleBySize(6)
    return FrameContainer:new{
        width = max_w,
        height = max_h,
        margin = 0,
        padding = padding,
        bordersize = Size.line.thin,
        color = Blitbuffer.COLOR_GRAY_9,
        background = Blitbuffer.COLOR_GRAY_E,
        CenterContainer:new{
            dimen = Geom:new{ w = max_w - 2 * padding, h = max_h - 2 * padding },
            TextWidget:new{
                text = text,
                face = Font:getFace("xx_smallinfofont"),
                max_width = max_w - 2 * padding,
                fgcolor = Blitbuffer.COLOR_GRAY_5,
            },
        },
    }
end

--[[--
Cover from a downloaded image file (WeRead shelf), stretched to fill the
box exactly (mild distortion for odd aspect ratios beats side gaps);
falls back to the placeholder on any failure (missing/corrupt file,
unsupported format).
--]]--
local function buildWereadCover(book, max_w, max_h)
    if book.cover_path then
        local ok, image = pcall(function()
            local img = ImageWidget:new{
                file = book.cover_path,
                width = max_w,
                height = max_h,
                alpha = true,
            }
            img:_render()
            return img
        end)
        if ok and image then
            return image
        end
    end
    return buildPlaceholderCover(book.text, max_w, max_h)
end

-- Square badge for finished books: a small white square with a thin
-- gray border and gray「已读」text, sized to hug the two characters,
-- pinned to the top-right corner of the cover.
local function buildFinishedBadge()
    return FrameContainer:new{
        margin = 0,
        padding_h = Screen:scaleBySize(3),
        padding_v = 0, -- text fills the block vertically; height hugs the text
        bordersize = Size.line.thin,
        color = Blitbuffer.COLOR_GRAY_9,
        background = Blitbuffer.COLOR_WHITE,
        TextWidget:new{
            text = _("已读"),
            face = Font:getFace("cfont", Screen:scaleBySize(7)),
            fgcolor = Blitbuffer.COLOR_GRAY_5,
        },
    }
end

--[[--
WeRead cover with a status marker overlaid on the cover box: finished
books get a checkmark badge in the top-right corner; other books show
nothing. Works on top of real and placeholder covers alike.
--]]--
local function buildWereadCoverBadged(book, max_w, max_h)
    local cover = buildWereadCover(book, max_w, max_h)
    if not book.finished then
        return cover -- no marker: clean cover
    end
    local group = OverlapGroup:new{
        allow_mirroring = false, -- keep the offsets below literal
        dimen = Geom:new{ w = max_w, h = max_h },
        cover,
    }
    local badge = buildFinishedBadge()
    local bs = badge:getSize()
    badge.overlap_offset = { max_w - bs.w, 0 }
    table.insert(group, badge)
    return group
end

--[[--
A WeRead shelf cell: badged cover plus a one-line title. There is no
footer row; reading state lives on the cover.
--]]--
local WereadBookCell = InputContainer:extend{
    book = nil, -- { text=, cover_path=, finished=bool|nil }
    dimen = nil,
    cover_h = nil,
    callback = nil,
    hold_callback = nil, -- long-press (download options); shelf only
}

function WereadBookCell:init()
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            }
        },
    }
    if self.hold_callback then
        self.ges_events.Hold = {
            GestureRange:new{
                ges = "hold",
                range = self.dimen,
            }
        }
    end
    local cell_w = self.dimen.w
    self[1] = VerticalGroup:new{
        align = "center",
        buildWereadCoverBadged(self.book, cell_w, self.cover_h),
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        TextWidget:new{
            text = self.book.text,
            face = Font:getFace("xx_smallinfofont"),
            max_width = cell_w,
        },
    }
end

function WereadBookCell:onTap()
    if self.callback then
        self.callback(self.book)
    end
    return true
end

function WereadBookCell:onHold()
    if self.hold_callback then
        self.hold_callback(self.book)
    end
    return true
end

--[[--
A section row with horizontal swipe paging. Children (book cells) get
taps first; swipes fall through to this container.
--]]--
local SectionRow = InputContainer:extend{
    dimen = nil,
    row = nil, -- HorizontalGroup of cells
    on_swipe = nil, -- function(delta): +1 next page, -1 previous page
}

function SectionRow:init()
    self.ges_events.Swipe = {
        GestureRange:new{
            ges = "swipe",
            range = self.dimen,
        }
    }
    self[1] = self.row
end

function SectionRow:onSwipe(arg, ges)
    if ges.direction == "west" then -- swipe left: next page
        self.on_swipe(1)
    elseif ges.direction == "east" then -- swipe right: previous page
        self.on_swipe(-1)
    end
    return true
end

--[[--
The WeRead shelf grid with swipe paging. Children (book cells) get taps
first; swipes fall through to this container. Vertical swipes are the
primary paging gesture (like the WeRead app), horizontal ones also work.
--]]--
local GridPage = InputContainer:extend{
    dimen = nil,
    grid = nil, -- VerticalGroup of cell rows
    on_swipe = nil, -- function(delta): +1 next page, -1 previous page
}

function GridPage:init()
    self.ges_events.Swipe = {
        GestureRange:new{
            ges = "swipe",
            range = self.dimen,
        }
    }
    self[1] = self.grid
end

function GridPage:onSwipe(arg, ges)
    if ges.direction == "north" or ges.direction == "west" then
        self.on_swipe(1) -- swipe up/left: next page
    elseif ges.direction == "south" or ges.direction == "east" then
        self.on_swipe(-1) -- swipe down/right: previous page
    end
    return true
end

--[[--
Small tappable text entry (e.g. "返回书城" on the search results page).
--]]--
local HiddenEntry = InputContainer:extend{
    dimen = nil,
    text = nil,
    callback = nil,
}

function HiddenEntry:init()
    self.ges_events.Tap = {
        GestureRange:new{
            ges = "tap",
            range = self.dimen,
        }
    }
    self[1] = TextWidget:new{
        text = self.text,
        face = Font:getFace("xx_smallinfofont"),
        fgcolor = Blitbuffer.COLOR_GRAY_9,
    }
end

function HiddenEntry:onTap()
    if self.callback then
        self.callback()
    end
    return true
end

-- Bottom tab bar entries, shared by the three WeRead pages.
local TAB_DEFS = {
    { id = "shelf", icon = "home", text = _("书架") },
    { id = "store", icon = "appbar.search", text = _("书城") },
    { id = "settings", icon = "appbar.settings", text = _("设置") },
}

--[[--
One bottom-tab cell: a 2px indicator strip on top (black on the active
tab), icon + label below. Tapping switches pages without closing the
desktop.
--]]--
local TabCell = InputContainer:extend{
    dimen = nil,
    def = nil,
    active = false,
    on_switch = nil, -- function(tab_id)
}

function TabCell:init()
    self.ges_events.Tap = {
        GestureRange:new{
            ges = "tap",
            range = self.dimen,
        }
    }
    local cell_w = self.dimen.w
    local cell_h = self.dimen.h
    local indicator_h = Screen:scaleBySize(2)
    local indicator
    if self.active then
        indicator = LineWidget:new{
            dimen = Geom:new{ w = cell_w, h = indicator_h },
            background = Blitbuffer.COLOR_BLACK,
        }
    else
        indicator = VerticalSpan:new{ width = indicator_h }
    end
    local icon_size = Screen:scaleBySize(24)
    self[1] = VerticalGroup:new{
        align = "center",
        indicator,
        CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h - indicator_h },
            VerticalGroup:new{
                align = "center",
                IconWidget:new{
                    icon = self.def.icon,
                    width = icon_size,
                    height = icon_size,
                    alpha = true,
                },
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{
                    text = self.def.text,
                    face = Font:getFace("xx_smallinfofont"),
                    fgcolor = self.active
                        and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_9,
                },
            },
        },
    }
end

function TabCell:onTap()
    if self.on_switch then
        self.on_switch(self.def.id)
    end
    return true
end

--[[--
The store tab's search entry: a bordered box with a magnifier icon and
a hint, opening the keyword dialog on tap.
--]]--
local SearchEntry = InputContainer:extend{
    dimen = nil,
    callback = nil,
    text = nil,
}

function SearchEntry:init()
    self.ges_events.Tap = {
        GestureRange:new{
            ges = "tap",
            range = self.dimen,
        }
    }
    local icon_size = Screen:scaleBySize(24)
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        margin = 0,
        padding = 0,
        padding_left = Screen:scaleBySize(10),
        bordersize = Size.line.thin,
        color = Blitbuffer.COLOR_GRAY_D,
        background = Blitbuffer.COLOR_GRAY_E,
        HorizontalGroup:new{
            align = "center",
            IconWidget:new{
                icon = "appbar.search",
                width = icon_size,
                height = icon_size,
                alpha = true,
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(8) },
            TextWidget:new{
                text = self.text or _("搜索书名"),
                face = Font:getFace("smallinfofont"),
                fgcolor = Blitbuffer.COLOR_GRAY_9,
            },
        },
    }
end

function SearchEntry:onTap()
    if self.callback then
        self.callback()
    end
    return true
end

--[[--
A full-width tappable settings row: label on the left, optional gray
value on the right (e.g. 开/关).
--]]--
local SettingsRow = InputContainer:extend{
    dimen = nil,
    label = nil,
    value = nil,
    callback = nil,
}

function SettingsRow:init()
    self.ges_events.Tap = {
        GestureRange:new{
            ges = "tap",
            range = self.dimen,
        }
    }
    local row_w = self.dimen.w
    local row_h = self.dimen.h
    local value_w = 0
    local value_widget
    if self.value then
        value_widget = TextWidget:new{
            text = self.value,
            face = Font:getFace("xx_smallinfofont"),
            fgcolor = Blitbuffer.COLOR_GRAY_5,
        }
        value_w = value_widget:getSize().w + Screen:scaleBySize(10)
    elseif self.chevron ~= false then
        -- Navigation row: trailing chevron, iOS-settings style.
        value_widget = TextWidget:new{
            text = ">",
            face = Font:getFace("smallinfofont"),
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        }
        value_w = value_widget:getSize().w + Screen:scaleBySize(10)
    end
    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = row_w - value_w, h = row_h },
            TextWidget:new{
                text = self.label,
                face = Font:getFace("smallinfofont"),
            },
        },
    }
    if value_widget then
        table.insert(row, RightContainer:new{
            dimen = Geom:new{ w = value_w, h = row_h },
            value_widget,
        })
    end
    self[1] = row
end

function SettingsRow:onTap()
    if self.callback then
        self.callback()
    end
    return true
end

--[[--
The bookshelf page itself.
data = {
  weread       = true,          -- logged-in WeRead mode (tabbed pages)
  tab          = "shelf"|"store"|"settings"|nil (widget-side state),
  account_name = string|nil,
  account_vid  = string|nil,
  books        = { book, ... }, -- shelf books (empty until first fetch)
  store_feed / store_error / store_search = store tab state,
  sync_progress = bool,
  autosuspend_label = string, -- 定时熄屏 (autosuspend) timeout display
  device_status = string|nil, -- battery · storage line
  has_frontlight = bool, night_mode = bool, wifi_on = bool,
  rotation_label/screensaver_label/clock_label = string,
  shelf_query = string|nil, shelf_sort_label = string,
  storage_label = string|nil,
  sync_status_label = string|nil,
  plugin_version = string,
}
or { login_prompt = true } when not logged in.
actions = { { icon=, callback= }, ... }  -- top-right toolbar icons
--]]--
local BookshelfWidget = InputContainer:extend{
    modal = true,
    name = "wereaddesktop",
    covers_fullscreen = true, -- hint for UIManager:_repaint()
    data = nil,
    actions = nil,
    settings_sub_page = nil, -- nil | "device" — sub-page state
    on_open_book = nil,
    on_book_hold = nil, -- long-press on a shelf book: download options
    on_login = nil, -- function(), starts the WeRead QR login
    -- WeRead store / settings tab callbacks (all function() unless noted).
    on_store_feed = nil, -- fetches the store home feed (first visit)
    on_store_search = nil, -- function(keyword|nil): nil prompts for input
    on_store_search_back = nil, -- clears search results, back to the feed
    on_shelf_search = nil, -- function(keyword|nil): local shelf filter
    on_toggle_sync = nil, -- toggles the progress-sync setting
    on_toggle_autostart = nil, -- toggles the show-desktop-on-start setting
    on_set_autosuspend = nil, -- cycles the autosuspend (定时熄屏) timeout
    on_cycle_shelf_sort = nil,
    on_storage = nil,
    on_sync_status = nil,
    on_read_stats = nil,
    on_device_settings = nil, -- opens the device settings sub-page
    on_refresh_shelf = nil,
    on_relogin = nil,
    on_logout = nil,
    on_about = nil,
    on_close = nil,
}

function BookshelfWidget:init()
    self.dimen = Screen:getSize()
    if Device:isTouchDevice() then
        -- Cells and toolbar buttons consume taps on their own area
        -- first, so this handler only fires for taps on empty space.
        self.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            }
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.weread_page = 1 -- current page (1-based) of the WeRead grid
    self:buildUI()
end

-- Replace the displayed data and rebuild in place.
function BookshelfWidget:setData(data)
    -- The active tab is widget-side state; collectData does not set it.
    data.tab = data.tab or (self.data and self.data.tab)
    self.data = data
    if self[1] then
        self[1]:free() -- release cover blitbuffers
    end
    self:buildUI()
    -- A dialog above the desktop (download confirm, search input,
    -- download progress...) would be painted over by a fullscreen
    -- desktop repaint; the dialog's own close repaints the desktop.
    local stack = UIManager._window_stack or {}
    for i, window in ipairs(stack) do
        if window.widget == self then
            if i < #stack then
                return
            end
            break
        end
    end
    UIManager:setDirty(self, "full")
end

-- Fixed height of the bottom tab bar (separator + bar).
function BookshelfWidget:tabBarHeight()
    return Size.line.thin + Screen:scaleBySize(56)
end

-- Bottom tab bar shared by the WeRead pages: separator on top, three
-- equal cells (书架/书城/设置).
function BookshelfWidget:buildTabBar(content_w)
    local bar_h = Screen:scaleBySize(56)
    local cell_w = math.floor(content_w / #TAB_DEFS)
    local cells = HorizontalGroup:new{ align = "center" }
    for i, def in ipairs(TAB_DEFS) do
        local w = i < #TAB_DEFS and cell_w
            or (content_w - (#TAB_DEFS - 1) * cell_w)
        table.insert(cells, TabCell:new{
            dimen = Geom:new{ w = w, h = bar_h },
            def = def,
            active = (self.data.tab or "shelf") == def.id,
            on_switch = function(tab_id)
                self:switchTab(tab_id)
            end,
        })
    end
    return VerticalGroup:new{
        align = "left",
        self:separator(content_w),
        cells,
    }
end

-- Switch the active WeRead tab in place (no close/reopen).
function BookshelfWidget:switchTab(tab)
    if (self.data.tab or "shelf") == tab then
        return
    end
    self.data.tab = tab
    -- Any sub-page (device settings etc.) is scoped to its own tab;
    -- switching away resets it.
    self.settings_sub_page = nil
    -- First visit to the store: kick off the feed fetch; the page
    -- rebuilds via refreshDesktop → setData when the data lands.
    if tab == "store" and not self.data.store_feed
        and not self.data.store_error and not self.data.store_search
        and self.on_store_feed then
        self.on_store_feed()
    end
    if self[1] then
        self[1]:free()
    end
    self:buildUI()
    UIManager:setDirty(self, "full")
end

-- Shared page tail for the tabbed WeRead pages: push the content up,
-- pin the tab bar to the bottom, wrap in the white full-screen frame.
function BookshelfWidget:wrapWereadPage(page, used_h)
    local screen_w = self.dimen.w
    local screen_h = self.dimen.h
    local content_w = screen_w - 2 * Screen:scaleBySize(28)
    local tabbar = self:buildTabBar(content_w)
    local leftover = screen_h - used_h - tabbar:getSize().h
    if leftover > 0 then
        table.insert(page, VerticalSpan:new{ width = leftover })
    end
    table.insert(page, tabbar)
    self[1] = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            page,
        },
    }
end

-- Rebuild the layout when the screen rotates or the emulator window
-- is resized.
function BookshelfWidget:onSetDimensions(new_dimen)
    self.dimen = new_dimen
    if self.ges_events.Tap then
        self.ges_events.Tap[1].range = new_dimen
    end
    if self[1] then
        self[1]:free() -- release cover blitbuffers
    end
    self:buildUI()
    UIManager:setDirty(self, "full")
    return true
end

function BookshelfWidget:buildTopBar(content_w)
    local bar_h = Screen:scaleBySize(44)
    local icon_size = Screen:scaleBySize(36)
    local icons = HorizontalGroup:new{ align = "center" }
    for i, action in ipairs(self.actions) do
        if i > 1 then
            table.insert(icons, HorizontalSpan:new{ width = Screen:scaleBySize(28) })
        end
        table.insert(icons, IconButton:new{
            icon = action.icon,
            width = icon_size,
            height = icon_size,
            allow_flash = false, -- callbacks close this widget
            show_parent = self,
            callback = action.callback,
        })
    end
    return HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = math.floor(content_w * 0.6), h = bar_h },
            HorizontalGroup:new{
                align = "center",
                TextWidget:new{
                    text = os.date("%H:%M"),
                    face = Font:getFace("smalltfont"),
                },
                HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                TextWidget:new{
                    text = (function()
                        local t = os.date("*t")
                        local weekdays = {
                            _("周日"), _("周一"), _("周二"), _("周三"),
                            _("周四"), _("周五"), _("周六"),
                        }
                        return string.format(_("%d月%d日 %s"), t.month, t.day, weekdays[t.wday])
                    end)(),
                    face = Font:getFace("xx_smallinfofont"),
                    fgcolor = Blitbuffer.COLOR_GRAY_5,
                },
            },
        },
        RightContainer:new{
            dimen = Geom:new{ w = content_w - math.floor(content_w * 0.6), h = bar_h },
            icons,
        },
    }
end

function BookshelfWidget:separator(content_w)
    return LineWidget:new{
        dimen = Geom:new{ w = content_w, h = Size.line.thin },
        background = Blitbuffer.COLOR_GRAY_D,
    }
end

-- Centered empty-shelf hint (title + one line of gray hint text).
function BookshelfWidget:buildEmptyState(content_w, avail_h, hint_text)
    local group = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = _("书架空空如也"),
            face = Font:getFace("tfont"),
        },
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        TextWidget:new{
            text = hint_text,
            face = Font:getFace("smallinfofont"),
            fgcolor = Blitbuffer.COLOR_GRAY_5,
        },
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = avail_h },
        group,
    }
end

function BookshelfWidget:buildUI()
    -- WeRead mode: three tabbed pages sharing the bottom tab bar.
    if self.data.weread then
        local tab = self.data.tab or "shelf"
        if tab == "store" then
            self:buildStoreUI()
        elseif tab == "settings" then
            self:buildSettingsUI()
        else
            self:buildWereadUI()
        end
        return
    end
    -- Not logged in: the QR login prompt is the only other page.
    self:buildLoginUI()
end

function BookshelfWidget:changeWereadPage(delta)
    local per_page = self.weread_per_page
    if not per_page then
        return
    end
    local pages = math.ceil(#(self.data.books or {}) / per_page)
    if pages < 2 then
        return
    end
    -- Wrap around: swiping past the last page returns to the first.
    self.weread_page = (self.weread_page - 1 + delta) % pages + 1
    if self[1] then
        self[1]:free() -- release cover blitbuffers
    end
    self:buildUI()
    UIManager:setDirty(self, "ui")
end

--[[--
WeRead shelf layout: top bar (with the account name under the clock),
then a multi-row cover grid paged vertically (rows per page depend on
the available height), with page dots pinned above the bottom edge.
--]]--
function BookshelfWidget:buildWereadUI()
    local screen_w = self.dimen.w
    local screen_h = self.dimen.h
    local portrait = screen_h >= screen_w
    local columns = portrait and 4 or 6
    local margin = Screen:scaleBySize(28)
    local content_w = screen_w - 2 * margin

    local page = VerticalGroup:new{ align = "left" }
    local used_h = 0
    local function add(widget, h)
        table.insert(page, widget)
        used_h = used_h + (h or widget:getSize().h)
    end

    local top_pad = Screen:scaleBySize(16)
    local topbar = self:buildTopBar(content_w)
    add(VerticalSpan:new{ width = top_pad }, top_pad)
    add(topbar)
    if self.data.account_name then
        add(VerticalSpan:new{ width = Screen:scaleBySize(4) })
        add(TextWidget:new{
            text = string.format(_("微信读书 · %s"), self.data.account_name),
            face = Font:getFace("xx_smallinfofont"),
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        })
    end
    add(VerticalSpan:new{ width = Screen:scaleBySize(8) })
    add(self:separator(content_w))

    local search_h = Screen:scaleBySize(36)
    add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
    add(SearchEntry:new{
        dimen = Geom:new{ w = content_w, h = search_h },
        text = self.data.shelf_query and string.format(
            _("筛选：%s（点击修改）"), self.data.shelf_query)
            or _("搜索书架"),
        callback = function()
            if self.on_shelf_search then
                self.on_shelf_search(self.data.shelf_query)
            end
        end,
    }, search_h)

    local books = self.data.books or {}

    if #books == 0 then
        add(self:buildEmptyState(content_w,
            screen_h - used_h - Screen:scaleBySize(32),
            self.data.shelf_query and _("没有匹配的书籍，点击上方搜索框修改筛选")
                or _("去菜单「微读 → 微信读书 → 刷新书架」拉取书架")))
    else
        local title_h = textHeight(Font:getFace("xx_smallinfofont"))
        -- One-line title only: reading state is badged on the cover, so
        -- the freed footer height goes to more rows per page.
        local labels_h = title_h + Screen:scaleBySize(6)
        local cell_gap = Screen:scaleBySize(16)
        local row_gap = Screen:scaleBySize(16)
        local cell_w = math.floor((content_w - (columns - 1) * cell_gap) / columns)
        -- Cover box: 4:3-ish portrait aspect, capped like local covers.
        local max_cover = math.min(math.floor(cell_w * 4 / 3), Screen:scaleBySize(260))
        local min_cover = Screen:scaleBySize(100)
        local indicator_h = Screen:scaleBySize(30)
        local bottom_pad = Screen:scaleBySize(16)
        local avail_h = screen_h - used_h - indicator_h - bottom_pad
            - self:tabBarHeight()
            - Screen:scaleBySize(14) -- gap below the separator
        -- Fill the available height: start from the row count that fits
        -- with the smallest acceptable covers, then expand covers until
        -- they hit the proportional maximum.  Extra space (when covers
        -- are already at max) stays as padding below the grid — the
        -- common Kindle case of only 2 rows with huge empty footer now
        -- gets 3 rows with slightly shorter covers instead.
        local rows = math.max(1, math.floor(
            (avail_h + row_gap) / (min_cover + labels_h + row_gap)))
        local cover_h = math.floor(
            (avail_h - (rows - 1) * row_gap) / rows) - labels_h
        while rows > 1 and cover_h < min_cover do
            rows = rows - 1
            cover_h = math.floor(
                (avail_h - (rows - 1) * row_gap) / rows) - labels_h
        end
        cover_h = math.min(cover_h, max_cover)
        local row_h = cover_h + labels_h
        local per_page = rows * columns
        self.weread_per_page = per_page
        local pages = math.ceil(#books / per_page)
        self.weread_page = math.min(math.max(self.weread_page or 1, 1), pages)

        -- ---- Grid for the current page -------------------------------
        local grid = VerticalGroup:new{ align = "left" }
        local first = (self.weread_page - 1) * per_page + 1
        local last = math.min(first + per_page - 1, #books)
        local i = first
        while i <= last do
            local row = HorizontalGroup:new{ align = "top" }
            for c = 1, columns do
                if i > last then
                    break
                end
                if c > 1 then
                    table.insert(row, HorizontalSpan:new{ width = cell_gap })
                end
                local book = books[i]
                -- Normalize for WereadBookCell: the cover badging only
                -- needs finished, everything else is a clean cover.
                local cell_book = {
                    text = book.text,
                    cover_path = book.cover_path,
                }
                if book.finished then
                    cell_book.finished = true
                end
                table.insert(row, WereadBookCell:new{
                    book = cell_book,
                    dimen = Geom:new{ w = cell_w, h = row_h },
                    cover_h = cover_h,
                    show_parent = self,
                    callback = function()
                        -- Open the original shelf entry, not the
                        -- normalized cell book.
                        if self.on_open_book then
                            self.on_open_book(book)
                        end
                    end,
                    hold_callback = function()
                        -- Long-press: download options (补齐/重新下载).
                        if self.on_book_hold then
                            self.on_book_hold(book)
                        end
                    end,
                })
                i = i + 1
            end
            table.insert(grid, row)
            if i <= last then
                table.insert(grid, VerticalSpan:new{ width = row_gap })
            end
        end

        add(VerticalSpan:new{ width = Screen:scaleBySize(14) })
        -- The swipe area spans all grid rows, even when the last page
        -- shows fewer books.
        local grid_area_h = rows * row_h + (rows - 1) * row_gap
        add(GridPage:new{
            dimen = Geom:new{ w = content_w, h = grid_area_h },
            grid = grid,
            on_swipe = function(delta)
                self:changeWereadPage(delta)
            end,
        })

        -- ---- Page indicator, pinned above the tab bar ----------------
        local leftover = screen_h - used_h - indicator_h - bottom_pad
            - self:tabBarHeight()
        if leftover > 0 then
            add(VerticalSpan:new{ width = leftover }, leftover)
        end
        if pages > 1 then
            local dots = {}
            for p = 1, pages do
                dots[p] = p == self.weread_page and "●" or "○"
            end
            add(CenterContainer:new{
                dimen = Geom:new{ w = content_w, h = indicator_h },
                TextWidget:new{
                    text = string.format("%s  %d/%d",
                        table.concat(dots), self.weread_page, pages),
                    face = Font:getFace("xx_smallinfofont"),
                    fgcolor = Blitbuffer.COLOR_GRAY_5,
                },
            }, indicator_h)
        else
            add(VerticalSpan:new{ width = indicator_h }, indicator_h)
        end
    end

    self:wrapWereadPage(page, used_h)
end

--[[--
The WeRead store tab: a search entry on top, then either the search
results grid or the recommendation feed sections (横向滑动翻页).
--]]--
function BookshelfWidget:buildStoreUI()
    local screen_w = self.dimen.w
    local screen_h = self.dimen.h
    local portrait = screen_h >= screen_w
    local columns = portrait and 4 or 6
    local margin = Screen:scaleBySize(28)
    local content_w = screen_w - 2 * margin
    local section_gap = Screen:scaleBySize(14)

    local page = VerticalGroup:new{ align = "left" }
    local used_h = 0
    local function add(widget, h)
        table.insert(page, widget)
        used_h = used_h + (h or widget:getSize().h)
    end

    local top_pad = Screen:scaleBySize(16)
    local topbar = self:buildTopBar(content_w)
    add(VerticalSpan:new{ width = top_pad }, top_pad)
    add(topbar)
    add(VerticalSpan:new{ width = Screen:scaleBySize(8) })
    add(self:separator(content_w))
    add(VerticalSpan:new{ width = section_gap })

    -- ---- Search entry -------------------------------------------------
    local entry_h = Screen:scaleBySize(36)
    add(SearchEntry:new{
        dimen = Geom:new{ w = content_w, h = entry_h },
        callback = function()
            if self.on_store_search then
                -- No keyword: the host prompts for one first.
                self.on_store_search(nil)
            end
        end,
    }, entry_h)
    add(VerticalSpan:new{ width = section_gap })

    local avail_h = screen_h - used_h - self:tabBarHeight()
        - Screen:scaleBySize(16) -- bottom pad

    -- ---- Body: search results / feed / states -------------------------
    local search = self.data.store_search
    if search then
        -- Header: "「kw」的搜索结果" + 返回书城 on the right.
        local back_w = Screen:scaleBySize(120)
        local header_h = textHeight(Font:getFace("smallinfofontbold"))
        add(HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = content_w - back_w, h = header_h },
                TextWidget:new{
                    text = string.format(_("“%s”的搜索结果"), search.keyword or ""),
                    face = Font:getFace("smallinfofontbold"),
                },
            },
            RightContainer:new{
                dimen = Geom:new{ w = back_w, h = header_h },
                HiddenEntry:new{
                    dimen = Geom:new{ w = back_w, h = header_h },
                    text = _("返回书城"),
                    callback = self.on_store_search_back,
                },
            },
        }, header_h)
        add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
        if search.error then
            local remaining = screen_h - used_h - self:tabBarHeight()
                - Screen:scaleBySize(16)
            add(self:buildStoreError(remaining, function()
                if self.on_store_search then
                    self.on_store_search(search.keyword)
                end
            end))
        else
            self:addStoreGrid(page, add, search.books or {}, columns,
                content_w, screen_h - used_h - self:tabBarHeight()
                - Screen:scaleBySize(16))
        end
    elseif self.data.store_error then
        add(self:buildStoreError(avail_h, function()
            if self.on_store_feed then
                self.on_store_feed()
            end
        end))
    elseif not self.data.store_feed then
        -- First visit: the fetch was kicked off by switchTab; the busy
        -- spinner usually covers this placeholder.
        add(CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = avail_h },
            TextWidget:new{
                text = _("加载中…"),
                face = Font:getFace("smallinfofont"),
                fgcolor = Blitbuffer.COLOR_GRAY_5,
            },
        })
    else
        self.store_pages = self.store_pages or {}
        local title_h = textHeight(Font:getFace("xx_smallinfofont"))
        local labels_h = title_h + Screen:scaleBySize(6)
        local header_face = Font:getFace("smallinfofontbold")
        local header_h = textHeight(header_face)
        local cell_gap = Screen:scaleBySize(16)
        local cell_w = math.floor((content_w - (columns - 1) * cell_gap) / columns)
        local sections = self.data.store_feed
        local n = #sections
        -- Split the remaining space between the feed rows; shrink the
        -- covers (never below the floor) until everything fits.
        local cover_h = math.min(math.floor(cell_w * 4 / 3),
            Screen:scaleBySize(260))
        local row_h = cover_h + labels_h
        local function total_h(ch)
            return n * (section_gap + header_h + Screen:scaleBySize(10)
                + ch + labels_h)
                + (n - 1) * (2 * section_gap + Size.line.thin)
        end
        while cover_h > Screen:scaleBySize(100) and total_h(cover_h) > avail_h do
            cover_h = cover_h - Screen:scaleBySize(8)
        end
        row_h = cover_h + labels_h
        for si, s in ipairs(sections) do
            if si > 1 then
                add(VerticalSpan:new{ width = section_gap })
                add(self:separator(content_w))
            end
            add(VerticalSpan:new{ width = section_gap })
            local pages = math.ceil(#s.books / columns)
            local page_idx = math.min(self.store_pages[si] or 1, pages)
            self.store_pages[si] = page_idx
            add(TextWidget:new{ text = s.title, face = header_face }, header_h)
            add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
            local row = HorizontalGroup:new{ align = "top" }
            local first = (page_idx - 1) * columns + 1
            local last = math.min(page_idx * columns, #s.books)
            for i = first, last do
                if i > first then
                    table.insert(row, HorizontalSpan:new{ width = cell_gap })
                end
                local book = s.books[i]
                table.insert(row, WereadBookCell:new{
                    book = {
                        text = book.text,
                        cover_path = book.cover_path,
                    },
                    dimen = Geom:new{ w = cell_w, h = row_h },
                    cover_h = cover_h,
                    show_parent = self,
                    callback = function()
                        if self.on_open_book then
                            self.on_open_book(book)
                        end
                    end,
                })
            end
            add(SectionRow:new{
                dimen = Geom:new{ w = content_w, h = row_h },
                row = row,
                on_swipe = function(delta)
                    self:changeStorePage(si, delta)
                end,
            })
        end
    end

    self:wrapWereadPage(page, used_h)
end

-- Centered「加载失败，点击重试」state for the store tab.
function BookshelfWidget:buildStoreError(avail_h, retry)
    local content_w = self.dimen.w - 2 * Screen:scaleBySize(28)
    local entry_h = textHeight(Font:getFace("smallinfofont"))
    return CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = math.max(avail_h, entry_h) },
        HiddenEntry:new{
            dimen = Geom:new{ w = content_w, h = entry_h },
            text = _("加载失败，点击重试"),
            callback = retry,
        },
    }
end

-- Search-result grid: as many rows as fit, a hint when truncated.
function BookshelfWidget:addStoreGrid(page, add, books, columns, content_w, avail_h)
    local title_h = textHeight(Font:getFace("xx_smallinfofont"))
    local labels_h = title_h + Screen:scaleBySize(6)
    local cell_gap = Screen:scaleBySize(16)
    local row_gap = Screen:scaleBySize(16)
    local cell_w = math.floor((content_w - (columns - 1) * cell_gap) / columns)
    local max_cover = math.min(math.floor(cell_w * 4 / 3), Screen:scaleBySize(260))
    local min_cover = Screen:scaleBySize(100)
    -- Fill the available height: start from the most rows that fit with
    -- the smallest acceptable covers, then expand covers up to the
    -- proportional maximum.
    local rows = math.max(1, math.floor((avail_h + row_gap) / (min_cover + labels_h + row_gap)))
    local cover_h = math.floor((avail_h - (rows - 1) * row_gap) / rows) - labels_h
    while rows > 1 and cover_h < min_cover do
        rows = rows - 1
        cover_h = math.floor((avail_h - (rows - 1) * row_gap) / rows) - labels_h
    end
    cover_h = math.min(cover_h, max_cover)
    local row_h = cover_h + labels_h
    local shown = math.min(#books, rows * columns)
    local grid = VerticalGroup:new{ align = "left" }
    local i = 1
    while i <= shown do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 1, columns do
            if i > shown then
                break
            end
            if c > 1 then
                table.insert(row, HorizontalSpan:new{ width = cell_gap })
            end
            local book = books[i]
            table.insert(row, WereadBookCell:new{
                book = {
                    text = book.text,
                    cover_path = book.cover_path,
                },
                dimen = Geom:new{ w = cell_w, h = row_h },
                cover_h = cover_h,
                show_parent = self,
                callback = function()
                    if self.on_open_book then
                        self.on_open_book(book)
                    end
                end,
            })
            i = i + 1
        end
        table.insert(grid, row)
        if i <= shown then
            table.insert(grid, VerticalSpan:new{ width = row_gap })
        end
    end
    add(grid)
    if #books == 0 then
        add(CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = Screen:scaleBySize(60) },
            TextWidget:new{
                text = _("没有找到相关书籍"),
                face = Font:getFace("smallinfofont"),
                fgcolor = Blitbuffer.COLOR_GRAY_5,
            },
        })
    elseif shown < #books then
        add(VerticalSpan:new{ width = Screen:scaleBySize(8) })
        add(TextWidget:new{
            text = string.format(_("仅显示前 %d 本"), shown),
            face = Font:getFace("xx_smallinfofont"),
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        }, title_h)
    end
end

function BookshelfWidget:changeStorePage(section_index, delta)
    local sections = self.data.store_feed
    local s = sections and sections[section_index]
    if not s then
        return
    end
    local portrait = self.dimen.h >= self.dimen.w
    local columns = portrait and 4 or 6
    local pages = math.ceil(#s.books / columns)
    if pages < 2 then
        return
    end
    self.store_pages = self.store_pages or {}
    self.store_pages[section_index] =
        ((self.store_pages[section_index] or 1) - 1 + delta) % pages + 1
    if self[1] then
        self[1]:free()
    end
    self:buildUI()
    UIManager:setDirty(self, "ui")
end

--[[--
The WeRead settings tab: account card on top, then action rows grouped
into read / device / tools / info.  Long lists of device quick-settings
(light, night mode, wifi …) live on a secondary page reached by tapping
"设备快捷设置 ▸"; a back button in its header returns to the main page.
--]]--
function BookshelfWidget:buildSettingsUI()
    if self.settings_sub_page == "device" then
        self:buildDeviceSettingsUI()
        return
    end

    local screen_w = self.dimen.w
    local screen_h = self.dimen.h
    local margin = Screen:scaleBySize(28)
    local content_w = screen_w - 2 * margin

    local page = VerticalGroup:new{ align = "left" }
    local used_h = 0
    local function add(widget, h)
        table.insert(page, widget)
        used_h = used_h + (h or widget:getSize().h)
    end

    local top_pad = Screen:scaleBySize(16)
    local topbar = self:buildTopBar(content_w)
    add(VerticalSpan:new{ width = top_pad }, top_pad)
    add(topbar)
    add(VerticalSpan:new{ width = Screen:scaleBySize(8) })
    add(self:separator(content_w))

    -- ---- Account card --------------------------------------------------
    add(VerticalSpan:new{ width = Screen:scaleBySize(20) })
    add(TextWidget:new{
        text = self.data.account_name or _("微信读书用户"),
        face = Font:getFace("smalltfont"),
    })
    add(VerticalSpan:new{ width = Screen:scaleBySize(20) })
    add(self:separator(content_w))

    -- ---- Device status line --------------------------------------------
    if self.data.device_status and self.data.device_status ~= "" then
        add(VerticalSpan:new{ width = Screen:scaleBySize(12) })
        add(TextWidget:new{
            text = self.data.device_status,
            face = Font:getFace("xx_smallinfofont"),
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        })
        add(VerticalSpan:new{ width = Screen:scaleBySize(12) })
        add(self:separator(content_w))
    end

    -- ---- Action rows, grouped by section --------------------------------
    local row_h = Screen:scaleBySize(44)
    local rows = {}
    -- 阅读
    table.insert(rows, {
        label = _("同步阅读进度"),
        value = self.data.sync_progress and _("开") or _("关"),
        callback = self.on_toggle_sync,
    })
    table.insert(rows, {
        label = _("离线阅读时长"),
        value = self.data.sync_status_label or _("无待上报"),
        callback = self.on_sync_status,
    })
    table.insert(rows, {
        label = _("自动显示桌面（启动和退出书籍时）"),
        value = self.data.auto_start and _("开") or _("关"),
        callback = self.on_toggle_autostart,
    })
    table.insert(rows, {
        label = _("定时熄屏（无操作自动休眠）"),
        value = self.data.autosuspend_label,
        callback = self.on_set_autosuspend,
    })
    table.insert(rows, {
        label = _("书架排序"),
        value = self.data.shelf_sort_label,
        callback = self.on_cycle_shelf_sort,
    })
    table.insert(rows, {
        label = _("阅读统计"),
        value = _("查看"),
        callback = self.on_read_stats,
    })
    table.insert(rows, {
        label = _("微读缓存"),
        value = self.data.storage_label or _("查看"),
        callback = self.on_storage,
    })
    if self.data.has_frontlight then
        table.insert(rows, {
            label = _("前光（亮度/色温）"),
            value = _("调节"),
            callback = self.on_frontlight,
        })
    end
    -- 设备 → sub-page
    table.insert(rows, {
        label = _("设备快捷设置"),
        value = "▸",
        callback = function()
            self.settings_sub_page = "device"
            self:buildUI()
            UIManager:setDirty(self, "full")
        end,
    })
    -- 工具
    table.insert(rows, { label = _("刷新书架"), callback = self.on_refresh_shelf })
    table.insert(rows, { label = _("重新扫码登录"), callback = self.on_relogin })
    table.insert(rows, { label = _("退出登录"), callback = self.on_logout })
    -- 关于
    table.insert(rows, {
        label = _("检查更新"),
        value = self.data.plugin_version
            and ("v" .. self.data.plugin_version) or nil,
        callback = self.on_check_update,
    })
    table.insert(rows, { label = _("关于"), callback = self.on_about })
    local avail_h = screen_h - used_h - self:tabBarHeight()
    if #rows * row_h > avail_h then
        row_h = math.max(Screen:scaleBySize(30), math.floor(avail_h / #rows))
    end
    for _, def in ipairs(rows) do
        add(SettingsRow:new{
            dimen = Geom:new{ w = content_w, h = row_h },
            label = def.label,
            value = def.value,
            callback = def.callback,
        }, row_h)
        add(self:separator(content_w))
    end

    self:wrapWereadPage(page, used_h)
end

-- Device quick-settings sub-page: the same top-bar / tab-bar chrome as
-- the main settings page, with a "← 返回" row (no button border) at the
-- top of the content area to go back.  The device status line and the
-- six quick-setting rows follow.
function BookshelfWidget:buildDeviceSettingsUI()
    local screen_w = self.dimen.w
    local screen_h = self.dimen.h
    local margin = Screen:scaleBySize(28)
    local content_w = screen_w - 2 * margin

    local page = VerticalGroup:new{ align = "left" }
    local used_h = 0
    local function add(widget, h)
        table.insert(page, widget)
        used_h = used_h + (h or widget:getSize().h)
    end

    local top_pad = Screen:scaleBySize(16)
    local topbar = self:buildTopBar(content_w)
    add(VerticalSpan:new{ width = top_pad }, top_pad)
    add(topbar)
    add(VerticalSpan:new{ width = Screen:scaleBySize(8) })
    add(self:separator(content_w))

    -- ---- Back row -------------------------------------------------------
    local row_h = Screen:scaleBySize(44)
    add(SettingsRow:new{
        dimen = Geom:new{ w = content_w, h = row_h },
        label = "← " .. _("返回"),
        callback = function()
            self.settings_sub_page = nil
            self:buildUI()
            UIManager:setDirty(self, "full")
        end,
    }, row_h)
    add(self:separator(content_w))

    -- ---- Device status line ---------------------------------------------
    if self.data.device_status and self.data.device_status ~= "" then
        add(VerticalSpan:new{ width = Screen:scaleBySize(12) })
        add(TextWidget:new{
            text = self.data.device_status,
            face = Font:getFace("xx_smallinfofont"),
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        })
        add(VerticalSpan:new{ width = Screen:scaleBySize(12) })
        add(self:separator(content_w))
    end

    -- ---- Device quick-settings rows -------------------------------------
    local rows = {}
    table.insert(rows, {
        label = _("夜间模式（反色）"),
        value = self.data.night_mode and _("开") or _("关"),
        callback = self.on_toggle_night_mode,
    })
    table.insert(rows, {
        label = _("Wi-Fi"),
        value = self.data.wifi_on and _("开") or _("关"),
        callback = self.on_toggle_wifi,
    })
    table.insert(rows, {
        label = _("屏幕旋转"),
        value = self.data.rotation_label,
        callback = self.on_cycle_rotation,
    })
    table.insert(rows, {
        label = _("屏保"),
        value = self.data.screensaver_label,
        callback = self.on_cycle_screensaver,
    })
    table.insert(rows, {
        label = _("时钟格式"),
        value = self.data.clock_label,
        callback = self.on_toggle_clock,
    })
    for _, def in ipairs(rows) do
        add(SettingsRow:new{
            dimen = Geom:new{ w = content_w, h = row_h },
            label = def.label,
            value = def.value,
            callback = def.callback,
        }, row_h)
        add(self:separator(content_w))
    end

    self:wrapWereadPage(page, used_h)
end

--[[--
The WeRead login prompt shown when no account is logged in: title,
subtitle and a QR-login button centered on the page.
--]]--
function BookshelfWidget:buildLoginUI()
    local screen_w = self.dimen.w
    local screen_h = self.dimen.h
    local margin = Screen:scaleBySize(28)
    local content_w = screen_w - 2 * margin

    local page = VerticalGroup:new{ align = "left" }
    local used_h = 0
    local function add(widget, h)
        table.insert(page, widget)
        used_h = used_h + (h or widget:getSize().h)
    end

    local top_pad = Screen:scaleBySize(16)
    local topbar = self:buildTopBar(content_w)
    add(VerticalSpan:new{ width = top_pad }, top_pad)
    add(topbar)
    add(VerticalSpan:new{ width = Screen:scaleBySize(8) })
    add(self:separator(content_w))

    add(CenterContainer:new{
        dimen = Geom:new{
            w = content_w,
            h = screen_h - used_h - Screen:scaleBySize(32),
        },
        VerticalGroup:new{
            align = "center",
            TextWidget:new{
                text = _("微信读书"),
                face = Font:getFace("tfont"),
            },
            VerticalSpan:new{ width = Screen:scaleBySize(10) },
            TextWidget:new{
                text = _("扫码登录，同步你的书架和阅读进度"),
                face = Font:getFace("smallinfofont"),
                fgcolor = Blitbuffer.COLOR_GRAY_5,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(28) },
            Button:new{
                text = _("扫码登录"),
                width = Screen:scaleBySize(240),
                show_parent = self,
                callback = function()
                    if self.on_login then
                        self.on_login()
                    end
                end,
            },
        },
    })

    -- Push everything towards the top.
    local leftover = screen_h - used_h
    if leftover > 0 then
        table.insert(page, VerticalSpan:new{ width = leftover })
    end

    self[1] = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            page,
        },
    }
end

function BookshelfWidget:onTap()
    UIManager:close(self)
    return true
end

function BookshelfWidget:onClose()
    UIManager:close(self)
    return true
end

function BookshelfWidget:onCloseWidget()
    if self.on_close then
        self.on_close()
    end
    UIManager:setDirty(nil, "full")
end

return BookshelfWidget
