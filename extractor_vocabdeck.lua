-- Reads VocabDeck's own per-language SQLite databases and turns them into
-- Extractor Records: a stable, content-derived Merge Key plus a set of
-- fields, each carrying its own merge policy and a "changed_at" timestamp
-- this extractor computes itself (see snapshot_store.lua for why).
--
-- This module only reads VocabDeck's data and maintains this extractor's own
-- snapshot file -- it never writes to VocabDeck's database. The writeback
-- half (turning merged records back into VocabDeck rows) and the actual
-- AnnotationSync push call are separate, deliberately deferred pieces --
-- see main.lua.
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local TextUtils = require("vocabdeck_text_utils")

local MemoryHelperParser = require("memory_helper_parser")
local Snapshot = require("snapshot_store")

local Extractor = {}

local DB_DIRECTORY = ffiUtil.joinPath(DataStorage:getDataDir(), "vocabdeck")

-- Mirrors vocabdeck_db.lua's own normalizePhrase() exactly -- this MUST stay
-- byte-for-byte identical to VocabDeck's version, since the Merge Key only
-- works as a stable cross-device identifier if it's computed the same way
-- VocabDeck itself computes normalized_phrase. If VocabDeck ever changes its
-- normalization, this needs to change with it.
local function normalizePhrase(phrase)
    phrase = tostring(phrase or "")
    phrase = phrase:gsub("\194\160", " ") -- NBSP; Lua 5.1 %s doesn't match it
    phrase = phrase:gsub("%s+", " ")
    phrase = TextUtils.trim(phrase)
    return phrase:lower()
end

-- Columns pulled straight from vocabdeck_db.lua's CARD_SELECT_COLUMNS. `id`
-- and `book_id` are deliberately excluded from this list -- both are local
-- autoincrement values with no meaning across devices; normalized_phrase is
-- the only safe Merge Key (see the PR discussion this project's history
-- records: the original vocabdeck-anki-export script's stable_id used the
-- row id and would have silently collided/diverged across devices).
local CARD_COLUMNS = {
    "id", "book_id", "phrase", "sentence", "ai_context", "display_context",
    "pronunciation", "meaning", "synonym", "word_type", "source_language",
    "user_note", "ai_memory_helper", "ai_status", "ai_error", "due",
    "fsrs_state", "fsrs_step", "fsrs_stability", "fsrs_difficulty",
    "last_review", "review_count", "lapse_count", "suspended", "leech",
    "known", "flag", "created_at", "updated_at",
}

-- write_once: correct once set, never meaningfully revised (or if it is,
-- losing the update isn't a real problem -- e.g. display_context is
-- recomputed from settings, not user intent).
-- last_write_wins: the whole point is the *latest* value, not the first --
-- confirmed directly by the user: VocabDeck offers at least two separate
-- "re-enrich" actions, and the freshly re-enriched data is what's supposed
-- to end up synced, not whatever was there originally.
local FIELD_POLICY = {
    phrase = "write_once",
    sentence = "write_once",
    ai_context = "write_once",
    display_context = "write_once",
    created_at = "write_once",
    book_title = "write_once",
    book_filepath = "write_once",

    pronunciation = "last_write_wins",
    meaning = "last_write_wins",
    synonym = "last_write_wins",
    word_type = "last_write_wins",
    source_language = "last_write_wins",
    user_note = "last_write_wins",
    ai_status = "last_write_wins",
    ai_error = "last_write_wins",
    due = "last_write_wins",
    fsrs_state = "last_write_wins",
    fsrs_step = "last_write_wins",
    fsrs_stability = "last_write_wins",
    fsrs_difficulty = "last_write_wins",
    last_review = "last_write_wins",
    review_count = "last_write_wins",
    lapse_count = "last_write_wins",
    suspended = "last_write_wins",
    leech = "last_write_wins",
    known = "last_write_wins",
    flag = "last_write_wins",

    -- Parsed out of ai_memory_helper (see memory_helper_parser.lua). Tagged
    -- last_write_wins, same reasoning as meaning/synonym/etc: "Regenerate"
    -- is a deliberate, intentional update, and last-write-wins is exactly
    -- the right policy for a field that's occasionally intentionally
    -- replaced wholesale.
    morphology = "last_write_wins",
    collocations = "last_write_wins",
    memory_hook = "last_write_wins",
    example_sentence = "last_write_wins",
}
Extractor.FIELD_POLICY = FIELD_POLICY

