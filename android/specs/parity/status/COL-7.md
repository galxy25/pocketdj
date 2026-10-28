state: implemented

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
