--[[--
Regression test: chapter downloads fetch thought locations only.

Run from the plugin directory:
    cd wereaddesktop.koplugin && luajit spec/test_lazy_thought_downloader.lua
--]]--

package.path = package.path .. ";./?.lua"

local noop = function() end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_, _delay, fn) fn() end }
end
package.preload["weread.lib.logger"] = function()
    return { info = noop, warn = noop, err = noop }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return { template = function(value) return value end }
end
package.preload["weread.lib.content"] = function()
    return {
        finalize_single_chapter_content = function(_, _, _, _, xhtml)
            return xhtml, {}
        end,
        save_chapter_part = noop,
        save_part_asset = noop,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(value) return value end }
end
package.preload["weread.lib.protocol"] = function() return {} end

local apply_calls = 0
package.preload["weread.lib.thoughts"] = function()
    return {
        fetch_underlines = function()
            return true, {
                underlines = {
                    { range = "15-17", type = 0 },
                    { range = "19-21", type = 2 },
                },
            }, { "15-17", "19-21" }
        end,
        apply_data = function(_, _, _, xhtml, _underlines, reviews)
            assert(reviews == nil, "comment bodies must not be passed")
            apply_calls = apply_calls + 1
            return xhtml, ""
        end,
        merge_css = function(css) return css end,
    }
end

local review_calls = 0
local Downloader = require("weread.lib.downloader")
local downloader = Downloader:new{
    client = {
        get_chapter_reviews_batch = function()
            review_calls = review_calls + 1
            return true, { reviews = {} }
        end,
    },
    settings = {
        get = function() return { download_book_images = false } end,
    },
}

local finished = false
downloader._finishChapter = function()
    finished = true
end

local dl = {
    book = { book_id = "3300050599" },
    current = {
        chapter = { chapterUid = 59 },
        xhtml = "<html><body>正文</body></html>",
    },
    index = 1,
    total = 1,
    state = {},
}
downloader:_startAnnotations(dl)

local failures = 0
local function check(label, condition)
    if condition then
        print("ok   - " .. label)
    else
        failures = failures + 1
        print("FAIL - " .. label)
    end
end

check("chapter download never fetches comment bodies", review_calls == 0)
check("underline locations are still injected", apply_calls == 1 and finished)
check("only type=0 is counted as a thought location",
    dl.annotation and dl.annotation.thought_locations == 1)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
