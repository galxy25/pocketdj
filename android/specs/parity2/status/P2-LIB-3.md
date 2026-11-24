state: reviewed

# P2-LIB-3: Apple Music library source, part 2 (fold, supersede, sync, Settings)

- [x] AppleMusicLibraryFold: pure `split`/`fold`/`syntheticIndex` (source "Apple Music", manifest source `apple-music-library`, `amlib_`/`amlibpl_` ids), supersede by appleMusicId onto indexed "Apple Music (Local)" twins only, playlist song ids remapped, albums pruned of superseded tracks; memoized `Source` (identity-keyed, keeps CatalogRepository no-op-merge check cheap)
- [x] CatalogRepository: `amLibrarySource` + `onAmLibrarySupersede` (appended after Imported + profile source, iOS order); CollectionsGraph wires it (store.onChanged -> remergeLocal; supersede = remap collections + favorites FIRST, then prune store, as Imported)
- [x] supersededAddedAt carried for Recently added via `RecentlyAdded.extraOverrides` hook (additive, default empty)
- [x] SyncEntry("apple-music-library", pocketdj-apple-music-library.json) whole-doc LWW (`writePulled` + `reloadFromDisk`); account-deletion key list + AccountDeletionTest lockstep updated; reset hook clears the store; sign-out clears the store
- [x] Settings > Apple Music: "Index my Apple Music library" toggle (`amLibraryIndexEnabled`), last-indexed caption, "Re-index now"
- [x] Tests: AppleMusicLibraryFoldTest (15)

Test count: 7040 total JVM tests, 0 failures (15 new). `:app:testDebugUnitTest :app:assembleDebug` green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations / notes
- Files touched outside owned set (minimal, additive): `data/collections/RecentlyAdded.kt` (extraOverrides hook), `data/applemusic/AppleMusicLibraryStore.kt` (`writePulled`), `data/reset/AccountDeletionService.kt` (key), `AccountDeletionTest.kt` (lockstep), `di/ServicesGraph.kt`, `di/CollectionsGraph.kt`, `data/catalog/CatalogRepository.kt` (touchpoints).
- Owner gate: iOS supersedes only for the catalog OWNER (`amLibrarySupersedes`). Android has no owner-identity probe, so the gate is a lambda (`AppleMusicLibraryFold.Source(store) { true }` in ServicesGraph) defaulting ON; scoped to source name "Apple Music (Local)" as defense in depth.
- Superseded album track ids are pruned in the fold itself (iOS leaves them until the store prune); no behavior difference for users.
- Emulator step not run (emulator is integrator-owned).

## Questions for Levi
- Should a library song supersede onto the "Apple Music (Local)" twin for EVERY user (current default) or only when the catalog is provably the user's own (iOS owner gate)? Android has no owner probe yet; a hybrid user pointed at a curator's shared catalog would see their library rows fold into the curator's twins.
- Signing out of Apple Music now erases the local library index (re-indexed on next sign-in). OK?

## Review
- MAJOR owner gate hard-wired true -> fixed: gate now `ServicesGraph.amLibrarySupersedesOntoLocal`, default OFF (no owner probe exists); test `gateOffNeverSupersedesGateOnDoes`. Library rows stay under source "Apple Music" until a real owner signal flips it.
- MINOR supersede() left dangling playlist ids -> fixed: supersede() remaps stored playlist songIds; test `foldThenSupersedeThenFoldKeepsPlaylistsResolvable`.
- MINOR sign-out clear() re-adopted from cloud -> fixed: sign-out no longer clears; re-sign-in is a FULL run that replaces the index wholesale (signInIndexDecision), so no cross-account inheritance.
- NIT extraOverrides leak -> rejected (already reset in @After of AppleMusicLibraryFoldTest); wiring tests not added.
- Tests: 7042 total, 0 failures (+2). Note: the wrapper refused `--no-quiesce-fin` (7GB LM Studio models resident), so builds ran with default quiesce.

fixes applied
