"""Final packages — collections (COL), browse (BRW)."""
from spec_common import M, T, R, TR, MANIFEST, GRADLE, m, t
from spec_part1 import P

PACKAGES = [
    # ───────────────────────────── COLLECTIONS ─────────────────────────────
    P("COL-1", "collections", src=["COL-1"],
      title="Collections + activity schema parity (additive iOS fields, lenient kinds, iOS fixture round-trip)",
      files=m("data/collections/CollectionsModels.kt", "data/collections/CollectionsCodec.kt", "data/collections/CollectionsStore.kt", "data/activity/ActivityModels.kt", "data/activity/CollectionActivityStore.kt")
            + [TR + "fixtures/ios-collections-v7.json"] + t("data/collections/CollectionsCodecParityTest.kt", "data/activity/ActivityModelsCodecTest.kt"),
      deps=[], est=700, prio="P0", rank=0),

    P("COL-2", "collections", src=["COL-2"],
      title="Store batch choke points + shared VersionedJsonWriter (off-main, version-ordered, invalidate(through:) seam)",
      goal="COL-2 plus decision D6: the writer is the program-wide `data/store/VersionedJsonWriter.kt` reused by MIX-1, PB-4 and STU-1. Batch add/remove/reorder choke points so a select-all add is ONE document write, ONE activity batch, ONE write-back resolution.",
      files=m("data/collections/CollectionsStore.kt", "data/store/VersionedJsonWriter.kt", "data/activity/CollectionActivityStore.kt", "di/CollectionsGraph.kt")
            + t("data/store/VersionedJsonWriterTest.kt", "data/collections/CollectionsBatchTest.kt"),
      deps=["COL-1", "SURF-1"], est=900, prio="P0", rank=1),

    P("COL-3", "collections", src=["DEDUPE-1"],
      title="SongDuplicateJudge (deterministic tiers) + Remove duplicates (collection, all collections) + reconcile duplicate gates",
      files=m("data/collections/SongDuplicateJudge.kt", "data/collections/CollectionsStore.kt", "screens/collections/RemoveDuplicatesDialog.kt", "screens/playlists/PlaylistsScreen.kt", "screens/playlists/PocketDetailScreen.kt")
            + t("data/collections/SongDuplicateJudgeTest.kt", "data/collections/RemoveDuplicatesTest.kt"),
      deps=["COL-1"], est=900, prio="P1", rank=15),

    P("COL-4", "collections", src=["ADD-1"], partial=["GAMES-4"],
      title="AddToActions + Add-to sheet parity (Suggested + Recent, pockets A–Z, playlists A–Z, More… search, onAdded/stayOpenAfterAdd) + 'Add to Playlist' context submenu",
      files=m("screens/collections/AddToActions.kt", "screens/collections/AddToPlaylistMenu.kt", "screens/collections/AddToCollectionSheet.kt", "data/collections/FuzzyMatch.kt",
              "screens/browse/BrowseScreen.kt", "screens/playlists/PlaylistsComponents.kt", "di/CollectionsGraph.kt")
            + t("screens/collections/AddToActionsTest.kt", "data/collections/FuzzyMatchTest.kt", "screens/collections/AddToSheetParamsTest.kt"),
      shared=[M + "screens/browse/BrowseScreen.kt (item context menu hook only)"],
      deps=["COL-2"], est=1400, prio="P1", rank=9,
      acc=["AddToCollectionSheet exposes optional onAdded + stayOpenAfterAdd with unchanged default behaviour (needed by GM-4)"]),

    P("COL-5", "collections", src=["SEL-1"],
      title="Multi-select: RowSelection + SelectableRow + SelectionBar on Browse and every collection detail (touch-first, long-press arms per scope)",
      files=m("ui/selection/RowSelection.kt", "ui/selection/SelectionUi.kt", "screens/browse/BrowseScreen.kt", "screens/playlists/PlaylistDetailScreen.kt", "screens/playlists/PocketDetailScreen.kt", "di/CollectionsGraph.kt")
            + t("ui/selection/RowSelectionTest.kt", "ui/selection/SelectionBarSemanticsTest.kt"),
      shared=[M + "screens/browse/BrowseScreen.kt (selection wrapper)"],
      deps=["COL-2", "COL-4"], est=1500, prio="P1", rank=21),

    P("COL-6", "collections", src=["DND-1"],
      title="Song drag & drop + clipboard (SongTransfer payload, collection-row and whole-list drop targets, paste)",
      files=m("data/collections/SongTransfer.kt", "ui/dnd/SongDragDrop.kt", "screens/playlists/PlaylistsScreen.kt", "screens/playlists/PlaylistDetailScreen.kt", "ui/selection/SelectionUi.kt", "screens/browse/BrowseScreen.kt")
            + t("data/collections/SongTransferTest.kt", "ui/dnd/SongDropAcceptableIdsTest.kt"),
      deps=["COL-5"], est=900, prio="P2", rank=70),

    P("COL-7", "collections", src=["SYNC-1@collections"],
      title="Source-sync completion: auto reconcile on catalog refresh, global + per-item toggles, direction gate, link-to-source",
      files=m("data/collections/CollectionsStore.kt", "data/collections/SourceSyncSettings.kt", "screens/playlists/LinkSourceSheet.kt", "screens/playlists/PocketDetailScreen.kt", "screens/playlists/PlaylistDetailScreen.kt",
              "screens/settings/sections/CollectionsSyncSection.kt", "di/CollectionsGraph.kt")
            + t("data/collections/CollectionsSourceSyncTest.kt", "data/collections/CollectionsLinkTest.kt"),
      deps=["COL-1", "COL-3"], est=1000, prio="P1", rank=23),

    P("COL-8", "collections", src=["WB-1"],
      title="Apple Music write-back queue (durable, Web API transport via SVC-15, batch confirm, backfill, force sync) + Apple Music settings screen",
      files=m("data/applemusic/AppleMusicLibraryPlaylists.kt", "data/applemusic/WriteBackMatcher.kt", "data/applemusic/PlaylistWriteBack.kt", "data/applemusic/WriteBackSettings.kt", "data/collections/CollectionsStore.kt",
              "screens/settings/AppleMusicSettingsScreen.kt", "screens/collections/WriteBackConfirmDialog.kt", "screens/playlists/PocketDetailScreen.kt", "di/CollectionsGraph.kt")
            + t("data/applemusic/WriteBackMatcherTest.kt", "data/applemusic/PlaylistWriteBackQueueTest.kt", "data/applemusic/WriteBackBackfillTest.kt"),
      deps=["COL-2", "COL-7", "SVC-15"], est=2300, prio="P1", rank=33,
      device="Needs a real Apple Music subscription + Music-User-Token; emulator verifies queue durability + NeedsUserToken handling only."),

    P("COL-9", "collections", src=["AMSYNC-1"],
      title="Apple Music playlist sync (Lambda WS2): client, coordinator, audit/run persistence, daily auto-sync (WorkManager), Settings pane",
      files=m("data/applemusic/AMPlaylistSyncClient.kt", "data/applemusic/PlaylistAppleMusicSync.kt", "data/applemusic/AppleMusicAutoSync.kt", "data/applemusic/AmSyncSettings.kt",
              "screens/settings/AppleMusicSettingsScreen.kt", "di/CollectionsGraph.kt")
            + t("data/applemusic/AMPlaylistSyncClientTest.kt", "data/applemusic/PlaylistAppleMusicSyncTest.kt", "data/applemusic/AutoSyncScheduleTest.kt"),
      deps=["COL-8", "COL-7", "SURF-2"], est=2300, prio="P2", rank=72,
      device="Real subscription + MUT."),

    P("COL-10", "collections", src=["FAV-1"],
      title="Favorites store + ♥ toggle + Browse favorite tri-state filter model + heart/unheart activity + FavoriteSeam for the lock screen",
      files=m("data/favorites/FavoritesModels.kt", "data/favorites/FavoritesStore.kt", "ui/FavoriteToggle.kt", "screens/browse/BrowseModels.kt", "screens/playlists/PlaylistsComponents.kt",
              "data/storage/StorageService.kt", "di/CollectionsGraph.kt")
            + t("data/favorites/FavoritesStoreTest.kt", "data/favorites/FavoritesActivityTest.kt"),
      shared=[M + "screens/browse/BrowseModels.kt (favorite tri-state only)", M + "data/storage/StorageService.kt (FAVORITES category)"],
      deps=["COL-1", "SURF-1"], est=1300, prio="P0", rank=4,
      acc=["Implements the playback FavoriteSeam contract shape (isFavorite/toggle by songId) so PB-2's ♥ command can bind to it through CollectionsGraph"]),

    P("COL-11", "collections", src=["FAV-2"],
      title="Favorites two-way Apple Music sync (opt-in) + owner-seed opt-in (default OFF)",
      files=m("data/favorites/FavoritesSyncService.kt", "data/favorites/FavoritesSyncSettings.kt", "screens/settings/AppleMusicSettingsScreen.kt", "di/CollectionsGraph.kt")
            + t("data/favorites/FavoritesSyncServiceTest.kt", "data/favorites/OwnerSeedOptInTest.kt"),
      deps=["COL-10", "COL-8", "SVC-15"], est=1100, prio="P2", rank=74,
      device="Real subscription + MUT."),

    P("COL-12", "collections", src=["RA-1"], partial=["HIST-3"],
      title="Recently added virtual playlist (derivation from IndexSong.dateAdded + add history) + Settings count row",
      files=m("data/collections/RecentlyAdded.kt", "screens/playlists/PlaylistsScreen.kt", "screens/playlists/SourcePlaylistDetailScreen.kt", "screens/settings/sections/CollectionsSection.kt", "di/CollectionsGraph.kt")
            + t("data/collections/RecentlyAddedTest.kt"),
      shared=[M + "screens/settings/sections/CollectionsSection.kt (count row, created by SURF-6)"],
      deps=["COL-1", "BRW-3", "SURF-6"], est=700, prio="P1", rank=27),

    P("COL-13", "collections", src=["SORT-1"],
      title="Per-collection sort/filter on every collection detail (BrowseEngine over the song subset, per-collection persistence, default-order gating)",
      files=m("screens/playlists/CollectionSortFilter.kt", "data/collections/CollectionSortSettings.kt", "screens/playlists/SourcePlaylistDetailScreen.kt", "screens/playlists/PlaylistDetailScreen.kt", "screens/playlists/PocketDetailScreen.kt")
            + t("screens/playlists/CollectionSortFilterTest.kt"),
      deps=["COL-12", "BRW-1"], est=1000, prio="P2", rank=76),

    P("COL-14", "collections", src=["IO-1"], partial=["SET-2"],
      title=".pdjcollection + backup .pocketdj.zip codecs, idempotent import merge, CSV (pure JVM, byte-shape compatible with BackupZip/PocketZip/PlaylistZip.swift)",
      files=m("data/collections/io/PlaylistZip.kt", "data/collections/io/CollectionFile.kt", "data/backup/BackupZip.kt", "data/backup/BackupModels.kt", "data/collections/CollectionsStore.kt")
            + [TR + "fixtures/pwa-playlist.pocketdj.zip", TR + "backup/ios-backup.pocketdj.zip", TR + "backup/ios-pocket.pdjcollection"]
            + t("data/collections/io/PlaylistZipTest.kt", "data/collections/io/ImportMergeIdempotenceTest.kt", "data/backup/BackupZipTest.kt"),
      deps=["COL-1", "COL-10"], est=1600, prio="P2", rank=60,
      acc=["An iOS-produced backup zip and a .pdjcollection round-trip byte-shape (same entry names + manifest) and import twice without duplicating anything"]),

    P("COL-15", "collections", src=["IO-2"], partial=["SET-2"],
      title=".pdjcollection / backup SAF export-import UI, tapped-file open (deep-link handler), provisional imported songs, Settings ▸ Backup section",
      files=m("screens/collections/CollectionExportImport.kt", "data/catalog/ImportedSongsStore.kt", "data/backup/CollectionShare.kt", "screens/settings/sections/BackupSection.kt",
              "shell/CollectionImportSeam.kt", "screens/playlists/PlaylistsScreen.kt", "data/catalog/CatalogRepository.kt", "di/CollectionsGraph.kt")
            + t("data/catalog/ImportedSongsStoreTest.kt", "shell/CollectionImportSeamTest.kt"),
      shared=[M + "data/catalog/CatalogRepository.kt (imported-songs provisional source)"],
      deps=["COL-14", "SURF-4"], est=1400, prio="P2", rank=62),

    P("COL-16", "collections", src=["LP-1@collections"], partial=["LP-1@browse"],
      title="Listening pockets wire models (extending GM-5 PocketsModels), HTTP client, CollectionFlattener + collections payload (pure)",
      files=m("data/pockets/ListeningPocketsModels.kt", "data/pockets/ListeningPocketsClient.kt", "data/pockets/ListeningPocketsCollections.kt", "data/collections/CollectionFlattener.kt")
            + t("data/pockets/ListeningPocketsModelsTest.kt", "data/pockets/ListeningPocketsClientTest.kt", "data/pockets/ListeningPocketsCollectionsTest.kt", "data/collections/CollectionFlattenerTest.kt"),
      deps=["COL-1", "GM-5"], est=1300, prio="P2", rank=64),

    P("COL-17", "collections", src=["LP-2"], partial=["LP-1@browse"],
      title="ListeningPocketsService (upload cadence, results cache, cursors/flushEpoch, delete cascade) + PlayOutcome listener + opt-in gate + real PocketsBridge for In the Pocket",
      files=m("data/pockets/ListeningPocketsService.kt", "data/pockets/PocketsPlayListener.kt", "data/pockets/LivePocketsBridge.kt", "data/location/ListeningContext.kt", "data/pockets/PocketsSettings.kt", "di/CollectionsGraph.kt")
            + t("data/pockets/ListeningPocketsServiceTest.kt", "data/pockets/PocketsPlayListenerTest.kt", "data/pockets/LivePocketsBridgeTest.kt"),
      deps=["COL-16", "PB-5", "BRW-13", "GM-7"], est=1500, prio="P2", rank=78,
      acc=["Service is inert (zero network calls) until the REC credentials seam is non-null; GM-7's PocketsBridge contract is satisfied and the In the Pocket opt-in state flips"]),

    P("COL-18", "collections", src=["LP-3"], partial=["LP-1@browse"],
      title="History ▸ Pockets screen (Recurring/Recent, patterns, detail: features/harmonic/when/songs, Play, Save as playlist, opt-in offer, device re-labelling)",
      files=m("screens/history/ListeningPocketsScreen.kt", "screens/history/ListeningPocketDetailScreen.kt", "screens/history/ListeningPocketLabeler.kt", "screens/history/HistoryScreen.kt")
            + t("screens/history/ListeningPocketLabelerTest.kt", "screens/history/PocketsTabGateTest.kt"),
      shared=[M + "screens/history/HistoryScreen.kt (Pockets tab slot)"],
      deps=["COL-17", "BRW-6"], est=1200, prio="P2", rank=82),

    P("COL-19", "collections", src=["LOC-1"],
      title="Listening places engine + location store (pure port, no platform APIs)",
      files=m("data/location/ListeningPlaceEngine.kt", "data/location/ListeningPlacesStore.kt", "data/location/ListeningContext.kt") + [R + "xml/backup_rules.xml"]
            + t("data/location/ListeningPlaceEngineTest.kt", "data/location/ListeningPlacesStoreTest.kt"),
      deps=["COL-17"], est=1500, prio="P2", rank=84),

    P("COL-20", "collections", src=["LOC-2"],
      title="Android location source (fused low-power + dwell detection) + Settings rows + wiring (default OFF, erased on disable)",
      files=m("data/location/FusedVisitSource.kt", "data/location/DwellDetector.kt", "screens/settings/sections/ListeningLocationSection.kt", "data/location/LocationSettings.kt", "di/CollectionsGraph.kt") + [MANIFEST]
            + t("data/location/DwellDetectorTest.kt"),
      deps=["COL-19"], est=900, prio="P2", rank=94,
      device="Real movement/dwell; emulator uses `adb emu geo fix` sequences."),

    # ───────────────────────────── BROWSE ─────────────────────────────
    P("BRW-1", "browse", src=["BRW-1"],
      title="Full filter/sort clause engine (18 fields, 5 ops) as pure BrowseEngine.filterSort + persistence migration",
      files=m("screens/browse/BrowseFilter.kt", "screens/browse/BrowseEngine.kt", "screens/browse/BrowseSort.kt", "screens/browse/BrowseModels.kt", "data/settings/BrowseSnapshot.kt",
              "screens/browse/BrowseSessionPersistence.kt", "screens/browse/BrowseScreen.kt")
            + t("screens/browse/FilterEngineTest.kt", "screens/browse/BrowseEngineTest.kt", "screens/browse/BrowseSessionPersistenceTest.kt"),
      deps=[], est=1400, prio="P0", rank=0),

    P("BRW-2", "browse", src=["BRW-2"],
      title="Filter/sort sheets at full width + membership (in/not-in, none-of) + favorite + hide-skips read-time layers",
      files=m("screens/browse/BrowseFilterSheet.kt", "screens/browse/ClauseEditor.kt", "screens/browse/MembershipSection.kt", "screens/browse/ReadTimeFilters.kt", "screens/browse/BrowseModels.kt", "screens/browse/BrowseScreen.kt")
            + t("screens/browse/ReadTimeFiltersTest.kt", "screens/browse/MembershipFilterTest.kt"),
      deps=["BRW-1", "COL-10", "PB-5"], est=1100, prio="P0", rank=8),

    P("BRW-3", "browse", src=["EXPL-1"],
      title="Explicit/edition system (SongVariant, EditionPolicy, clean-only) + streaming-link and dateAdded index fields",
      files=m("data/catalog/IndexModels.kt", "data/edition/SongVariant.kt", "data/edition/EditionPolicy.kt", "data/edition/EditionSettings.kt", "screens/settings/sections/EditionSection.kt", "data/rips/PlayResolver.kt", "di/BrowseGraph.kt")
            + t("data/edition/EditionPolicyTest.kt", "data/catalog/IndexModelsAdditiveFieldsTest.kt"),
      shared=[M + "data/rips/PlayResolver.kt (edition pick before resolve)"],
      deps=["SURF-1"], est=700, prio="P0", rank=2),

    P("BRW-4", "browse", src=["BRW-3", "LYR-1"],
      title="Song/Album detail parity: lyrics store + timed-lyrics sidecar + lyrics panel, share text, shuffle, artist-kind polish",
      files=m("data/lyrics/LyricsStore.kt", "data/lyrics/TimedLyricsSidecar.kt", "data/share/ShareText.kt", "screens/browse/SongDetailSheet.kt", "screens/browse/AlbumDetailScreen.kt", "screens/browse/BrowseSortSheet.kt",
              "data/storage/StorageService.kt", "di/BrowseGraph.kt")
            + t("data/lyrics/LyricsStoreTest.kt", "data/lyrics/TimedLyricsSidecarTest.kt", "data/share/ShareTextTest.kt"),
      shared=[M + "data/storage/StorageService.kt (LYRICS cache category)"],
      deps=["BRW-3", "BRW-1"], est=1300, prio="P0", rank=7),

    P("BRW-5", "browse", src=["SRCH-1"],
      title="Online OpenSearch (aoss) search: device↔online toggle, SigV4-signed direct queries, clause/sort translation, server paging, credential rows",
      files=m("data/search/SearchConfig.kt", "data/search/SearchService.kt", "data/search/OnlineSearchModel.kt", "data/search/SearchSettings.kt", "screens/settings/sections/OnlineSearchSection.kt",
              "screens/browse/OnlineResults.kt", "screens/browse/BrowseScreen.kt", "di/BrowseGraph.kt")
            + t("data/search/SearchServiceTest.kt", "data/search/OnlineSearchModelTest.kt", "data/search/FilterQueryTranslationTest.kt"),
      deps=["BRW-1", "SVC-5"], est=1400, prio="P0", rank=9),

    P("BRW-6", "browse", src=["HIST-2"],
      title="History screen parity: tab model (Playback | Collection | Pockets | For You slots), engine-backed timeline, row chrome, rewind-to-here, hide-skips",
      files=m("screens/history/HistoryScreen.kt", "screens/history/HistoryRows.kt", "screens/history/HistoryBrowseState.kt", "screens/history/Rewind.kt", "screens/history/HistoryRowMenu.kt", "data/history/HistorySettings.kt", "di/BrowseGraph.kt")
            + t("screens/history/HistoryBrowseStateTest.kt", "screens/history/RewindTest.kt"),
      deps=["BRW-1", "BRW-2", "PB-5", "PB-1"], est=1800, prio="P0", rank=10),

    P("BRW-7", "browse", src=["HIST-3"],
      title="Collection timeline (F8) + timeline cue store + History ▸ Collection tab",
      files=m("data/timeline/CollectionTimeline.kt", "data/timeline/TimelineCueStore.kt", "screens/history/CollectionTimelineScreen.kt", "screens/history/HistoryScreen.kt")
            + t("data/timeline/CollectionTimelineTest.kt", "data/timeline/TimelineCueStoreTest.kt"),
      deps=["BRW-3", "BRW-6", "COL-12"], est=1200, prio="P1", rank=35),

    P("BRW-8", "browse", src=["REC-1"],
      title="Recs core A: SimilarityFamilies, Similarity profile, TimbreCatalog (timbrePrior=2 load-bearing)",
      files=m("data/recs/SimilarityFamilies.kt", "data/recs/Similarity.kt", "data/recs/TimbreCatalog.kt", "data/catalog/CatalogService.kt") + [TR + "recs/timbre-fixture.json", TR + "recs/similarity-parity.json"]
            + t("data/recs/SimilarityParityTest.kt", "data/recs/TimbreCatalogTest.kt"),
      deps=[], est=1600, prio="P1", rank=11),

    P("BRW-9", "browse", src=["REC-2"],
      title="Recs core B: identity + shaping (version/recording identity, membership, novelty, composition, sound admit, audio shortlist)",
      files=m("data/recs/RecIdentity.kt", "data/recs/RecShaping.kt") + [TR + "recs/version-identity-cases.json"] + t("data/recs/RecIdentityTest.kt", "data/recs/RecShapingTest.kt"),
      deps=[], est=1500, prio="P1", rank=11),

    P("BRW-10", "browse", src=["REC-3"],
      title="ZoneEngine: In Da Zone + collection suggestions + cloud shaping",
      files=m("data/recs/ZoneEngine.kt", "data/recs/ZoneCatalog.kt") + [TR + "recs/zone-fixture-catalog.json"] + t("data/recs/ZoneEngineTest.kt", "data/recs/ZoneParityTest.kt"),
      deps=["BRW-8", "BRW-9", "PB-5"], est=2400, prio="P1", rank=28),

    P("BRW-11", "browse", src=["REC-4"],
      title="For You feed store, feedback store, read-time refresh schedule, tiles/grid, recsEnabled toggle plumbing, collection recs",
      files=m("data/recs/ForYouFeed.kt", "data/recs/ForYouFeedStore.kt", "data/recs/ForYouRefreshSchedule.kt", "data/recs/ForYouTiles.kt", "data/recs/ForYouGrid.kt", "data/recs/RecFeedbackStore.kt",
              "data/recs/ForYouSettings.kt", "data/collections/CollectionsRecs.kt", "di/BrowseGraph.kt")
            + t("data/recs/ForYouFeedStoreTest.kt", "data/recs/ForYouRefreshScheduleTest.kt", "data/recs/RecFeedbackStoreTest.kt", "data/recs/ForYouGridTest.kt"),
      deps=["BRW-10", "COL-2"], est=2000, prio="P1", rank=37),

    P("BRW-12", "browse", src=["REC-5"],
      title="For You UI: History ▸ For You tab, tiles grid, song list, feedback buttons, recs toggle, Settings ▸ For You",
      files=m("screens/foryou/ForYouTilesScreen.kt", "screens/foryou/ForYouSongListScreen.kt", "screens/foryou/RecFeedbackButtons.kt", "screens/foryou/CollectionRecsToggle.kt", "screens/foryou/ForYouRoutes.kt",
              "screens/settings/sections/ForYouSection.kt", "screens/history/HistoryScreen.kt", "di/BrowseGraph.kt")
            + t("screens/foryou/ForYouTileLayoutTest.kt"),
      deps=["BRW-11", "BRW-6"], est=1700, prio="P1", rank=44),

    P("BRW-13", "browse", src=["REC-6"],
      title="Cloud recommendation engine service + client + rec key (device-local) + Settings ▸ Recommendations + Suggested collections + shared credentials seam",
      files=m("data/recs/RecModels.kt", "data/recs/RecEngineClient.kt", "data/recs/RecommendationService.kt", "data/recs/RecsSettings.kt", "data/config/Endpoints.kt",
              "screens/settings/sections/RecommendationsSection.kt", "screens/browse/SongDetailSheet.kt", "di/BrowseGraph.kt")
            + t("data/recs/RecEngineClientTest.kt", "data/recs/RecommendationServiceTest.kt"),
      shared=[M + "data/config/Endpoints.kt (rec-engine base)"],
      deps=["BRW-11", "PB-5"], est=2200, prio="P1", rank=46),

    P("BRW-14", "browse", src=["REC-7"],
      title="New releases feed + screen + release streaming (am:<storeId> rows through the AM resolver)",
      files=m("data/recs/ReleaseFeedModels.kt", "data/recs/ReleaseFeedService.kt", "data/recs/ReleaseStreaming.kt", "data/recs/AlbumOwnership.kt", "screens/foryou/NewReleasesScreen.kt", "di/BrowseGraph.kt")
            + [TR + "recs/artists-latest-release.json"] + t("data/recs/ReleaseFeedServiceTest.kt", "data/recs/AlbumOwnershipTest.kt"),
      deps=["BRW-12", "BRW-3", "SVC-15", "PB-8"], est=2200, prio="P2", rank=86),

    P("BRW-15", "browse", src=["DISC-1"],
      title="Discover tab: Apple Music catalog search (SVC-15) ∥ rip-server /search, Songs|Albums scope, refine by artist",
      files=m("screens/discover/DiscoverModels.kt", "screens/discover/DiscoverSearchModel.kt", "screens/discover/DiscoverResultsList.kt", "screens/discover/DiscoverAlbumResultsList.kt", "data/rips/RipServerClient.kt",
              "screens/browse/BrowseModels.kt", "screens/browse/BrowseScreen.kt", "di/BrowseGraph.kt")
            + t("screens/discover/DiscoverSearchModelTest.kt", "screens/discover/DiscoverMergeTest.kt"),
      shared=[M + "data/rips/RipServerClient.kt (/search only)"],
      deps=["BRW-5", "SVC-15"], est=1500, prio="P1", rank=48),

    P("BRW-16", "browse", src=["DISC-2"],
      title="Discover ＋Add: provisional catalog entries, album fan-out, supersede, Remove from Library",
      files=m("data/discover/DiscoverAddsStore.kt", "data/discover/DiscoverAddState.kt", "data/discover/ProvisionalSource.kt", "data/catalog/CatalogRepository.kt", "data/activity/ActivityModels.kt",
              "screens/discover/DiscoverAddController.kt", "screens/browse/SongDetailSheet.kt", "di/BrowseGraph.kt")
            + t("data/discover/DiscoverAddsStoreTest.kt", "data/discover/SupersedeTest.kt"),
      shared=[M + "data/catalog/CatalogRepository.kt (provisional source)", M + "data/activity/ActivityModels.kt (discover-add activity kind)"],
      deps=["BRW-15", "COL-2"], est=2000, prio="P1", rank=52),

    P("BRW-17", "browse", src=["SHZ-1"],
      title="'?♪?' recognizer: vendored ShazamKit-for-Android AAR + AudioRecord + catalog match + result sheet + Apple Music actions (add / rip+burn)",
      files=m("screens/shazam/ShazamRecognizer.kt", "screens/shazam/ShazamCatalogMatch.kt", "screens/shazam/AppleMusicRecognition.kt", "screens/shazam/ShazamButton.kt", "screens/shazam/ShazamResultSheet.kt",
              "screens/settings/sections/AppleMusicRecognitionSection.kt", "screens/browse/BrowseScreen.kt", "di/BrowseGraph.kt") + ["android/app/libs/shazamkit-android.aar", GRADLE]
            + t("screens/shazam/ShazamCatalogMatchTest.kt", "screens/shazam/RecognitionActionReducerTest.kt"),
      deps=["BRW-16", "SVC-2", "SVC-11"], est=1500, prio="P1", rank=56,
      device="Live recognition needs a microphone + the vendored AAR's native libs; the matcher and action reducer are JVM-tested."),
]
