-- Splits VocabDeck's ai_memory_helper blob into its labeled sections.
--
-- vocabdeck_memory_helper.lua asks its AI provider for a fixed set of
-- plain-text sections ("Morphology:", "Collocations:", "Memory hook:",
-- "Example:"), each optional, separated by blank lines, and stores the
-- whole thing as one TEXT column. This recovers the individual sections so
-- they can travel as separate, independently-mergeable Extractor fields
-- instead of one opaque blob.
local TextUtils = require("vocabdeck_text_utils")

local Parser = {}

-- Ordered so ties (a label string appearing as a false-positive substring of
-- another) resolve predictably; VocabDeck itself always emits this order,
-- but this parser doesn't require it.
local SECTION_LABELS = { "Morphology", "Collocations", "Memory hook", "Example" }
local SECTION_KEYS = {
    ["Morphology"] = "morphology",
    ["Collocations"] = "collocations",
    ["Memory hook"] = "memory_hook",
    ["Example"] = "example_sentence",
}

function Parser.emptySections()
    return {
        morphology = "",
        collocations = "",
        memory_hook = "",
        example_sentence = "",
    }
end

function Parser.parse(text)
    local sections = Parser.emptySections()
    if type(text) ~= "string" or text == "" then
        return sections
    end

    local found = {}
    for _, label in ipairs(SECTION_LABELS) do
        local start_pos = text:find(label .. ":", 1, true)
        if start_pos then
            found[#found + 1] = {
                label = label,
                start_pos = start_pos,
                content_start = start_pos + #label + 1,
            }
        end
    end
    table.sort(found, function(a, b) return a.start_pos < b.start_pos end)

    for i, entry in ipairs(found) do
        local content_end = found[i + 1] and (found[i + 1].start_pos - 1) or #text
        local content = text:sub(entry.content_start, content_end)
        sections[SECTION_KEYS[entry.label]] = TextUtils.trim(content)
    end

    return sections
end

return Parser
