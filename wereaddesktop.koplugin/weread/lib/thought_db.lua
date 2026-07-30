--[[--
Normalized SQLite thought storage for the WeRead KOReader plugin.

One database per book directory: {book_dir}/thoughts.db

Each pageReview is stored as one row. Tapping an underline performs a single
indexed lookup by (chapter_uid, range), without decoding JSON or rendering HTML.
--]]--

local logger = require("weread.lib.logger")

local ThoughtDB = {}

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if ok and SQ3 then
        return SQ3
    end
    return nil
end

--- Delete thoughts.db and WAL/SHM sidecars. Missing files are ignored.
function ThoughtDB.remove_db(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then
        return false
    end
    for _, path in ipairs({
        book_dir .. "/thoughts.db",
        book_dir .. "/thoughts.db-wal",
        book_dir .. "/thoughts.db-shm",
    }) do
        os.remove(path)
    end
    return true
end

--- Open or create the per-book thought database.
function ThoughtDB.open(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then
        return nil
    end

    local SQ3 = getSQ3()
    if not SQ3 then
        logger.warn("thought_db lua-ljsqlite3 unavailable")
        return nil
    end

    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(book_dir)
    local db_path = book_dir .. "/thoughts.db"

    local ok, db = pcall(SQ3.open, db_path)
    if not ok or not db then
        logger.warn("thought_db open failed:", db_path, db)
        return nil
    end

    pcall(function() db:exec("PRAGMA journal_mode=WAL") end)
    pcall(function() db:exec("PRAGMA synchronous=NORMAL") end)

    local schema_ok, schema_err = pcall(function()
        -- Development-only predecessor; this format was never released.
        db:exec("DROP TABLE IF EXISTS reviews")
        db:exec([[
            CREATE TABLE IF NOT EXISTS review_items (
                chapter_uid INTEGER NOT NULL,
                range       TEXT    NOT NULL,
                item_index  INTEGER NOT NULL,
                abstract    TEXT,
                author      TEXT    NOT NULL,
                content     TEXT    NOT NULL,
                likes_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (chapter_uid, range, item_index)
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS review_ranges (
                chapter_uid INTEGER NOT NULL,
                range       TEXT    NOT NULL,
                fetched_at  INTEGER NOT NULL,
                max_idx     INTEGER NOT NULL DEFAULT 0,
                sync_key    INTEGER NOT NULL DEFAULT 0,
                total_count INTEGER NOT NULL DEFAULT 0,
                has_more    INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (chapter_uid, range)
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS book_review_items (
                item_index  INTEGER NOT NULL PRIMARY KEY,
                review_id   TEXT    NOT NULL UNIQUE,
                author      TEXT    NOT NULL,
                content     TEXT    NOT NULL,
                rating      INTEGER NOT NULL DEFAULT 0,
                likes_count INTEGER NOT NULL DEFAULT 0,
                created_at  INTEGER NOT NULL DEFAULT 0
            )
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS book_review_state (
                id          INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
                fetched_at  INTEGER NOT NULL,
                max_idx     INTEGER NOT NULL DEFAULT 0,
                sync_key    INTEGER NOT NULL DEFAULT 0,
                total_count INTEGER NOT NULL DEFAULT 0,
                has_more    INTEGER NOT NULL DEFAULT 0
            )
        ]])
    end)
    if not schema_ok then
        logger.warn("thought_db schema init failed:", db_path, schema_err)
        pcall(function() db:close() end)
        return nil
    end

    logger.info("thought_db opened", db_path)
    return db
end

local function insert_range_items(db, chapter_uid, range_str, range_review, start_index)
    local Annotations = require("weread.lib.annotations")
    local items = Annotations.buildThoughtPopupItems(range_review)
    if #items == 0 then
        return 0
    end
    local insert_stmt = db:prepare([[
        INSERT OR REPLACE INTO review_items
            (chapter_uid, range, item_index, abstract, author, content, likes_count)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]])
    for offset, item in ipairs(items) do
        insert_stmt:reset():bind(
            chapter_uid, range_str, start_index + offset,
            item.abstract, item.author, item.content, item.likes_count
        ):step()
    end
    insert_stmt:close()
    return #items
end

local function insert_reviews(db, chapter_uid, reviews)
    local Annotations = require("weread.lib.annotations")
    local insert_stmt = db:prepare([[
        INSERT INTO review_items
            (chapter_uid, range, item_index, abstract, author, content, likes_count)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]])

    local by_range = {}
    local range_order = {}
    for _, review in ipairs(reviews) do
        local range_str = type(review) == "table" and review.range or nil
        if type(range_str) == "string" and range_str ~= "" then
            if not by_range[range_str] then
                range_order[#range_order + 1] = range_str
            end
            by_range[range_str] = review
        end
    end

    local inserted = 0
    for _, range_str in ipairs(range_order) do
        local items = Annotations.buildThoughtPopupItems(by_range[range_str])
        for item_index, item in ipairs(items) do
            insert_stmt:reset():bind(
                chapter_uid, range_str, item_index,
                item.abstract, item.author, item.content, item.likes_count
            ):step()
            inserted = inserted + 1
        end
    end
    insert_stmt:close()
    return inserted
end

--- Replace all thought rows for one chapter in a single transaction.
function ThoughtDB.putReviews(db, chapter_uid, reviews)
    if not db or type(reviews) ~= "table" then return false end

    local transaction_open = false
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true

        local delete_stmt = db:prepare(
            "DELETE FROM review_items WHERE chapter_uid=?"
        )
        delete_stmt:reset():bind(chapter_uid):step()
        delete_stmt:close()

        insert_reviews(db, chapter_uid, reviews)

        db:exec("COMMIT")
        transaction_open = false
    end)

    if not ok then
        if transaction_open then
            pcall(function() db:exec("ROLLBACK") end)
        end
        logger.warn("thought_db chapter write failed:",
            "chapter_uid=", tostring(chapter_uid), "error=", tostring(err))
        return false
    end

    logger.info("thought_db written chapter_uid=", chapter_uid,
        " ranges=", #reviews)
    return true
end

--- Cache one lazily fetched thought range.
-- opts.append keeps the existing first page when "load more" is requested.
function ThoughtDB.putRange(db, chapter_uid, range_review, opts)
    local range_str = type(range_review) == "table" and range_review.range
    if not db or type(range_str) ~= "string" or range_str == "" then
        return false
    end
    opts = opts or {}

    local transaction_open = false
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true

        local start_index = 0
        if opts.append then
            local max_stmt = db:prepare([[
                SELECT COALESCE(MAX(item_index), 0)
                FROM review_items WHERE chapter_uid=? AND range=?
            ]])
            local row = max_stmt:reset():bind(chapter_uid, range_str):step()
            start_index = row and tonumber(row[1]) or 0
            max_stmt:close()
        else
            local delete_stmt = db:prepare(
                "DELETE FROM review_items WHERE chapter_uid=? AND range=?"
            )
            delete_stmt:reset():bind(chapter_uid, range_str):step()
            delete_stmt:close()
        end

        insert_range_items(
            db, chapter_uid, range_str, range_review, start_index
        )
        local metadata_stmt = db:prepare([[
            INSERT OR REPLACE INTO review_ranges
                (chapter_uid, range, fetched_at, max_idx, sync_key,
                 total_count, has_more)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ]])
        metadata_stmt:reset():bind(
            chapter_uid,
            range_str,
            tonumber(opts.fetched_at) or os.time(),
            tonumber(range_review.maxIdx) or 0,
            tonumber(range_review.synckey) or 0,
            tonumber(range_review.totalCount) or 0,
            (range_review.hasMore == true
                or tonumber(range_review.hasMore) == 1) and 1 or 0
        ):step()
        metadata_stmt:close()

        db:exec("COMMIT")
        transaction_open = false
    end)
    if not ok then
        if transaction_open then
            pcall(function() db:exec("ROLLBACK") end)
        end
        logger.warn("thought_db range write failed:",
            "chapter_uid=", tostring(chapter_uid),
            "range=", range_str, "error=", tostring(err))
        return false
    end
    logger.info("thought_db range written:",
        "chapter_uid=", tostring(chapter_uid), "range=", range_str,
        "append=", tostring(opts.append == true))
    return true
end

--- Read one range with an indexed lookup.
-- Returns nil only when neither metadata nor cached comment rows exist.
function ThoughtDB.getRange(db, chapter_uid, range_str)
    if not db or type(range_str) ~= "string" or range_str == "" then
        return nil
    end
    local result = { items = {} }
    local metadata_stmt = db:prepare([[
        SELECT fetched_at, max_idx, sync_key, total_count, has_more
        FROM review_ranges WHERE chapter_uid=? AND range=?
    ]])
    local metadata = metadata_stmt:reset():bind(
        chapter_uid, range_str
    ):step()
    metadata_stmt:close()
    if metadata then
        result.fetched_at = tonumber(metadata[1]) or 0
        result.max_idx = tonumber(metadata[2]) or 0
        result.sync_key = tonumber(metadata[3]) or 0
        result.total_count = tonumber(metadata[4]) or 0
        result.has_more = tonumber(metadata[5]) == 1
    end

    local items_stmt = db:prepare([[
        SELECT abstract, author, content, likes_count
        FROM review_items
        WHERE chapter_uid=? AND range=?
        ORDER BY item_index ASC
    ]])
    items_stmt:reset():bind(chapter_uid, range_str)
    while true do
        local row = items_stmt:step()
        if not row then
            break
        end
        result.items[#result.items + 1] = {
            abstract = row[1],
            author = tostring(row[2] or "匿名"),
            content = tostring(row[3] or ""),
            likes_count = tonumber(row[4]) or 0,
        }
    end
    items_stmt:close()

    if not metadata and #result.items == 0 then
        return nil
    end
    return result
end

--- Cache one page of normalized whole-book reviews.
function ThoughtDB.putBookReviews(db, page, opts)
    if not db or type(page) ~= "table" or type(page.items) ~= "table" then
        return false
    end
    opts = opts or {}
    local transaction_open = false
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        if not opts.append then
            db:exec("DELETE FROM book_review_items")
        end

        local insert_stmt = db:prepare([[
            INSERT OR IGNORE INTO book_review_items
                (item_index, review_id, author, content, rating,
                 likes_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ]])
        for sequence, item in ipairs(page.items) do
            insert_stmt:reset():bind(
                tonumber(item.item_index) or sequence,
                tostring(item.review_id or ("idx-" .. tostring(sequence))),
                tostring(item.author or "匿名"),
                tostring(item.content or ""),
                tonumber(item.rating) or 0,
                tonumber(item.likes_count) or 0,
                tonumber(item.created_at) or 0
            ):step()
        end
        insert_stmt:close()

        local state_stmt = db:prepare([[
            INSERT OR REPLACE INTO book_review_state
                (id, fetched_at, max_idx, sync_key, total_count, has_more)
            VALUES (1, ?, ?, ?, ?, ?)
        ]])
        state_stmt:reset():bind(
            tonumber(opts.fetched_at) or os.time(),
            tonumber(page.max_idx) or 0,
            tonumber(page.sync_key) or 0,
            tonumber(page.total_count) or 0,
            page.has_more == true and 1 or 0
        ):step()
        state_stmt:close()

        db:exec("COMMIT")
        transaction_open = false
    end)
    if not ok then
        if transaction_open then
            pcall(function() db:exec("ROLLBACK") end)
        end
        logger.warn("thought_db book reviews write failed:",
            "error=", tostring(err))
        return false
    end
    logger.info("thought_db book reviews written:",
        "items=", tostring(#page.items),
        "append=", tostring(opts.append == true))
    return true
end

--- Read the cached whole-book review list and its pagination cursor.
function ThoughtDB.getBookReviews(db)
    if not db then
        return nil
    end
    local state_stmt = db:prepare([[
        SELECT fetched_at, max_idx, sync_key, total_count, has_more
        FROM book_review_state WHERE id=1
    ]])
    local state = state_stmt:step()
    state_stmt:close()

    local result = { items = {} }
    if state then
        result.fetched_at = tonumber(state[1]) or 0
        result.max_idx = tonumber(state[2]) or 0
        result.sync_key = tonumber(state[3]) or 0
        result.total_count = tonumber(state[4]) or 0
        result.has_more = tonumber(state[5]) == 1
    end

    local items_stmt = db:prepare([[
        SELECT item_index, review_id, author, content, rating,
               likes_count, created_at
        FROM book_review_items ORDER BY item_index ASC
    ]])
    while true do
        local row = items_stmt:step()
        if not row then
            break
        end
        result.items[#result.items + 1] = {
            item_index = tonumber(row[1]) or 0,
            review_id = tostring(row[2] or ""),
            author = tostring(row[3] or "匿名"),
            content = tostring(row[4] or ""),
            rating = tonumber(row[5]) or 0,
            likes_count = tonumber(row[6]) or 0,
            created_at = tonumber(row[7]) or 0,
        }
    end
    items_stmt:close()
    if not state and #result.items == 0 then
        return nil
    end
    return result
end

--- Close the database handle.
function ThoughtDB.close(db)
    if db then
        pcall(function() db:close() end)
    end
end

return ThoughtDB
