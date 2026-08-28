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
| `main.lua` | Plugin entry point. Registers the debug menu (Tools > VocabDeck Extractor). Owns the real push call into AnnotationSync and the sync-event hook. |
| `extractor_vocabdeck.lua` | The core pipeline: enumerate VocabDeck's per-language databases, read every card, compute the Merge Key, diff against the snapshot, classify fields by policy, return records. |
| `writeback_vocabdeck.lua` | The other half: applies AnnotationSync's merged records back into VocabDeck's own database — inserts new cards, updates only the `last_write_wins` fields on existing ones, reconstructs `ai_memory_helper` from its four sub-fields, and keeps `snapshot_store.lua` in sync with what was actually written. |
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

**Push to AnnotationSync (real):**

For each language, `main.lua` calls
`AnnotationSync.pushExtractorData("vocabdeck", language, records, writeback_fn)`.
AnnotationSync merges the pushed records against whatever's on the remote
and calls `writeback_fn` back with the merged result.

**Writeback (real):**

`writeback_vocabdeck.lua:Writeback.apply(language, merged_records)` applies
that merged result into the real `cards` table, by Merge Key
(`normalized_phrase`):

1. Existing card: read the current row, compare every `last_write_wins`
   column (and the reconstructed `ai_memory_helper`, compared by parsed
   section rather than raw bytes — see Invariants) against the merged
   values. If nothing actually differs, touch nothing — no `UPDATE`, no
   `updated_at` bump, no snapshot write. Otherwise `UPDATE` only the columns
   that changed, bump `updated_at` to now, and update
   `snapshot_store.lua`'s memory for that card to match exactly what was
   written (see Invariants for why this second part matters).
2. New card (Merge Key not found locally): resolve or create its `books`
   row by `book_filepath`, then `INSERT` a full row from every field the
   merged record carries — including `last_write_wins` fields like FSRS
   scheduling state, since a card arriving from another device brings its
   own real review progress with it. This is deliberately not
   `vocabdeck_db.lua`'s own `DB.addCard()`, which only sets identity fields
   and lets fresh-card scheduling defaults apply — appropriate for a user
   creating a card right now on this device, wrong for one merging in
   already-reviewed from elsewhere.

## Invariants

- **The Merge Key normalization must stay byte-for-byte identical to VocabDeck's own `normalizePhrase()`** in `vocabdeck_db.lua`. If VocabDeck ever changes its normalization, this extractor needs the matching change, or Merge Keys silently stop lining up across devices. There is no test enforcing this today — it's a manual sync point.
- **`id` and `book_id` are never part of a record.** Both are local SQLite autoincrement values with no meaning across independently-created databases on different devices — this was the exact bug found in an earlier one-way export script that used the row `id` as a stable identifier.
- **Extraction only reads VocabDeck's data; it doesn't require VocabDeck's plugin code to be loaded, only that its data files exist on disk.** Writeback is the one part of this plugin that does write to VocabDeck's database — deliberately implemented with raw SQL rather than requiring `vocabdeck_db.lua`, for the same decoupling reason.
- **`snapshot_store.lua`'s `Snapshot.flush()` must be called on every real extraction, not just the debug-menu path.** `Snapshot.saveForLanguage()` only updates the in-memory `LuaSettings` object; `flush()` is what actually persists it to disk. This was originally only called at the end of `Extractor.extractAll()` (the debug menu's path) — the real push path (`pushLanguage`→`extractLanguage`) called `saveForLanguage()` but never flushed. In-memory that's invisible (the snapshot survives fine across calls within one running process), but it means a KOReader restart between real syncs silently loses all per-field memory — confirmed as a real bug via two-device testing (see the virtual-Kindle testing note below): every field gets re-stamped with a fresh `changed_at` on the next extraction regardless of whether its value actually changed, which can let a stale value incorrectly win a future `last_write_wins` merge purely from timestamp inflation. Fixed by flushing inside `extractLanguage()` itself, right after `saveForLanguage()` — not just at the end of a batch.
- **Writeback must also keep `snapshot_store.lua` in sync with what it writes, using the same `now` for both.** If writeback updates the DB but not the snapshot, the next extraction's coarse `updated_at` gate will look mismatched, forcing a full re-diff that stamps a fresh `changed_at` on the just-written fields — silently discarding the real origin timestamp of a merge that came from another device.
- **Writeback must compare against the *live* row, not just skip on any local change, and must compare `ai_memory_helper` by parsed section, not raw bytes.** The same four section values can legitimately serialize as `"Label: content"` or `"Label:\ncontent"` (the AI response's own formatting varies) — a raw-byte comparison here would flag an unchanged card as "different" on every single push, forever, needlessly bumping `updated_at` and re-stamping the snapshot each time.

## Decisions and why

- **Every AI-derived field is `last_write_wins`, not `write_once`.** Confirmed directly with the person this was built for: VocabDeck offers multiple ways to re-enrich a card (Refetch AI data, bulk re-enrich), and the *latest* enrichment is what's supposed to end up synced, not the first. This includes the parsed memory-helper sections — "Regenerate" is a deliberate, intentional update, and last-write-wins is the right policy for a field that's occasionally wholesale replaced.
- **Per-field `changed_at` is synthesized by this extractor, not read from VocabDeck.** VocabDeck's schema tracks exactly one `updated_at` per card row — bumped by a review, a re-enrichment, a memory-helper regenerate, or a note edit alike. Trusting that row-level timestamp directly for field-level merge decisions would let an unrelated change on the same row make a genuinely-stale field look artificially fresh. `snapshot_store.lua` exists specifically to avoid that, without requiring any change to VocabDeck itself.
- **The row-level `updated_at` is still used, as a cheap gate.** If it hasn't moved since the last extraction, nothing on that row changed — skip the per-field diff entirely rather than re-comparing every field of every card on every run.
- **The memory-helper blob is parsed into separate fields rather than pushed as one opaque string.** The point of an Extractor is normalizing a source plugin's storage into something a downstream tool can actually use field-by-field, not just relaying a blob a future consumer would have to re-parse itself.

## Status / non-goals

Tracked against [AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93).

- **Working and tested end-to-end, including writeback, across two real, independently-editing KOReader instances**: the physical Kindle plus a Docker container running KOReader's official Linux desktop build (same plugins, same starting data, syncing against the same server) — not just extraction against a single device anymore. Verified: fresh push from both against an empty remote converges cleanly; a real edit on one device correctly appears via writeback in the other device's actual database on its next sync; the identical field edited differently on both devices, synced in *reversed* order (the device with the older edit syncs first), still converges on the objectively newer edit regardless of sync order, while untouched fields on the same card stay independently correct.
- **Two real bugs found via that two-device testing, both fixed**: the missing `Snapshot.flush()` on the real path (see Invariants), and an early writeback draft comparing `ai_memory_helper` by raw bytes instead of parsed sections (also in Invariants).
- **Keyed Merge resolves `last_write_wins` per field**, confirmed both by reading `keyed_merge.lua` and by the reversed-sync-order test above.
