-- Book/chapter download engine.
--
-- Extracted from main.lua as an independent, dependency-injected object so the
-- plugin entry point keeps only thin menu wrappers. The host injects the API
-- client, settings, and a small set of UI/framework callbacks; the engine owns
-- the whole async download state machine and the device standby guard.
--
-- Standby guard: long downloads must not let the device suspend mid-transfer.
-- Every scheduled step runs through _scheduleGuarded, which wraps the step in
-- xpcall and always releases the guard (and closes the dialog + reports the
-- error) if the step throws. This is critical: a bare UIManager:scheduleIn that
-- threw would leak the guard and leave the device unable to sleep until reboot.

local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local logger = require("weread.lib.logger")
local time = require("ui/time")
local T = require("ffi/util").template

local Content = require("weread.lib.content")
local DownloadDialog = require("weread.ui.download_dialog")
local I18n = require("weread.lib.i18n")
local lfs = require("libs/libkoreader-lfs")
local Thoughts = require("weread.lib.thoughts")
local WeRead = require("weread.lib.protocol")

local function _(text)
    return I18n.tr(text)
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local function download_record(book)
    return {
        title = book.title,
        author = book.author,
        cover = book.cover,
        cached_file = book.cached_file,
        cached_chapters = book.cached_chapters,
        reader_url = book.reader_url,
        cache_dir = book.cache_dir,
    }
end

-- Block OS-level standby (Kindle powerd, Kobo lid/menu-suspend, etc.)
local function preventOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = true
    end
end

local function allowOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = false
    end
end

local Downloader = {}
Downloader.__index = Downloader

-- o = {
--   client, settings,                       -- injected dependencies
--   show_info(text), show_transient(text, timeout),
--   show_overlay(widget, refresh_mode),
--   refresh_ui(), refresh_shelf(),
--   open_file(path), safe_callback(label, fn),
--   require_login(cookie, api_key), run_online_task(label, fn),  -- host framework
-- }
function Downloader:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

function Downloader:_showOverlay(widget, refresh_mode)
    if type(self.show_overlay) == "function" then
        local shown = self.show_overlay(widget, refresh_mode)
        if shown then
            return shown
        end
    end
    UIManager:show(widget, refresh_mode or "full")
    return widget
end

-- Keep the device awake during long book downloads (reference counted so
-- multiple concurrent jobs share a single guard).
function Downloader:_beginStandby()
    self._standby_ref = (self._standby_ref or 0) + 1
    if self._standby_ref == 1 then
        UIManager:preventStandby()
        preventOsStandby()
    end
end

function Downloader:_endStandby()
    local ref = self._standby_ref or 0
    if ref <= 0 then
        return
    end
    self._standby_ref = ref - 1
    if self._standby_ref == 0 then
        UIManager:allowStandby()
        allowOsStandby()
    end
end

function Downloader:_releaseStandby(dl)
    if dl and dl.standby_guard then
        dl.standby_guard = nil
        self:_endStandby()
    end
end

function Downloader:_notifyCompletion(dl, ok, value)
    if not dl or dl.completion_notified then return end
    dl.completion_notified = true
    if type(dl.on_complete) ~= "function" then return end
    local called, err = pcall(dl.on_complete, ok == true, value, {
        failed_count = #(dl.failed or {}),
        success_count = #(dl.selected or {}),
        download_record = dl.download_record,
    })
    if not called then
        logger.warn("download completion callback failed:",
            log_error(err))
    end
end

