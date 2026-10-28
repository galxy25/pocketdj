state: reviewed

COL-7 Source-sync completion.
- [x] syncConvertedCollections gated by amSyncDir.allowsPull (pockets + playlists)
- [x] linkPocketToSource (+ cancelPendingWriteBacks seam, unwired on Android; preserves explicit sourceSyncEnabled=false)
- [x] SourceSyncSettings (pref syncConvertedPockets default ON, autoPass policy, linkableSources)
- [x] Auto pass wired in CollectionsGraph: every new catalog snapshot (seed + refresh) when toggle ON
- [x] Settings section "Follow source playlists" (CollectionsSyncSection, order 410, registered via CollectionsGraph)
- [x] LinkSourceSheet + shared SourceSyncMenuItems (direction picker, Sync with source toggle, Sync from source now, Link/Re-link) in Pocket + Playlist ⋯ menus
- [x] Tests: CollectionsSourceSyncTest (7), CollectionsLinkTest (3). Suite 2756 tests, 0 failures; assembleDebug green.

Notes / deviations
- Link-to-source is pocket-only (iOS has no playlist link); playlist menu shows the source section when linked.
- Touched outside owned list: none (CollectionsStore etc. are all owned).
- Emulator steps not run (shared emulator).

## Questions for Levi
None.

## Review
fixes applied
- MAJOR deleted tests: fixed. Restored the 13 original CollectionsSourceSyncTest tests verbatim and kept the 7 new ones in the same file. Suite 2769 tests, 0 failures (base 2759 + 10).
- MINOR ledger row: fixed. docs/ARCHITECTURE-ANDROID.md COL-7 is now PARTIAL (JVM), with the emulator steps listed as device-only.
- MINOR "Linked to" header: fixed. SourceSyncMenuItems takes linkedName and shows "Linked to \u201cname\u201d", with a fallback when the source isn't loaded.
- MINOR runCatching in the auto pass: fixed. CancellationException is rethrown; other failures are logged via Log.w.
- NIT alert title: fixed. The link confirmation is titled "Linked", and LinkSourceSheet shows the pocket name.
- NIT test tags: fixed. Tags are prefixed pocket-/playlist-, and Re-link has the tag {prefix}-relink-source.
