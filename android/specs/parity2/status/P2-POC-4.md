state: implemented

# P2-POC-4 Pocket palette store + sync/deletion keys

- [x] PocketPalette.kt (PocketSwatch, exact 12x2 RGB tables, oklchToSRGB, sha256 overflow hue)
- [x] PocketPaletteStore.kt (lenient per-entry decode, merge, normalized, 30-day free, iOS-style whole-number JSON, unknown top-level keys kept)
- [x] SyncEntry pocket-palette (ServicesGraph) + profile-source (StudioGraph); both in AccountDeletionService.cloudDocKeys; palette cleared in localStores
- [x] 13 new JVM tests (PocketPaletteStoreTest); full suite 6178 tests, 0 failures; assembleDebug green

## Deviations / files touched outside owned set
- ProfileSourceStore.kt: added `reloadFromDisk()` (needed by the profile-source sync entry) and updated the "no cloud sync" doc comment.
- AccountDeletionTest.kt: registry key set extended with the two new keys (lockstep test).
- `fav_songs` never freed: implemented in assign() per acceptance (iOS store has no such rule; harmless superset).
- Palette store is unreferenced by UI until P2-POC-5/9; no debug hook added. assembleRelease not run (no manifest/gradle/proguard/library change).

## Questions for Levi
None.