-- Schedule any download step behind xpcall so an uncaught error always
-- releases the standby guard, closes the progress dialog, and reports the
-- failure. Error reporting must not depend on the guard still being held:
-- a step releases the guard itself before later finishing operations
-- (save book, refresh shelf) that can still throw (review.md #4).
function Downloader:_scheduleGuarded(dl, step_fn, delay)
    local run = function()
        local ok, err = xpcall(step_fn, debug.traceback)
        if not ok then
            self:_releaseStandby(dl)
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            logger.err("download step failed:", log_error(err))
            if not dl.completion_notified then
                self:_notifyCompletion(dl, false, err)
                if not dl.headless then
                    self.show_info(T(_("Download failed:\n%1"), display_error(err)))
                end
            end
        end
    end
    if type(self.schedule_step) == "function" then
        self.schedule_step(run, delay or 0.1)
    else
        UIManager:scheduleIn(delay or 0.1, run)
    end
end

-- Public entry: start downloading the given chapters as one EPUB.
-- options.fill_missing: `chapters` is the FULL catalog; only chapters
-- missing from the on-disk parts cache (a previous partial download)
-- are fetched, and the EPUB is repacked from cache + fresh downloads.
-- options.include_comments: fetch underlines and their first comment page.
function Downloader:start(book, chapters, suffix, options)
    options = options or {}
    local full_catalog = chapters
    if options.fill_missing then
        local missing = Content.list_missing_chapters(
            self.settings, book, chapters)
        if #missing == 0 then
            local cached_file = book.cached_file
            if type(cached_file) == "string" and cached_file ~= ""
                and lfs.attributes(cached_file, "mode") == "file" then
                self.show_transient(_("本书已完整，无需补齐"), 2)
                if type(options.on_complete) == "function" then
                    pcall(options.on_complete, true, cached_file, {
                        failed_count = 0,
                        success_count = 0,
                        download_record = download_record(book),
                    })
                end
                return true
            end
            -- Every chapter is cached but the final EPUB was never
            -- finalized (a previous run failed between the parts-cache
            -- writes and the final pack): repack from the parts cache
            -- without re-downloading anything (review.md #14).
            chapters = {}
        else
            chapters = missing
        end
    end
    if not self.require_login(true, false) then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "authentication_required")
        end
        return false
    end
    local task_label = options.single_chapter and _("Download chapter and read") or _("Download full book")
    local started = self.run_online_task(task_label, function()
        local ok_init, err_init = pcall(function()
            Content.ensure_reader_state(self.client, book)
        end)
        if not ok_init then
            logger.err("initialize book download failed:", log_error(err_init))
            if type(options.on_complete) == "function" then
                pcall(options.on_complete, false, err_init)
            end
            if not options.headless then
                self.show_info(T(_("Download failed:\n%1"), display_error(err_init)))
            end
            return
        end

        if not options.headless then
            self:_beginStandby()
        end
        local total = #chapters
        local dl = {
            book = book,
            chapters = chapters,
            catalog = options.fill_missing and full_catalog or nil,
            fill_missing = options.fill_missing == true,
            suffix = suffix or "book",
            index = 1,
            cancelled = false,
            selected = {},
            bodies = {},
            assets = {},
            state = {},
            total = total,
            failed = {},
            annotation_failed_batches = 0,
            include_comments = options.include_comments == true,
            headless = options.headless == true,
            on_progress = options.on_progress,
            single_chapter = options.single_chapter == true,
            open_on_complete = options.open_on_complete == true,
            on_complete = options.on_complete,
            started_at = time.now(),
            standby_guard = options.headless ~= true,
        }

        if not dl.headless then
            local progress_dialog = DownloadDialog:new{
                title = T(_("Downloading: %1"), book.title or ""),
                progress_max = total,
                buttons = {{
                    {
                        text = _("Cancel download"),
                        callback = function()
                            dl.cancelled = true
                            if dl.progress_dialog then
                                dl.progress_dialog:close()
                                dl.progress_dialog = nil
                            end
                        end,
                    },
                }},
            }
            dl.progress_dialog = progress_dialog
            progress_dialog:show(self.show_overlay)
            self.refresh_ui()
        end

        self:_scheduleGuarded(dl, function() self:_step(dl) end)
    end)
    if started == false and type(options.on_complete) == "function" then
        pcall(options.on_complete, false, "offline")
    end
    return started ~= false
end

function Downloader:_setStage(dl, title, progress)
    if dl.progress_dialog then
        dl.progress_dialog:setTitle(title)
        if progress then
            dl.progress_dialog:reportProgress(progress)
        end
    end
    if type(dl.on_progress) == "function" then
        pcall(dl.on_progress, title, progress or 0, dl.total)
    end
end

function Downloader:_reportProgress(dl, progress)
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(progress)
    end
    if type(dl.on_progress) == "function" then
        pcall(dl.on_progress, nil, progress, dl.total)
    end
end

function Downloader:_perf(dl, stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info("download_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed),
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total), ...)
end

function Downloader:_failChapter(dl, err)
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    table.insert(dl.failed, uid)
    logger.warn("chapter download failed:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "error=", log_error(err))
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    self:_reportProgress(dl, dl.index - 1)
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_finishChapter(dl)
    if dl.cancelled or not dl.current then return end
    local chapter = dl.current.chapter
    local cache = self.settings:get("cache")
    local stage_text
    if cache.download_book_images then
        stage_text = T(_("Downloading images · chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    else
        stage_text = T(_("Processing chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    end
    self:_setStage(dl,
        stage_text, dl.index - 0.1)
    local started = time.now()
    local ok, xhtml, chapter_assets = pcall(function()
        return Content.finalize_single_chapter_content(
            self.client, self.settings, dl.book, chapter, dl.current.xhtml, dl.state
        )
    end)
    self:_perf(dl, "images_and_finalize", started, "ok=", tostring(ok))
    if not ok then
        self:_failChapter(dl, xhtml)
        return
    end
    local uid = tostring(chapter.chapterUid or dl.index)
    dl.bodies[uid] = xhtml
    table.insert(dl.selected, chapter)
    for _i, asset in ipairs(chapter_assets or {}) do
        table.insert(dl.assets, asset)
    end
    if not dl.single_chapter then
        -- Parts cache: lets a later "补齐缺失章节" run repack the EPUB
        -- without re-downloading this chapter. Best-effort.
        pcall(Content.save_chapter_part, self.settings, dl.book, uid, xhtml)
        for _i, asset in ipairs(chapter_assets or {}) do
            pcall(Content.save_part_asset, self.settings, dl.book, asset)
        end
    end
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    self:_reportProgress(dl, dl.index - 1)
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_applyAnnotations(dl)
    if dl.cancelled or not dl.current or not dl.annotation then return end
    local annotation = dl.annotation
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setStage(dl,
        T(_("Processing underlines and thoughts · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.15)
    local started = time.now()
    local ok, processed, annotation_css = pcall(function()
        return Thoughts.apply_data(self.settings, book_id, chapter.chapterUid,
            dl.current.xhtml, annotation.underlines, annotation.reviews, dl.book, {
                rebuild_thought_db = not dl.fill_missing
                    and not dl.single_chapter and dl.index == 1,
            })
    end)
    self:_perf(dl, "apply_annotations", started, "ok=", tostring(ok),
        "reviews=", tostring(#(annotation.reviews or {})))
    if not ok then
        self:_failChapter(dl, processed)
        return
    end
    dl.current.xhtml = processed
    dl.state.annotation_css_seen = dl.state.annotation_css_seen or {}
    if annotation_css ~= "" and not dl.state.annotation_css_seen[annotation_css] then
        dl.state.css = Thoughts.merge_css(dl.state.css, annotation_css)
        dl.state.annotation_css_seen[annotation_css] = true
    end
    self:_finishChapter(dl)
end

function Downloader:_annotationBatch(dl)
    if dl.cancelled then
        self:_releaseStandby(dl)
        self:_notifyCompletion(dl, false, "cancelled")
        self.show_transient(_("Download cancelled"), 2)
        return
    end
    local annotation = dl.annotation
    if not annotation then
        self:_finishChapter(dl)
        return
    end
    if annotation.batch_index > #annotation.batches then
        self:_applyAnnotations(dl)
        return
    end

    local batch_index = annotation.batch_index
    local batch_total = #annotation.batches
    local fractional = dl.index - 0.85
        + 0.7 * batch_index / math.max(1, batch_total)
    self:_setStage(dl,
        T(_("Downloading thoughts %1/%2 · chapter %3/%4"),
            tostring(batch_index), tostring(batch_total),
            tostring(dl.index), tostring(dl.total)),
        fractional)

    local started = time.now()
    local ok, result, err = self.client:get_chapter_reviews_batch(
        dl.book.book_id or dl.book.bookId,
        dl.current.chapter.chapterUid,
        annotation.batches[batch_index]
    )
    self:_perf(dl, "thought_batch", started,
        "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
        "ok=", tostring(ok), "retry=", tostring(annotation.retry))

    if not ok then
        if annotation.retry < 2 then
            annotation.retry = annotation.retry + 1
            self:_setStage(dl,
                T(_("Retrying thoughts %1/%2 · attempt %3"),
                    tostring(batch_index), tostring(batch_total),
                    tostring(annotation.retry)),
                fractional)
            self:_scheduleGuarded(dl,
                function() self:_annotationBatch(dl) end,
                0.6 * annotation.retry)
            return
        end
        dl.annotation_failed_batches = dl.annotation_failed_batches + 1
        logger.warn("thought batch skipped:",
            "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
            "error=", log_error(err or "unknown"))
    elseif result and type(result.reviews) == "table" then
        for _i, review in ipairs(result.reviews) do
            annotation.reviews[#annotation.reviews + 1] = review
        end
    end

    annotation.batch_index = batch_index + 1
    annotation.retry = 0
    self:_scheduleGuarded(dl,
        function() self:_annotationBatch(dl) end, 0.3)
end

function Downloader:_startAnnotations(dl)
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setStage(dl,
        T(_("Downloading underlines · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.85)
    local started = time.now()
    local ok, underlines, ranges, err = Thoughts.fetch_underlines(
        self.client, self.settings, book_id, chapter.chapterUid
    )
    self:_perf(dl, "underlines", started, "ok=", tostring(ok),
        "ranges=", tostring(#(ranges or {})))
    if not ok or type(underlines) ~= "table" then
        logger.warn("skip chapter annotations:", log_error(err or "no data"))
        self:_finishChapter(dl)
        return
    end
    dl.annotation = {
        underlines = underlines,
        reviews = {},
        batches = self.client:build_chapter_review_batches(ranges),
        batch_index = 1,
        retry = 0,
    }
    if #dl.annotation.batches == 0 then
        self:_applyAnnotations(dl)
    else
        self:_scheduleGuarded(dl,
            function() self:_annotationBatch(dl) end, 0.1)
    end
end

-- Fill-missing repack: walk the FULL catalog, taking each chapter's
-- body from this run's downloads or the on-disk parts cache, and merge
-- cached assets with the fresh ones (first href wins; the run re-saves
-- every asset it downloads, so freshness is maintained).
function Downloader:_mergedRepackArgs(dl)
    local bodies = {}
    local selected = {}
    for index, chapter in ipairs(dl.catalog or {}) do
        local uid = tostring(chapter.chapterUid or index)
        local body = dl.bodies[uid]
            or Content.load_chapter_part(self.settings, dl.book, uid)
        if body then
            bodies[uid] = body
            table.insert(selected, chapter)
        end
    end
    local seen_href = {}
    local assets = {}
    for _i, asset in ipairs(Content.load_part_assets(self.settings, dl.book)) do
        if not seen_href[asset.href] then
            seen_href[asset.href] = true
            table.insert(assets, asset)
        end
    end
    for _i, asset in ipairs(dl.assets) do
        if not seen_href[asset.href] then
            seen_href[asset.href] = true
            table.insert(assets, asset)
        end
    end
    local css = dl.state.css or Content.load_parts_css(self.settings, dl.book)
    return selected, bodies, assets, css
end

-- Completion dialog for a partial download: the book is usable, but
-- some chapters are missing. "补齐缺失章节" starts a fill-missing run
-- (re-downloads only the missing chapters and repacks); it shows up
-- again if chapters still fail. Not dismissable, matching the
-- download-confirmation dialog (a stray tap must not drop the choice).
function Downloader:_showIncompleteDialog(dl, path, completion_text)
    local dialog
    dialog = ButtonDialog:new{
        modal = true,
        dismissable = false,
        title = completion_text,
        buttons = {
            {
                {
                    text = _("补齐缺失章节"),
                    callback = function()
                        UIManager:close(dialog)
                        self:start(dl.book, dl.catalog or dl.chapters, dl.suffix, {
                            fill_missing = true,
                            include_comments = dl.include_comments,
                            open_on_complete = dl.open_on_complete,
                            on_complete = dl.on_complete,
                        })
                    end,
                },
                {
                    text = _("Read now"),
                    callback = self.safe_callback(_("Read now"), function()
                        UIManager:close(dialog)
                        self.open_file(path)
                    end),
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    self:_showOverlay(dialog)
end

function Downloader:_step(dl)
    if dl.cancelled then
        self:_releaseStandby(dl)
        self:_notifyCompletion(dl, false, "cancelled")
        self.show_transient(_("Download cancelled"), 2)
        return
    end

    if dl.index > dl.total then
        if #dl.selected == 0 and not dl.fill_missing then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            self:_releaseStandby(dl)
            logger.err("book download failed: no chapters downloaded")
            self:_notifyCompletion(dl, false, "no_chapters_downloaded")
            if not dl.headless then
                self.show_info(_("No chapters were downloaded."))
            end
            return
        end
        self:_setStage(dl, _("Building EPUB..."), dl.total)
        local save_started = time.now()
        local save_chapters, save_bodies, save_assets, save_css =
            dl.selected, dl.bodies, dl.assets, dl.state.css
        if not dl.single_chapter then
            -- Persist the merged CSS for later fill-missing repacks.
            pcall(Content.save_parts_css, self.settings, dl.book, dl.state.css)
        end
        if dl.fill_missing then
            save_chapters, save_bodies, save_assets, save_css =
                self:_mergedRepackArgs(dl)
            if #save_chapters == 0 then
                -- Nothing was downloaded and nothing is cached: the book
                -- is not recoverable from local state (review.md #14).
                if dl.progress_dialog then
                    dl.progress_dialog:close()
                    dl.progress_dialog = nil
                end
                self:_releaseStandby(dl)
                logger.err("book download failed: no chapters downloaded")
                self:_notifyCompletion(dl, false, "no_chapters_downloaded")
                if not dl.headless then
                    self.show_info(_("No chapters were downloaded."))
                end
                return
            end
        end
        local ok, path = pcall(function()
            if dl.single_chapter then
                local chapter = dl.selected[1]
                local uid = tostring(chapter.chapterUid or 1)
                return Content.save_chapter_epub(
                    self.settings, dl.book, chapter, dl.bodies[uid], dl.assets, dl.state.css
                )
            end
            local cover_data
            local cover_url = WeRead.normalize_cover_url(dl.book.cover)
            if cover_url and cover_url ~= "" then
                pcall(function() cover_data = self.client:get_binary(cover_url) end)
            end
            return Content.save_book_epub(
                self.settings, dl.book, save_chapters, save_bodies,
                dl.suffix, save_assets, save_css, cover_data
            )
        end)
        self:_perf(dl, "save_epub", save_started, "ok=", tostring(ok),
            "single=", tostring(dl.single_chapter))
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        self:_releaseStandby(dl)
        local book_id = dl.book.book_id or dl.book.bookId
        if book_id then
            dl.book.cached_chapters = dl.book.cached_chapters or {}
            for ci, ch in ipairs(dl.selected) do
                dl.book.cached_chapters[tostring(ch.chapterUid or ci)] = ok and path or nil
            end
            if ok then
                dl.book.cached_file = path
            end
            dl.book.reader_url = dl.book.reader_url or WeRead.reader_url(book_id)
            dl.download_record = download_record(dl.book)
            -- A headless downloader runs in a forked process. Its book record
            -- is a snapshot from download start, so saving the whole record
            -- here could overwrite reading progress written by the parent in
            -- the meantime. The parent merges only these download fields.
            if not dl.headless then
                self.settings:save_book(tostring(book_id), dl.book)
                self.settings:flush()
            end
        end
        self.refresh_shelf()
        if not ok then
            logger.err("save downloaded book failed:", log_error(path))
            self:_notifyCompletion(dl, false, path)
            if not dl.headless then
                self.show_info(T(_("Download failed:\n%1"), display_error(path)))
            end
            return
        end
        if #dl.failed > 0 then
            logger.warn(
                "book download completed with skipped chapters:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed)
            )
        else
            logger.info("book download completed:", "chapters=", tostring(#dl.selected))
        end
        local completion_text
        if #dl.failed > 0 then
            completion_text = T(
                _("Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"),
                tostring(#dl.selected), tostring(#dl.failed), path
            )
        else
            completion_text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#dl.selected), path)
        end
        if dl.annotation_failed_batches > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."),
                tostring(dl.annotation_failed_batches)
            )
        end
        self:_perf(dl, "download_total", dl.started_at,
            "success_chapters=", tostring(#dl.selected),
            "failed_chapters=", tostring(#dl.failed),
            "failed_thought_batches=", tostring(dl.annotation_failed_batches))
        if #dl.failed == 0 and dl.open_on_complete then
            self.open_file(path)
            self:_notifyCompletion(dl, true, path)
            return
        end
        self:_notifyCompletion(dl, true, path)
        if dl.headless then
            return
        end
        if #dl.failed > 0 then
            -- Incomplete book: offer a fill-missing run (only the failed
            -- chapters are re-downloaded; the rest comes from the parts
            -- cache written during this run).
            self:_showIncompleteDialog(dl, path, completion_text)
            return
        end
        self:_showOverlay(ConfirmBox:new{
            modal = true,
            text = completion_text,
            ok_text = _("Read now"),
            ok_callback = self.safe_callback(_("Read now"), function()
                self.open_file(path)
            end),
            cancel_text = _("Close"),
        })
        return
    end

    local chapter = dl.chapters[dl.index]
    self:_setStage(dl,
        T(_("Downloading chapter %1/%2: %3"), tostring(dl.index), tostring(dl.total),
            chapter.title or tostring(chapter.chapterUid)),
        dl.index - 1)
    local started = time.now()
    local ok, xhtml = pcall(function()
        return Content.fetch_single_chapter_source(
            self.client, self.settings, dl.book, chapter, dl.state
        )
    end)
    self:_perf(dl, "chapter_source", started, "ok=", tostring(ok))
    if not ok then
        self:_failChapter(dl, xhtml)
        return
    end
    dl.current = { chapter = chapter, xhtml = xhtml }
    if dl.include_comments then
        self:_startAnnotations(dl)
    else
        self:_finishChapter(dl)
    end
end

return Downloader
