# Architecture

Internals and design rationale. For what this plugin is and how to use it,
see [README.md](README.md).

## Purpose

An "Extractor" plugin for AnnotationSync's proposed cross-device sync
interface ([AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93)).
It turns VocabDeck's own SQLite data into a portable, field-level-mergeable
record shape another sync system can reason about without knowing anything
about VocabDeck's schema.

## Module map

| File | Responsibility |
|---|---|
| `main.lua` | Plugin entry point. Registers the debug menu (Tools > VocabDeck Extractor). Owns the (currently stubbed) call into AnnotationSync. |
| `extractor_vocabdeck.lua` | The core pipeline: enumerate VocabDeck's per-language databases, read every card, compute the Merge Key, diff against the snapshot, classify fields by policy, return records. |
| `memory_helper_parser.lua` | Splits VocabDeck's `ai_memory_helper` text blob into its four labeled sections. Pure function, no I/O. |
| `snapshot_store.lua` | Persists this plugin's own memory of "what did I last report for each field," entirely separate from VocabDeck's database. Thin wrapper over `LuaSettings`. |

## Data flow

**Extraction (real, working today):**

1. `main.lua`'s debug menu (eventually: AnnotationSync's broadcast sync event) calls `Extractor.extractAll()`.
2. For each language VocabDeck has a database for (`extractor_vocabdeck.lua:listLanguages()`, mirroring `vocabdeck_db.lua`'s own enumeration):
   a. Open that language's SQLite file directly (read-only in practice, though not opened in a read-only mode explicitly).
   b. Load `snapshot_store.lua`'s prior snapshot for this language.
   c. For each card row: if VocabDeck's own `updated_at` for that row matches what's in the snapshot, re-emit the stored field snapshot verbatim — cheap skip, nothing to recompute. Otherwise, diff every field's current value against the snapshot's last-known value; unchanged fields keep their old `changed_at`, changed fields get stamped with the current time.
   d. Parse `ai_memory_helper` into its four sections as part of that same per-row diff (they're just more fields to the diffing logic; it doesn't know or care that they came from one column).
   e. Save the updated snapshot for that language.
3. Return `{ [language] = records }`.

**Push to AnnotationSync (not implemented — see Status below):**

Deferred call shape, not yet real: for each language, call
`AnnotationSync.pushExtractorData("vocabdeck", language, records, writeback_fn)`,
where `writeback_fn` receives the post-merge records back and writes any
`last_write_wins` field back into that language's `cards` table by Merge Key.

## Invariants

- **The Merge Key normalization must stay byte-for-byte identical to VocabDeck's own `normalizePhrase()`** in `vocabdeck_db.lua`. If VocabDeck ever changes its normalization, this extractor needs the matching change, or Merge Keys silently stop lining up across devices. There is no test enforcing this today — it's a manual sync point.
- **`id` and `book_id` are never part of a record.** Both are local SQLite autoincrement values with no meaning across independently-created databases on different devices — this was the exact bug found in an earlier one-way export script that used the row `id` as a stable identifier.
- **This plugin only reads VocabDeck's data.** It doesn't require VocabDeck's plugin code to be loaded, only that its data files exist on disk, and it never writes to VocabDeck's database (the writeback half, once built, will be the first thing that does).

## Decisions and why

- **Every AI-derived field is `last_write_wins`, not `write_once`.** Confirmed directly with the person this was built for: VocabDeck offers multiple ways to re-enrich a card (Refetch AI data, bulk re-enrich), and the *latest* enrichment is what's supposed to end up synced, not the first. This includes the parsed memory-helper sections — "Regenerate" is a deliberate, intentional update, and last-write-wins is the right policy for a field that's occasionally wholesale replaced.
- **Per-field `changed_at` is synthesized by this extractor, not read from VocabDeck.** VocabDeck's schema tracks exactly one `updated_at` per card row — bumped by a review, a re-enrichment, a memory-helper regenerate, or a note edit alike. Trusting that row-level timestamp directly for field-level merge decisions would let an unrelated change on the same row make a genuinely-stale field look artificially fresh. `snapshot_store.lua` exists specifically to avoid that, without requiring any change to VocabDeck itself.
- **The row-level `updated_at` is still used, as a cheap gate.** If it hasn't moved since the last extraction, nothing on that row changed — skip the per-field diff entirely rather than re-comparing every field of every card on every run.
- **The memory-helper blob is parsed into separate fields rather than pushed as one opaque string.** The point of an Extractor is normalizing a source plugin's storage into something a downstream tool can actually use field-by-field, not just relaying a blob a future consumer would have to re-parse itself.

## Status / non-goals

Tracked against [AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93).

- **Working and tested against real device data:** everything under "Extraction" above. Verified against a live VocabDeck database — parsed memory-helper output matches the on-device UI exactly, and re-extracting with no changes produces byte-identical output (no spurious timestamp drift). A real single-field edit was also verified to only bump the timestamps of the fields that actually changed, nothing else on the same card or any other card.
- **Not implemented:** the `pushExtractorData` call, listening for AnnotationSync's sync-trigger event, and the writeback half. None of that exists in AnnotationSync's code yet, and guessing at the exact function/module/event names now risks redoing this work later for no reason — it's a small, isolated adapter once his interface is real, not a redesign of anything above.
- **Open question with the AnnotationSync maintainer:** whether Keyed Merge resolves `last_write_wins` per field or per whole pushed record. This extractor already computes real per-field timestamps regardless of the answer; the answer only affects how (or whether) they need to be collapsed before pushing.
