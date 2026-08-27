-- Persists this extractor's own memory of "what did I last report for each
-- field," entirely separate from VocabDeck's database.
--
-- VocabDeck only tracks one updated_at per card row, not per field, so it
-- can't tell a sync layer which specific field changed since the last sync
-- -- only that *something* on the row did. This store lets the extractor
-- synthesize accurate per-field "changed_at" timestamps anyway: each row
-- carries the row's own updated_at (a cheap gate -- unchanged means nothing
-- on that row needs re-checking) plus, per field, the last value seen and
-- the timestamp it was first seen at that value. A field whose value hasn't
-- actually changed keeps its old timestamp even when the row around it did.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local SNAPSHOT_FILE = DataStorage:getSettingsDir() .. "/vocabdeckextractor_snapshot.lua"

local Snapshot = {}

local settings

local function ensureOpen()
    if not settings then
        settings = LuaSettings:open(SNAPSHOT_FILE)
    end
    return settings
end

-- Returns the stored snapshot table for one language ({} if none yet).
-- Shape: { [normalized_phrase] = { row_updated_at = N, fields = { [name] = { value = v, changed_at = N } } } }
function Snapshot.forLanguage(language)
    return ensureOpen():readSetting(language) or {}
end

function Snapshot.saveForLanguage(language, language_snapshot)
    ensureOpen():saveSetting(language, language_snapshot)
end

function Snapshot.flush()
    if settings then
        settings:flush()
    end
end

return Snapshot
