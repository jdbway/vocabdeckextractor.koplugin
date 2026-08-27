-- VocabDeck Extractor plugin entry point.
--
-- This is the first "Extractor" built against AnnotationSync's proposed
-- Extractor interface (see AnnotationSync.koplugin#93). It reads VocabDeck's
-- own SQLite databases directly -- it does not require VocabDeck's plugin
-- code to be loaded or even installed as a *running* plugin, only that its
-- data files exist on disk, since extraction only ever reads files VocabDeck
-- itself already writes.
--
-- Status: the read/diff/snapshot half (this plugin's actual job) is real and
-- testable today. The push-to-AnnotationSync half is a stub -- as of this
-- writing, AnnotationSync.koplugin has no pushExtractorData implementation
-- to call, no broadcast event to listen for, and no writeback_fn contract
-- defined yet. See onPushToAnnotationSync() below for exactly what's
-- deferred and why.
local _ = require("gettext")
local DataStorage = require("datastorage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local dump = require("dump")

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

-- Deliberately not implemented yet -- see the header comment. Once
-- AnnotationSync.koplugin#93 settles on pushExtractorData's real signature,
-- this becomes: for each language, call
-- AnnotationSync.pushExtractorData("vocabdeck", language, records, writeback_fn),
-- where writeback_fn takes the merged records back and writes any
-- last_write_wins fields into this language's cards table by merge_key.
-- Everything upstream of that call (extraction, diffing, per-field
-- timestamps) is already real; only this adapter is pending.
function VocabDeckExtractor:onPushToAnnotationSync()
    UIManager:show(InfoMessage:new{
        text = _("Not implemented yet: AnnotationSync doesn't have a pushExtractorData interface to call. See AnnotationSync.koplugin issue #93."),
        timeout = 5,
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
