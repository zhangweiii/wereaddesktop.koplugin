--[[--
Regression test: chapter downloads respect the per-download comment option.

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
-- downloader.lua requires lfs for the fill-missing cached-file check; not
-- exercised by this test, a nil-returning stub suffices.
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end
package.preload["ffi/util"] = function()
    return { template = function(value) return value end }
end
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = noop,
        fetch_single_chapter_source = function()
            return "<html><body>正文</body></html>"
        end,
        finalize_single_chapter_content = function(_, _, _, _, xhtml)
            return xhtml, {}
        end,
        save_chapter_part = noop,
        save_part_asset = noop,
        save_parts_css = noop,
        save_book_epub = function()
            return "/cache/3300050599/book.epub"
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(value) return value end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function() return nil end,
        reader_url = function(book_id)
            return "https://weread.qq.com/web/reader/" .. tostring(book_id)
        end,
    }
end

local apply_calls = 0
local applied_review_count = 0
package.preload["weread.lib.thoughts"] = function()
    return {
        is_download_enabled = function() return true end,
        fetch_underlines = function()
            return true, {
                underlines = {
                    { range = "15-17", type = 0 },
                    { range = "19-21", type = 2 },
                },
            }, { "15-17", "19-21" }
        end,
        apply_data = function(_, _, _, xhtml, _underlines, reviews)
            apply_calls = apply_calls + 1
            applied_review_count = #(reviews or {})
            return xhtml, ""
        end,
        merge_css = function(css) return css end,
    }
end

local review_calls = 0
local batched_range_count = 0
local Downloader = require("weread.lib.downloader")
local downloader = Downloader:new{
    client = {
        build_chapter_review_batches = function(_, ranges)
            batched_range_count = #ranges
            return { { { range = ranges[1] } } }
        end,
        get_chapter_reviews_batch = function()
            review_calls = review_calls + 1
            return true, { reviews = { { range = "15-17" } } }
        end,
    },
    settings = {
        get = function() return { download_book_images = false } end,
    },
}

local plain_finished = false
local plain_started_comments = false
local original_start_annotations = downloader._startAnnotations
downloader._startAnnotations = function()
    plain_started_comments = true
end
downloader._finishChapter = function() plain_finished = true end
downloader:_step{
    book = { book_id = "3300050599" },
    chapters = { { chapterUid = 59 } },
    include_comments = false,
    index = 1,
    total = 1,
    state = {},
}

downloader._startAnnotations = original_start_annotations
local finished = false
downloader._finishChapter = function() finished = true end

local dl = {
    book = { book_id = "3300050599" },
    current = {
        chapter = { chapterUid = 59 },
        xhtml = "<html><body>正文</body></html>",
    },
    index = 1,
    total = 1,
    state = {},
    include_comments = true,
    annotation_failed_batches = 0,
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

check("plain-text option skips all comment requests",
    plain_finished and not plain_started_comments and review_calls == 1)
check("comment option downloads comment bodies", review_calls == 1)
check("underline locations are still injected", apply_calls == 1 and finished)
check("downloaded comment bodies are passed to the cache layer",
    applied_review_count == 1)
check("all underline ranges are considered for comment download",
    batched_range_count == 2)

local scheduled = {}
local headless_progress = {}
local headless_result
local headless_save_calls = 0
local headless = Downloader:new{
    client = {},
    settings = {
        get = function() return { download_book_images = false } end,
        save_book = function()
            headless_save_calls = headless_save_calls + 1
        end,
        flush = noop,
    },
    schedule_step = function(fn)
        scheduled[#scheduled + 1] = fn
    end,
    require_login = function() return true end,
    run_online_task = function(_, fn) fn() return true end,
    show_info = noop,
    show_transient = noop,
    refresh_ui = noop,
    refresh_shelf = noop,
    open_file = noop,
}
headless:start({ book_id = "3300050599", title = "测试书" }, {
    { chapterUid = 59, title = "第一章" },
}, "full", {
    headless = true,
    include_comments = false,
    on_progress = function(_title, progress)
        headless_progress[#headless_progress + 1] = progress
    end,
    on_complete = function(ok, path, metadata)
        headless_result = { ok = ok, path = path, metadata = metadata }
    end,
})
while #scheduled > 0 do
    table.remove(scheduled, 1)()
end
check("headless mode completes through the injected scheduler",
    headless_result and headless_result.ok == true
    and headless_result.path == "/cache/3300050599/book.epub")
check("headless mode reports chapter progress without a dialog",
    headless_progress[#headless_progress] == 1)
check("headless mode leaves book-record persistence to its parent",
    headless_save_calls == 0
    and headless_result.metadata
    and headless_result.metadata.download_record
    and headless_result.metadata.download_record.cached_file
        == "/cache/3300050599/book.epub")

-- Whole-book prefetch must persist each range's pagination cursor, otherwise
-- the reader cannot offer "load more" directly from the warm cache.
local ThoughtDB = require("weread.lib.thought_db")
local statement_calls = {}
local fake_db = {
    exec = noop,
    prepare = function(_, sql)
        local statement = { sql = sql }
        function statement:reset() return self end
        function statement:bind(...)
            statement_calls[#statement_calls + 1] = {
                sql = self.sql,
                args = { ... },
            }
            return self
        end
        function statement:step() return nil end
        function statement:close() end
        return statement
    end,
}
ThoughtDB.putReviews(fake_db, 59, {
    {
        range = "15-17",
        pageReviews = {},
        maxIdx = 30,
        synckey = 88,
        totalCount = 42,
        hasMore = true,
    },
})
local cursor_call
for _, call in ipairs(statement_calls) do
    if call.sql:find("INSERT OR REPLACE INTO review_ranges", 1, true) then
        cursor_call = call
        break
    end
end
check("prefetched thought ranges persist their load-more cursor",
    cursor_call
    and cursor_call.args[1] == 59
    and cursor_call.args[2] == "15-17"
    and cursor_call.args[4] == 30
    and cursor_call.args[5] == 88
    and cursor_call.args[7] == 1)

if failures > 0 then
    print(failures .. " check(s) FAILED")
    os.exit(1)
end
print("all checks passed")
