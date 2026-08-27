# VocabDeck Extractor

An "Extractor" plugin for [AnnotationSync.koplugin](https://github.com/dani84bs/AnnotationSync.koplugin),
built against the design proposed in
[AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93).
It reads [VocabDeck](https://github.com/yupmoon/vocabdeck.koplugin)'s own
per-language SQLite databases and turns them into Extractor Records:
a stable, content-derived Merge Key (VocabDeck's own `normalized_phrase`,
computed identically) plus a set of fields, each carrying its own merge
policy (`write_once` or `last_write_wins`) and a `changed_at` timestamp this
plugin computes itself.

## Status

**Working today:** reading VocabDeck's databases, computing Merge Keys,
classifying fields by policy, parsing the `ai_memory_helper` blob into
separate `morphology` / `collocations` / `memory_hook` / `example_sentence`
fields, and synthesizing accurate per-field `changed_at` timestamps from a
source database that only tracks one `updated_at` per row (see
`snapshot_store.lua`'s header comment for why that matters). This runs and
is testable right now via the debug menu entries below — no dependency on
anything AnnotationSync hasn't built yet.

**Not implemented yet:** the actual call into AnnotationSync
(`pushExtractorData`), listening for its sync-trigger event, and the
writeback half (turning merged records back into VocabDeck rows). None of
that exists in AnnotationSync's code as of this writing — see `main.lua`'s
`onPushToAnnotationSync()` for exactly what's deferred and why. This is
deliberate: building against an interface that isn't implemented yet risks
guessing wrong on names/signatures and redoing the work, so everything that
*can* be built and tested independently of AnnotationSync's own progress has
been, and only the thin adapter at the very end is waiting.

## Why this reads VocabDeck's data directly

This plugin doesn't require VocabDeck's own plugin code to be loaded, or
even installed as a *running* plugin — only that its data files exist on
disk (`<KOReader data dir>/vocabdeck/*.sqlite3`). Extraction only ever reads
files VocabDeck itself already writes.

## Files

- `extractor_vocabdeck.lua` — the core: enumerates VocabDeck's per-language
  databases, reads every card, diffs against this plugin's own snapshot to
  compute per-field timestamps, and returns records ready to push.
- `memory_helper_parser.lua` — splits VocabDeck's `ai_memory_helper` text
  blob into its four labeled sections.
- `snapshot_store.lua` — persists this plugin's own memory of "what did I
  last report for each field," entirely separate from VocabDeck's database.
- `main.lua` — plugin entry point, debug menu (Tools > VocabDeck Extractor),
  and the stubbed AnnotationSync push.

## Debug menu (Tools > VocabDeck Extractor)

- **Extract now (debug)** — runs the real extraction pipeline, shows a
  per-language card-count summary.
- **Dump extraction to file (debug)** — writes the full extracted record set
  to `<KOReader data dir>/vocabdeckextractor_dump.lua` as a plain Lua table
  literal, for inspection while there's no real downstream consumer yet.
- **Push to AnnotationSync** — currently a placeholder; shows a message
  explaining what's pending.

## Design notes worth knowing before touching this code

- The Merge Key (`normalized_phrase`) is computed by a function that
  **must stay byte-for-byte identical** to VocabDeck's own `normalizePhrase()`
  in `vocabdeck_db.lua`. If VocabDeck ever changes its normalization, this
  needs to change with it, or Merge Keys will silently stop matching across
  devices.
- `id` and `book_id` are deliberately excluded from the record's fields —
  both are local SQLite autoincrement values with no meaning across
  independently-created databases on different devices.
- Every AI-derived field (`meaning`, `synonym`, `word_type`, `pronunciation`,
  the parsed memory-helper sections) is tagged `last_write_wins`, not
  `write_once` — confirmed directly with the person this was built for:
  VocabDeck offers multiple ways to re-enrich a card, and the *latest*
  enrichment is what's supposed to end up synced, not the first.