local function listLanguages()
    local languages = {}
    if not lfs.attributes(DB_DIRECTORY, "mode") then
        return languages
    end
    for file in lfs.dir(DB_DIRECTORY) do
        if file:match("%.sqlite3$") and not file:match("%-backup") and file ~= "vocabdeck.sqlite3" then
            languages[#languages + 1] = file:gsub("%.sqlite3$", "")
        end
    end
    table.sort(languages)
    return languages
end
Extractor.listLanguages = listLanguages

-- Same resultset("hik") convention vocabdeck_db.lua uses: rows[0] holds
-- column-name headers, rows[header_index][row_index] holds values.
local function fetchRows(conn, sql)
    local stmt = conn:prepare(sql)
    local rows = stmt:resultset("hik")
    stmt:close()
    if not rows or not rows[1] then return {} end
    local headers = rows[0]
    local list = {}
    for i = 1, #rows[1] do
        local row = {}
        for header_index, header in ipairs(headers) do
            row[header] = rows[header_index][i]
        end
        list[#list + 1] = row
    end
    return list
end

local function valuesEqual(a, b)
    -- SQLite hands back numbers as numbers and text as strings already, via
    -- lua-ljsqlite3 -- no coercion needed, just compare directly. nil and ""
    -- are treated as the same "no value" for text-ish columns that default
    -- to '' in the schema, so a value that round-trips through nil doesn't
    -- register as a spurious change.
    if a == b then return true end
    if (a == nil or a == "") and (b == nil or b == "") then return true end
    return false
end

-- Diffs one already-fetched card row against this extractor's own memory of
-- it, filling in book_title/book_filepath and the parsed memory-helper
-- sections, and returns the merge key plus a fully-timestamped field table.
-- `language_snapshot` is mutated in place (the caller persists it).
local function buildRecord(row, book_titles, language_snapshot, now)
    local normalized = normalizePhrase(row.phrase)
    if normalized == "" then return nil end

    local previous = language_snapshot[normalized]
    local row_updated_at = tonumber(row.updated_at) or now

    if previous and previous.row_updated_at == row_updated_at then
        -- Cheap gate: VocabDeck's own row-level updated_at hasn't moved
        -- since we last looked, so nothing on this row changed. Re-emit the
        -- stored field snapshot verbatim -- no need to touch any field.
        return { merge_key = normalized, fields = previous.fields }
    end

    local sections = MemoryHelperParser.parse(row.ai_memory_helper)
    local book = book_titles[tonumber(row.book_id)] or {}

    local raw_values = {
        phrase = row.phrase or "",
        sentence = row.sentence or "",
        ai_context = row.ai_context or "",
        display_context = row.display_context or "",
        created_at = tonumber(row.created_at),
        book_title = book.title or "",
        book_filepath = book.filepath or "",

        pronunciation = row.pronunciation or "",
        meaning = row.meaning or "",
        synonym = row.synonym or "",
        word_type = row.word_type or "",
        source_language = row.source_language or "",
        user_note = row.user_note or "",
        ai_status = tonumber(row.ai_status),
        ai_error = row.ai_error or "",
        due = tonumber(row.due),
        fsrs_state = tonumber(row.fsrs_state),
        fsrs_step = tonumber(row.fsrs_step),
        fsrs_stability = tonumber(row.fsrs_stability),
        fsrs_difficulty = tonumber(row.fsrs_difficulty),
        last_review = tonumber(row.last_review),
        review_count = tonumber(row.review_count),
        lapse_count = tonumber(row.lapse_count),
        suspended = tonumber(row.suspended),
        leech = tonumber(row.leech),
        known = tonumber(row.known),
        flag = tonumber(row.flag),

        morphology = sections.morphology,
        collocations = sections.collocations,
        memory_hook = sections.memory_hook,
        example_sentence = sections.example_sentence,
    }

    local fields = {}
    local previous_fields = previous and previous.fields or {}
    for name, policy in pairs(FIELD_POLICY) do
        local value = raw_values[name]
        local old_entry = previous_fields[name]
        local changed_at
        if old_entry and valuesEqual(old_entry.value, value) then
            changed_at = old_entry.changed_at
        else
            changed_at = now
        end
        fields[name] = { value = value, policy = policy, changed_at = changed_at }
    end

    language_snapshot[normalized] = { row_updated_at = row_updated_at, fields = fields }
    return { merge_key = normalized, fields = fields }
end

-- Extracts every card in one language's database as Extractor Records.
-- Returns the record list; the caller (main.lua, eventually AnnotationSync)
-- treats each language as its own independently-synced "file", matching
-- pushExtractorData's per-file namespacing.
function Extractor.extractLanguage(language)
    local db_path = ffiUtil.joinPath(DB_DIRECTORY, language .. ".sqlite3")
    if not lfs.attributes(db_path, "mode") then
        return {}, "No database for language: " .. tostring(language)
    end

    local conn = SQ3.open(db_path)
    local ok, result = pcall(function()
        local book_titles = {}
        for _, row in ipairs(fetchRows(conn, "SELECT id, title, filepath FROM books;")) do
            book_titles[tonumber(row.id)] = { title = row.title, filepath = row.filepath }
        end

        local now = os.time()
        local language_snapshot = Snapshot.forLanguage(language)
        local records = {}
        for _, row in ipairs(fetchRows(conn, "SELECT " .. table.concat(CARD_COLUMNS, ", ") .. " FROM cards;")) do
            local record = buildRecord(row, book_titles, language_snapshot, now)
            if record then
                records[#records + 1] = record
            end
        end
        Snapshot.saveForLanguage(language, language_snapshot)
        return records
    end)
    conn:close()

    if not ok then
        return {}, tostring(result)
    end
    return result
end

-- Extracts every installed language. Returns { [language] = records }.
function Extractor.extractAll()
    local by_language = {}
    for _, language in ipairs(listLanguages()) do
        local records, err = Extractor.extractLanguage(language)
        if err then
            by_language[language] = { error = err }
        else
            by_language[language] = records
        end
    end
    Snapshot.flush()
    return by_language
end

return Extractor
