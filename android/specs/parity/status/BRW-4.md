state: reviewed

BRW-4 Song/Album detail parity.
- [x] LyricsStore (memory -> filesDir/lyrics-cache -> CDN; gated on lyricsStatus==found; non-2xx/blank not cached; ids sanitized), wired in BrowseGraph.lyricsStore
- [x] TimedLyricsSidecar decoder (lossy words, line grouping 1.2s/12 words)
- [x] ShareText (byte-parity with iOS) + ACTION_SEND on song and album
- [x] SongDetailSheet: Lyrics section + Share button
- [x] AlbumDetailScreen: Shuffle (collections.playNow shuffle, SOURCE_ALBUM, originId=album id, name=album name), Share, audio-analysis section
- [x] StorageService LYRICS category (+ StorageScreen meta, AppGraph wiring)
- [x] Artist-kind sort fields: SortField.forKind(ARTIST) already yields Artist/Albums/Songs/Plays etc.; no sheet change needed
Tests added: 20 (LyricsStoreTest 6, TimedLyricsSidecarTest 5, ShareTextTest 6, AudioAnalysisFmtTest 2, StorageServiceLyricsTest 1). Total 1386, 0 failures.

Files touched outside owned list (minimal, additive): screens/settings/StorageScreen.kt (LYRICS meta, exhaustive when), di/AppGraph.kt (StorageService wiring), shell/ShellNavigation.kt (pass onOpenSetlist to AlbumDetailScreen).
Notes: Timed sidecar is decoded but not yet rendered/fetched (no consumer in scope). Multi-select share helper ShareText.forSongs exists; no multi-select UI hook added.

## Questions for Levi
- none

## Review
fixes applied
- ShareText.query ASCII-only encoding -> fixed (per-code-point; keeps Unicode letters/digits/marks/numbers + -._~; test updated, CJK case added)
- Album Shuffle not gated on anyPlayable -> fixed
- TimedLyricsSidecar leniency vs iOS -> fixed (missing words => empty doc; blank/negative/backwards words kept; fractional ms dropped; wrong-typed header fields fail the doc; tests updated + 1 added)
- forSongs has no consumer -> deferred, not rejected: multi-select share needs a hook in History/Browse (outside BRW-4 owned files); ShareText.forSongs is ready for it
- Share subject lacks artist (NIT) -> fixed (song + album)
- KeyChip fixed width in analysis rows (NIT) -> fixed (84.dp Box; unknown-key 'U' chip not added)
Tests: 1387 total, 0 failures (was 1386).
