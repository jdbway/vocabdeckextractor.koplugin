local _ = require("gettext")
return {
    name = "vocabdeckextractor",
    fullname = _("VocabDeck Extractor"),
    description = _([[Reads VocabDeck's card data and prepares it for cross-device sync via AnnotationSync's Extractor interface. Requires VocabDeck to be installed.]]),
    -- Bump on every functionally meaningful change -- lets a deployed copy's
    -- version be checked with one grep (main.lua logs it at init) instead of
    -- diffing every file against the repo. 1.0.0 = first version with a real
    -- writeback implementation (previously extraction/push only).
    version = "1.0.0",
}
