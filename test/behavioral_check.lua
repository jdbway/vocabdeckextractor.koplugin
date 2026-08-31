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

if #failures > 0 then
    io.stderr:write("COMPAT CHECK FAILED -- extracted fields didn't match what was written:\n" .. table.concat(failures, "\n") .. "\n")
    os.exit(1)
end

print("COMPAT CHECK PASSED -- card round-tripped through upstream vocabdeck_db.lua and extractor_vocabdeck.lua correctly.")
os.exit(0)
