-- Behavioral compatibility test.
--
-- Unlike compat/vocabdeck/pin.json's source-diff check (does upstream's
-- FILE still look the same?), this exercises the REAL upstream
-- vocabdeck_db.lua to create a card exactly the way VocabDeck itself would
-- (DB.setLanguage / DB.getOrCreateBook / DB.addCard), then runs THIS
-- extractor's own Extractor.extractLanguage() against that same on-disk
-- database and asserts every field round-trips correctly. A source-file
-- diff can be a false alarm (a comment changed, a function got renamed but
-- kept the same shape) or a false pass (whitespace-only formatting hid a
-- real behavior change); this proves the actual behavior still works.
--
-- Requires KOReader's setupkoenv.lua to have already been dofile'd by the
-- caller (sets package.path for datastorage/logger/util/ffi/lua-ljsqlite3),
-- and two env vars pointing at the two checkouts to test against:
--   UPSTREAM_DIR   - a fresh clone of yupmoon/vocabdeck.koplugin
--   EXTRACTOR_DIR  - this repo's own checkout (vocabdeckextractor.koplugin)
-- KO_HOME should already be set to an empty temp directory by the caller,
-- so DataStorage:getDataDir() resolves somewhere disposable -- both
-- upstream's DB code and this extractor read/write under the same data
-- dir, which is what lets this test share state between them the same way
-- they'd share it on a real device.

local UPSTREAM_DIR = assert(os.getenv("UPSTREAM_DIR"), "UPSTREAM_DIR not set")
local EXTRACTOR_DIR = assert(os.getenv("EXTRACTOR_DIR"), "EXTRACTOR_DIR not set")

package.path = UPSTREAM_DIR .. "/?.lua;" .. EXTRACTOR_DIR .. "/?.lua;" .. package.path

local DB = require("vocabdeck_db")
local Extractor = require("extractor_vocabdeck")

local TEST_LANGUAGE = "CompatCheckLanguage"
local EXPECTED = {
    phrase = "compat-check-phrase",
    sentence = "A sentence used only for the compatibility check.",
    pronunciation = "kem-PAT",
    meaning = "a deliberately fake dictionary meaning",
    synonym = "placeholder",
    word_type = "noun",
    -- A canonical name, not an ISO code -- upstream's addCard() runs this
    -- through Languages.normalize(), which maps codes/aliases to a display
    -- name (e.g. "es" -> "Spanish"). Using the canonical form directly here
    -- means this test round-trips the card fields without also depending on
    -- that alias table's exact contents, which isn't what this test is for.
    source_language = "Spanish",
    user_note = "note added by the compatibility check",
}

DB.setLanguage(TEST_LANGUAGE)

local book_id = DB.getOrCreateBook("Compat Check Book", "/fake/compat-check.epub", EXPECTED.source_language)
assert(book_id, "DB.getOrCreateBook returned nil -- upstream's book-creation API may have changed shape")

local card_id = DB.addCard(book_id, EXPECTED)
assert(card_id, "DB.addCard returned nil -- upstream's card-creation API may have changed shape")

-- ---------------------------------------------------------------------------
-- Memory-helper section labels.
--
-- vocabdeck_memory_helper.lua doesn't expose a pure function that formats
-- this text -- the text comes back from an AI provider, shaped by the prompt
-- that file builds. So the coupling worth testing isn't a function call, it's
-- the *section labels* the prompt demands ("Morphology:", "Collocations:",
-- ...), since memory_helper_parser.lua splits on exactly those.
--
-- Critically, these labels are scraped out of upstream's own prompt source
-- rather than hardcoded here. Hardcoding them would make this test vacuous:
-- it would keep passing while upstream renamed a label out from under the
-- parser, which is precisely the failure this is meant to catch.
local function scrapeSectionLabels()
    local f = assert(io.open(UPSTREAM_DIR .. "/vocabdeck_memory_helper.lua", "r"),
        "couldn't open upstream vocabdeck_memory_helper.lua")
    local source = f:read("*a")
    f:close()

    local labels = {}
    -- Matches the prompt's own rule lines, e.g.:
    --   - Include "Collocations:" with 2-4 common word pairings ...
    for label in source:gmatch('Include "([^":]+):"') do
        labels[#labels + 1] = label
    end
    return labels
end

local SECTION_LABELS = scrapeSectionLabels()

-- Guard against a vacuous pass: if upstream restructures its prompt so the
-- scrape pattern matches nothing, an empty label list would make every
-- assertion below trivially true. Fail loudly instead.
if #SECTION_LABELS == 0 then
    io.stderr:write("COMPAT CHECK FAILED -- couldn't scrape any section labels from upstream's\n" ..
        "vocabdeck_memory_helper.lua prompt. Its prompt structure likely changed, so\n" ..
        "memory_helper_parser.lua's assumptions need a human review.\n")
    os.exit(1)
end

-- Build a memory-helper blob the way upstream's prompt asks the AI to: each
-- scraped label, blank-line separated, with distinctive content per section.
local section_content = {}
local blob_parts = {}
for i, label in ipairs(SECTION_LABELS) do
    local content = string.format("compat-check content for section %d", i)
    section_content[label] = content
    blob_parts[#blob_parts + 1] = label .. ": " .. content
end
assert(DB.updateCardMemoryHelper(card_id, table.concat(blob_parts, "\n\n")),
    "DB.updateCardMemoryHelper failed -- upstream's memory-helper write API may have changed shape")

local records, err = Extractor.extractLanguage(TEST_LANGUAGE)
assert(not err, "Extractor.extractLanguage returned an error: " .. tostring(err))
assert(#records == 1, "expected exactly 1 extracted record, got " .. tostring(#records))

local fields = records[1].fields
local failures = {}
for name, expected_value in pairs(EXPECTED) do
    local actual = fields[name] and fields[name].value
    if actual ~= expected_value then
        failures[#failures + 1] = string.format("  %s: expected %q, got %q", name, tostring(expected_value), tostring(actual))
    end
end

-- Every section upstream's prompt asks for must land in some parsed field.
-- Deliberately not asserting a specific label -> field mapping: that mapping
-- is this extractor's own business. What matters for compatibility is that
-- no section upstream produces gets silently dropped on the floor.
local MEMORY_HELPER_FIELDS = { "morphology", "collocations", "memory_hook", "example_sentence" }
for label, content in pairs(section_content) do
    local found = false
    for _, field_name in ipairs(MEMORY_HELPER_FIELDS) do
        local entry = fields[field_name]
        if entry and entry.value == content then
            found = true
            break
        end
    end
    if not found then
        failures[#failures + 1] = string.format(
            "  memory-helper section %q was not recovered into any parsed field -- " ..
            "memory_helper_parser.lua may not know this label", label)
    end
end

if #failures > 0 then
    io.stderr:write("COMPAT CHECK FAILED -- extracted fields didn't match what was written:\n" .. table.concat(failures, "\n") .. "\n")
    os.exit(1)
end

print("COMPAT CHECK PASSED -- card round-tripped through upstream vocabdeck_db.lua and extractor_vocabdeck.lua correctly.")
os.exit(0)
