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

**Working today:** the full round trip — reading VocabDeck's databases,
computing stable cross-device Merge Keys, classifying every field by merge
policy, parsing the AI memory helper into its separate sections, computing
accurate per-field change timestamps, pushing to AnnotationSync, and writing
merged results back into VocabDeck's own database (new cards inserted,
existing cards updated field-by-field). Verified end-to-end across two real,
independently-editing KOReader instances — see
[ARCHITECTURE.md](ARCHITECTURE.md#status--non-goals) for what's been tested
and how.

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

## Roadmap

This is meant to become the first of several small, source-specific
Extractor plugins — one per KOReader annotation/vocabulary tool that's
worth syncing (a second is planned for
[assistant.koplugin](https://github.com/omer-faruq/assistant.koplugin)'s
notebook log). Rather than requiring a separate install per source, the plan
is a single installed "suite" plugin that auto-detects which source plugins
are actually present on the device and activates only the matching
extractor module(s) internally. This repo stays the standalone VocabDeck
extractor until that suite's shared core exists to fold it into — see
[ARCHITECTURE.md](ARCHITECTURE.md) for why building the generalized
suite/detection shell before a second real extractor exists would mean
guessing at an abstraction with no second example to design it against.

## Contributing

Issues and pull requests are welcome — this is early and still evolving
alongside AnnotationSync's own design work on the Extractor interface (see
[AnnotationSync.koplugin#93](https://github.com/dani84bs/AnnotationSync.koplugin/issues/93)),
so it's worth reading [ARCHITECTURE.md](ARCHITECTURE.md) first to see what's
settled versus still in flux, and worth opening an issue before a large
change so the approach can be agreed on first. Small fixes and clarifications
don't need that — just open a PR.

## License

GPLv3 (see [LICENSE](LICENSE)) — matching
[VocabDeck](https://github.com/yupmoon/vocabdeck.koplugin)'s own license,
since this plugin's phrase-normalization logic is intentionally copied from
VocabDeck's source to guarantee the two stay compatible (see
[ARCHITECTURE.md](ARCHITECTURE.md#invariants)).
