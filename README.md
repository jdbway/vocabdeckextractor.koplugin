# VocabDeck Extractor

An "Extractor" plugin for [AnnotationSync.koplugin](https://github.com/dani84bs/AnnotationSync.koplugin),
built against the design proposed in
[AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93).
It reads [VocabDeck](https://github.com/yupmoon/vocabdeck.koplugin)'s own
per-language SQLite databases and turns them into Extractor Records — data
AnnotationSync (once its side of this interface exists) can sync across
devices and merge field-by-field, instead of clobbering a whole card if two
devices touch it independently.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how this actually works
internally, the module map, and the design decisions behind it.

## Status

**Working today:** reading VocabDeck's databases, computing stable
cross-device Merge Keys, classifying every field by merge policy, parsing
the AI memory helper into its separate sections, and computing accurate
per-field change timestamps. Verified against real device data — see
[ARCHITECTURE.md](ARCHITECTURE.md#status--non-goals) for what's been tested
and how.

**Not implemented yet:** actually pushing to AnnotationSync. Its side of
this interface doesn't exist yet — tracked on
[AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93).

## Installation

1. Download or clone this repository.
2. Copy the folder named `vocabdeckextractor.koplugin` into KOReader's
   `plugins` directory.
3. Restart KOReader.
4. Requires [VocabDeck](https://github.com/yupmoon/vocabdeck.koplugin) to
   already have some cards saved — this plugin only reads VocabDeck's data
   files, it doesn't need VocabDeck's own plugin to be running.

## Debug menu (Tools > VocabDeck Extractor)

- **Extract now (debug)** — runs the real extraction pipeline, shows a
  per-language card-count summary.
- **Dump extraction to file (debug)** — writes the full extracted record set
  to `<KOReader data dir>/vocabdeckextractor_dump.lua` as a plain Lua table
  literal, for inspection while there's no real downstream consumer yet.
- **Push to AnnotationSync** — currently a placeholder; shows a message
  explaining what's pending.
