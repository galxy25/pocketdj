state: implemented

# BRW-10 ZoneEngine: In Da Zone + collection suggestions + cloud shaping

- [x] ZoneEngine.kt: Track/Play/Tuning/Feedback(+skipPenalties)/Queue/Pool; versionKeys; inDaZone (two-pool blend, shortlist, fallback pool, cross-pool keepMask); shapeCloudRanking; interleave; rank (SOUND DOOR, veto, composition); suggestions; explainedSuggestions
- [x] ZoneCatalog.kt: MergedCatalog -> tracks + genreBySongId ("Other" -> null, year falls back to album, raw genre kept) + lazy versionKeys; ZoneCatalogCache keyed on revision
- [x] zone-fixture-catalog.json (144 songs / 18 albums / 72 timbre vectors, generated deterministically)
- [x] ZoneEngineTest (43) + ZoneParityTest (13)
- [x] Full suite: 2936 tests, 0 failures; assembleDebug green

## Notes / deviations
- Reuses BRW-8 `Similarity` (balanced profile/score) and BRW-9 RecIdentity/RecShaping; no files outside the owned set touched.
- inDaZone's similarity-free aux math lives in a private `ZoneSignals` class (not closures): D8 8.9.32 crashed with ArrayIndexOutOfBounds on the one giant function.
- Parity is invariant/pin based (no Swift runner available to emit golden outputs); the numeric families are already golden-tested in BRW-8 (SimilarityParityTest).
- Faithful iOS behavior worth knowing: `Feedback.rejected` in inDaZone only SUBTRACTS (shape); removal is `suppressed` (scoped tombstone resolved by the caller). Sound-quota is relative to emitted list length (0.12 x limit, hard cap 3), so a short list seats fewer door rows.
- Emulator step ("rank now" debug action) not wired: no debug-screen owner file in scope; entry point is `ZoneEngine.inDaZone(...).count / .count(Pool.REDISCOVERY)` over `ZoneCatalog.from(MergedCatalog)`.

## Questions for Levi
None.
