--[[--
Regression checks for lazy WeRead thought markers.

Downloading a chapter must only embed the location of public thoughts.
It must not require the comment bodies to have been downloaded first.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_lazy_thoughts.lua
--]]--

package.path = package.path .. ";./?.lua"

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end }
end

local Annotations = require("weread.lib.annotations")

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

local source = "<html><body><p>甲乙丙丁戊己庚辛壬癸</p></body></html>"
local underlines = {
    -- type=0: known public-thought location; count is not the comment count.
    { range = "15-17", type = 0, count = 0 },
    -- type=2: popular underline; it still needs a tappable target so it
    -- does not look interactive but fall through to page turning.
    { range = "19-21", type = 2, count = 50 },
}

local converted = Annotations.process(source, {
    chapterUid = 59,
    underlines = underlines,
}, nil, "3300050599")

check("thought marker is present without downloading comment bodies",
    converted:find(
        'href="wrthought://3300050599/59/15-17"', 1, true
    ) ~= nil)
check("all visible underlines become tappable thought ranges",
    select(2, converted:gsub("wrthought://", "")) == 2
    and converted:find(
        'href="wrthought://3300050599/59/19-21"', 1, true
    ) ~= nil)
check("popular underline remains visually distinct without a thought star",
    select(2, converted:gsub('class="wr%-underline"', "")) == 2
    and select(2, converted:gsub('class="wr%-star"', "")) == 1)

local parsed = Annotations.parseThoughtURL(
    "wrthought://3300050599/59/15-17"
)
check("thought URL round-trips its lookup key",
    parsed
    and parsed.book_id == "3300050599"
    and parsed.chapter_uid == 59
    and parsed.range == "15-17")
check("unrelated links are ignored",
    Annotations.parseThoughtURL("https://weread.qq.com/") == nil)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
