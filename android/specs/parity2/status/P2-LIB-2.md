state: merged

# P2-LIB-2: Apple Music library source, part 1 (store + Web API indexer)

- [x] AppleMusicLibraryStore: iOS doc shape (`pocketdj-apple-music-library.json`), optional albums/playlists/lastAddedMs/supersededAddedAt, whole-number epoch ms encoded like Swift, atomic write, replaceAll / applyIncremental (idempotent by songId, mark never lowers) / supersede / clear / reloadFromDisk
- [x] AppleMusicApi: `librarySongsPage`, `libraryAlbumsPage` (include=catalog); parsing in AppleMusicLibraryIndexer.kt (`AppleMusicLibraryParsing`); playlists reuse existing `allLibraryPlaylists` / `allPlaylistTrackRows`
- [x] AppleMusicLibraryIndexer: full vs incremental, FNV-1a album ids (iOS-identical), album enrichment, `amlib_` / `amlibpl_` ids, appleMusicId from catalog relationship
- [x] AppleMusicLibraryWorker: daily periodic (network + battery-not-low, not unmetered-gated), `enqueueNow` for sign-in and manual Re-index; ServicesGraph wiring (`amLibraryStore`, `amLibraryIndexer`, `runAmLibraryIndex`, `reindexAmLibrary()`, sign-in watcher)
- [x] Tests: AppleMusicLibraryStoreTest (9), AppleMusicLibraryIndexerTest (9)

Test count: 6843 total JVM tests, 0 failures (18 new). `:app:testDebugUnitTest :app:assembleDebug` green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations / notes
- The Web API has no documented sort by add date, so an incremental run pages through all songs and appends unseen songIds (idempotent) rather than stopping at a high-water mark as iOS does. `lastAddedMs` is still advanced.
- Library `dateAdded` is used when the API carries it; else a known value (pulled from iOS / earlier run) is kept; else first-indexed time.
- Failed playlist read: playlists are left untouched (full run keeps existing; incremental passes null) so a transient error never wipes them.
- `supersededAddedAt` survives a full re-index (iOS's replaceAll also leaves it).
- Files touched outside owned set (minimal, additive): `shell/FeatureModule.kt` (`PeriodicWorkSpec.requiresBatteryNotLow`, default false), `work/WorkScheduler.kt` (`WorkPlan.requiresBatteryNotLow`, applied to constraints), `di/ServicesGraph.kt` (touchpoint), `AppleMusicApi.kt` (owned).
- Not done here (P2-LIB-3): catalog fold, SyncEntry `apple-music-library`, account-deletion key, Settings toggle UI + "Re-index" button. Hooks ready: `AmLibrarySettings.ENABLED` (pref `amLibraryIndexEnabled`, default true), `ServicesGraph.reindexAmLibrary()`, `amLibraryStore.reloadFromDisk()`/`syncFile`/`onChanged`.
- Emulator step (pdj.amApiBase + fakeMut) not run (emulator is integrator-owned); `run-as cat files/pocketdj-apple-music-library.json` is the check.

## Questions for Levi
- Index your own Apple Music library on Android once a day after sign-in? Defaulted to YES (toggle pref `amLibraryIndexEnabled`; UI in P2-LIB-3).

## Review
- MINOR sign-in watcher enqueued on every launch -> fixed: `signInIndexDecision` (launch: only when store empty / never indexed / >24h; false->true transition: FULL; else none).
- MINOR AUTO never reconciles removals -> fixed: a stored song absent from the full listing escalates the run to a full replace (empty listing ignored).
- MINOR account change mixes stores -> fixed: sign-in transition enqueues FULL (replaceAll). Sign-out clearing left to P2-LIB-3.
- NIT empty albums/playlists keys -> fixed: replaceAll keeps empty lists (iOS shape).
- Tests added: incrementalDropsSongsRemovedFromLibrary, signInDecision.

fixes applied
