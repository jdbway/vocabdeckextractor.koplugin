-- VocabDeck Extractor plugin entry point.
--
-- This is the first "Extractor" built against AnnotationSync's Extractor
-- interface (see AnnotationSync.koplugin#93 and its
-- docs/writing-an-extractor.md). It reads VocabDeck's own SQLite databases
-- directly -- it does not require VocabDeck's plugin code to be loaded or
-- even installed as a *running* plugin, only that its data files exist on
-- disk, since extraction only ever reads files VocabDeck itself already
-- writes.
--
-- Status: extraction, the sync-event hook, and the real pushExtractorData
-- call are all live. writeback_fn (turning merged records back into
-- VocabDeck rows -- the only way a card created on another device shows up
-- here) is still a stub -- see stubWriteback() below.
local _ = require("gettext")
local DataStorage = require("datastorage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local dump = require("dump")
local PluginShare = require("pluginshare")

local Extractor = require("extractor_vocabdeck")

local VOCABDECK_DATA_DIR = ffiUtil.joinPath(DataStorage:getDataDir(), "vocabdeck")

local VocabDeckExtractor = InputContainer:extend{
    name = "vocabdeckextractor",
    is_doc_only = false,
}

local function vocabDeckDataExists()
    return lfs.attributes(VOCABDECK_DATA_DIR, "mode") ~= nil
end

local function summarize(by_language)
    local lines = {}
    local total_cards, total_errors = 0, 0
    for language, records in pairs(by_language) do
        if records.error then
            lines[#lines + 1] = string.format("%s: error -- %s", language, records.error)
            total_errors = total_errors + 1
        else
            lines[#lines + 1] = string.format("%s: %d cards", language, #records)
            total_cards = total_cards + #records
        end
    end
    table.sort(lines)
    table.insert(lines, 1, string.format("%d cards across %d language(s)%s",
        total_cards, #lines - (total_errors > 0 and 1 or 0),
        total_errors > 0 and (", " .. total_errors .. " error(s)") or ""))
    return table.concat(lines, "\n")
end

-- Debug entry point: run the real extraction/diff/snapshot pipeline and show
-- what it found. This is the only way to exercise the extractor today,
-- since there's no AnnotationSync sync event to trigger it yet.
function VocabDeckExtractor:runExtractionDebug()
    local ok, by_language = pcall(Extractor.extractAll)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Extraction failed:\n%s"), tostring(by_language)),
            timeout = 6,
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = summarize(by_language),
        timeout = 8,
    })
end

-- Dumps the full extracted record set (not just the summary) to a plain Lua
-- table literal on disk, for inspection outside the UI (e.g. over SSH) while
-- there's no real consumer of this data yet.
function VocabDeckExtractor:dumpExtractionToFile()
    local ok, by_language = pcall(Extractor.extractAll)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Extraction failed:\n%s"), tostring(by_language)),
            timeout = 6,
        })
        return
    end
    local path = DataStorage:getDataDir() .. "/vocabdeckextractor_dump.lua"
    local file = io.open(path, "w")
    if not file then
        UIManager:show(InfoMessage:new{ text = _("Could not open dump file for writing."), timeout = 4 })
        return
    end
    file:write("return ", dump(by_language), "\n")
    file:close()
    UIManager:show(InfoMessage:new{
        text = string.format(_("Wrote extraction dump to:\n%s"), path),
        timeout = 6,
    })
end

-- Not built yet -- next task. pushExtractorData always calls this, whether
-- or not anything actually changed (see AnnotationSync's extractor_push.lua)
-- so it's safe to call unconditionally; it just doesn't persist anything
-- into VocabDeck's own database yet. The real version needs to: for each
-- entry in merged_records, insert a new row if normalized_phrase isn't
-- already local (that's how a card added on another device appears here),
-- otherwise update only the last_write_wins fields on the existing row --
-- write_once fields on a row that already exists locally never need
-- touching, since nothing could have legitimately overwritten them.
local function stubWriteback(language, merged_records)
    logger.info("vocabdeckextractor: writeback stub for", language,
        "-- got", #merged_records, "merged record(s), not yet persisted")
end

-- One pushExtractorData call per language, matching this Extractor's
-- <extractor_id>/<filename> namespacing (filename = language).
function VocabDeckExtractor:pushLanguage(language)
    local records, err = Extractor.extractLanguage(language)
    if err then
        logger.warn("vocabdeckextractor: extraction failed for", language, "--", err)
        return
    end
    PluginShare.AnnotationSync.pushExtractorData("vocabdeck", language, records, function(merged_records)
        stubWriteback(language, merged_records)
    end)
end

function VocabDeckExtractor:pushAll()
    for _, language in ipairs(Extractor.listLanguages()) do
        self:pushLanguage(language)
    end
end

-- AnnotationSyncRequested fires once per sync episode (manual "Sync Now" or
-- a background reconnect), not per document -- correct here, since neither
-- VocabDeck's cards nor the notebook log belong to any one book.
function VocabDeckExtractor:onAnnotationSyncRequested()
    if not PluginShare.AnnotationSync then return end
    self:pushAll()
end

-- Manual trigger, kept alongside the automatic event hook above -- useful
-- for testing without waiting for a real sync episode.
function VocabDeckExtractor:onPushToAnnotationSync()
    if not PluginShare.AnnotationSync then
        UIManager:show(InfoMessage:new{
            text = _("AnnotationSync isn't installed or enabled."),
            timeout = 4,
        })
        return
    end
    self:pushAll()
    UIManager:show(InfoMessage:new{
        text = _("Push started. writeback isn't implemented yet, so nothing will be written back locally -- check the log for what came back."),
        timeout = 6,
    })
end

function VocabDeckExtractor:addToMainMenu(menu_items)
    if not vocabDeckDataExists() then
        return
    end
    menu_items.vocabdeckextractor = {
        sorting_hint = "tools",
        text = _("VocabDeck Extractor"),
        sub_item_table = {
            {
                text = _("Extract now (debug)"),
                keep_menu_open = true,
                callback = function() self:runExtractionDebug() end,
            },
            {
                text = _("Dump extraction to file (debug)"),
                keep_menu_open = true,
                callback = function() self:dumpExtractionToFile() end,
            },
            {
                text = _("Push to AnnotationSync"),
                keep_menu_open = true,
                callback = function() self:onPushToAnnotationSync() end,
            },
        },
    }
end

function VocabDeckExtractor:init()
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

return VocabDeckExtractor
