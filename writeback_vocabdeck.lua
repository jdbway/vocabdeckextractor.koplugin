-- Applies AnnotationSync's merged VocabDeck records back into VocabDeck's
-- own per-language SQLite database -- the other half of extractor_vocabdeck's
-- read pipeline. See ARCHITECTURE.md for why this also has to update this
-- extractor's own snapshot memory (snapshot_store.lua), not just the DB.
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Snapshot = require("snapshot_store")
local MemoryHelperParser = require("memory_helper_parser")

local DB_DIRECTORY = ffiUtil.joinPath(DataStorage:getDataDir(), "vocabdeck")

local Writeback = {}

-- Inverse of memory_helper_parser.lua's parse() -- must stay byte-compatible
-- with vocabdeck_memory_helper.lua's cleanText(), which is the canonical
-- format actually stored in the ai_memory_helper column: each present
-- section as "Label: content", joined by exactly one blank line, empty
-- sections omitted entirely (never emitted as "Label:" with no content).
local MEMORY_SECTIONS = {
    { key = "morphology", label = "Morphology" },
    { key = "collocations", label = "Collocations" },
    { key = "memory_hook", label = "Memory hook" },
    { key = "example_sentence", label = "Example" },
}

local function serializeMemoryHelper(fields)
    local parts = {}
    for _, section in ipairs(MEMORY_SECTIONS) do
        local field = fields[section.key]
        local value = field and field.value
        if value and value ~= "" then
            parts[#parts + 1] = section.label .. ": " .. value
        end
    end
    return table.concat(parts, "\n\n")
end

local function fieldValue(fields, name, default)
    local field = fields[name]
    if field == nil or field.value == nil then return default end
    return field.value
end

local function findCardId(conn, normalized)
    local stmt = conn:prepare("SELECT id FROM cards WHERE normalized_phrase = ? LIMIT 1;")
    stmt:bind(normalized)
    local row = stmt:step()
    stmt:close()
    return row and tonumber(row[1]) or nil
end

-- Mirrors vocabdeck_db.lua's own DB.getOrCreateBook find-or-create shape,
-- reimplemented locally rather than requiring vocabdeck_db.lua directly --
-- same reasoning as extractor_vocabdeck.lua's own direct-SQLite-access
-- design: writeback shouldn't require VocabDeck to be a currently-loaded
-- plugin, only that its data files exist.
local function getOrCreateBookId(conn, title, filepath, source_language)
    if not filepath or filepath == "" then return nil end
    local stmt = conn:prepare("SELECT id FROM books WHERE filepath = ? LIMIT 1;")
    stmt:bind(filepath)
    local row = stmt:step()
    stmt:close()
    if row then
        return tonumber(row[1])
    end
    local insert = conn:prepare("INSERT INTO books (title, filepath, source_language) VALUES (?, ?, ?);")
    insert:bind(title or "", filepath, source_language or "")
    insert:step()
    insert:close()
    local new_id = conn:rowexec("SELECT last_insert_rowid();")
    return new_id and tonumber(new_id) or nil
end

-- Exactly FIELD_POLICY's last_write_wins columns (extractor_vocabdeck.lua) --
-- write_once fields on a card that already exists locally are never
-- legitimately different, since keyed_merge.lua never overwrites them either.
local UPDATE_COLUMNS = {
    "pronunciation", "meaning", "synonym", "word_type", "source_language",
    "user_note", "ai_status", "ai_error", "due", "fsrs_state", "fsrs_step",
    "fsrs_stability", "fsrs_difficulty", "last_review", "review_count",
    "lapse_count", "suspended", "leech", "known", "flag",
}

-- Reads the current row's UPDATE_COLUMNS + ai_memory_helper, keyed the same
-- way fieldValue() reads a merged record, so the two can be compared
-- directly field-by-field.
local function readCurrentRow(conn, card_id)
    local sql = "SELECT " .. table.concat(UPDATE_COLUMNS, ", ") .. ", ai_memory_helper FROM cards WHERE id = ?;"
    local stmt = conn:prepare(sql)
    stmt:bind(card_id)
    local row = stmt:step()
    stmt:close()
    local current = {}
    for i, name in ipairs(UPDATE_COLUMNS) do
        current[name] = row[i]
    end
    current.ai_memory_helper = row[#UPDATE_COLUMNS + 1]
    return current
end

-- true if applying `fields` to this card would actually change anything --
-- comparing against the LIVE row (not the snapshot) so a card edited
-- directly (outside this extractor's own tracking) doesn't get silently
-- skipped just because the snapshot thinks it already matches.
local function valuesEqual(a, b)
    if a == b then return true end
    if (a == nil or a == "") and (b == nil or b == "") then return true end
    return false
end

-- Compares ai_memory_helper by its PARSED sections, not raw bytes: the same
-- four values can legitimately be stored as "Label: content" or
-- "Label:\ncontent" (the AI's own response formatting varies), and
-- memory_helper_parser.lua already treats those as identical -- a raw byte
-- comparison here would flag a real, unchanged card as "different" on every
-- push forever, purely from re-normalizing formatting that was never
-- semantically meaningful.
local function memoryHelperEqual(current_raw, fields)
    local current_sections = MemoryHelperParser.parse(current_raw)
    for _, section in ipairs(MEMORY_SECTIONS) do
        if not valuesEqual(current_sections[section.key], fieldValue(fields, section.key, "")) then
            return false
        end
    end
    return true
end

local function needsUpdate(current, fields)
    for _, name in ipairs(UPDATE_COLUMNS) do
        if not valuesEqual(current[name], fieldValue(fields, name, nil)) then
            return true
        end
    end
    return not memoryHelperEqual(current.ai_memory_helper, fields)
end

-- Builds bind values with an explicit count rather than relying on
-- table length/unpack -- last_review is a genuine nullable INTEGER column
-- (never-reviewed cards store real SQL NULL, not 0), and a Lua nil in the
-- middle of a table breaks `#`/plain unpack. bind()'s own varargs handling
-- (select("#", ...)) copes with nils fine as long as we don't route them
-- through a length-counted table first.
--
-- Only called when needsUpdate() already found a real difference -- writing
-- (and bumping updated_at / the snapshot) on every push regardless would
-- churn every card on every no-op sync and re-stamp changed_at on fields
-- that never actually changed, exactly the timestamp-laundering problem
-- ARCHITECTURE.md warns about.
local function updateCard(conn, card_id, fields, target_memory_helper, now)
    local set_clauses = {}
    local values = {}
    local n = 0
    for _, name in ipairs(UPDATE_COLUMNS) do
        set_clauses[#set_clauses + 1] = name .. " = ?"
        n = n + 1
        values[n] = fieldValue(fields, name, nil)
    end
    set_clauses[#set_clauses + 1] = "ai_memory_helper = ?"
    n = n + 1
    values[n] = target_memory_helper
    set_clauses[#set_clauses + 1] = "updated_at = ?"
    n = n + 1
    values[n] = now

    local sql = "UPDATE cards SET " .. table.concat(set_clauses, ", ") .. " WHERE id = ?;"
    n = n + 1
    values[n] = card_id
    local stmt = conn:prepare(sql)
    stmt:bind(unpack(values, 1, n))
    stmt:step()
    stmt:close()
end

-- A card arriving from another device carries its own real review/enrichment
-- progress (last_write_wins fields) -- deliberately NOT the same as
-- vocabdeck_db.lua's own DB.addCard(), which only sets identity fields and
-- lets fresh-card scheduling defaults apply, since that's for a card a user
-- is creating right now on *this* device, not one merging in from elsewhere.
local function insertCard(conn, normalized, fields, now)
    local book_id = getOrCreateBookId(
        conn,
        fieldValue(fields, "book_title", ""),
        fieldValue(fields, "book_filepath", ""),
        fieldValue(fields, "source_language", "")
    )
    if not book_id then
        return false, "no book_filepath on incoming record for " .. tostring(normalized)
    end

    local sql = [[INSERT INTO cards
        (book_id, phrase, normalized_phrase, sentence, ai_context, display_context,
         pronunciation, meaning, synonym, word_type, source_language, user_note,
         ai_memory_helper, ai_status, ai_error, due, fsrs_state, fsrs_step,
         fsrs_stability, fsrs_difficulty, last_review, review_count, lapse_count,
         suspended, leech, known, flag, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]]
    local values = {
        book_id,
        fieldValue(fields, "phrase", ""),
        normalized,
        fieldValue(fields, "sentence", ""),
        fieldValue(fields, "ai_context", ""),
        fieldValue(fields, "display_context", ""),
        fieldValue(fields, "pronunciation", ""),
        fieldValue(fields, "meaning", ""),
        fieldValue(fields, "synonym", ""),
        fieldValue(fields, "word_type", ""),
        fieldValue(fields, "source_language", ""),
        fieldValue(fields, "user_note", ""),
        serializeMemoryHelper(fields),
        fieldValue(fields, "ai_status", 0),
        fieldValue(fields, "ai_error", ""),
        fieldValue(fields, "due", now),
        fieldValue(fields, "fsrs_state", 1),
        fieldValue(fields, "fsrs_step", 0),
        fieldValue(fields, "fsrs_stability", 0),
        fieldValue(fields, "fsrs_difficulty", 0),
        fieldValue(fields, "last_review", nil),
        fieldValue(fields, "review_count", 0),
        fieldValue(fields, "lapse_count", 0),
        fieldValue(fields, "suspended", 0),
        fieldValue(fields, "leech", 0),
        fieldValue(fields, "known", 0),
        fieldValue(fields, "flag", 0),
        fieldValue(fields, "created_at", now),
        now,
    }
    local stmt = conn:prepare(sql)
    stmt:bind(unpack(values, 1, 29))
    stmt:step()
    stmt:close()
    return true
end

-- Applies merged_records into `language`'s database, touching only rows that
-- actually differ from what's already there, and updates this extractor's
-- own snapshot memory for exactly the rows it touched -- so the next
-- extraction's coarse gate (row_updated_at) sees untouched rows as
-- unchanged, and per-field diffing preserves each field's real origin
-- changed_at instead of re-stamping it at next-extraction time. A push
-- against an empty/unchanged remote (the common case) should be a total
-- no-op here, not a churn of every card's updated_at.
function Writeback.apply(language, merged_records)
    if not merged_records or #merged_records == 0 then return end

    local db_path = ffiUtil.joinPath(DB_DIRECTORY, language .. ".sqlite3")
    if not lfs.attributes(db_path, "mode") then
        logger.warn("vocabdeckextractor: writeback skipped, no database for", language)
        return
    end

    local conn = SQ3.open(db_path)
    local now = os.time()
    local language_snapshot = Snapshot.forLanguage(language)
    local touched = false

    local ok, err = pcall(function()
        conn:exec("BEGIN;")
        for _, record in ipairs(merged_records) do
            local normalized = record.merge_key
            local fields = record.fields
            local card_id = findCardId(conn, normalized)
            if card_id then
                local current = readCurrentRow(conn, card_id)
                if needsUpdate(current, fields) then
                    updateCard(conn, card_id, fields, serializeMemoryHelper(fields), now)
                    language_snapshot[normalized] = { row_updated_at = now, fields = fields }
                    touched = true
                end
            else
                local inserted, insert_err = insertCard(conn, normalized, fields, now)
                if inserted then
                    language_snapshot[normalized] = { row_updated_at = now, fields = fields }
                    touched = true
                else
                    logger.warn("vocabdeckextractor: writeback insert skipped:", insert_err)
                end
            end
        end
        conn:exec("COMMIT;")
    end)

    if not ok then
        pcall(function() conn:exec("ROLLBACK;") end)
        logger.warn("vocabdeckextractor: writeback failed for", language, "--", tostring(err))
    elseif touched then
        Snapshot.saveForLanguage(language, language_snapshot)
        Snapshot.flush()
    end

    conn:close()
end

return Writeback
