state: implemented

# SURF-4 — Deep links + file opens

- [x] DeepLinkParser (pure JVM, java.net.URI): jukebox / mwf (before jukebox) / play / album / artist / playlist / pocket / setlist / search, https App Link, file opens (.pdjcollection, .pocketdj.zip, .zip, MIME), diag key
- [x] PendingOpenStore (ordered, de-duplicated, atomic drain)
- [x] DeepLinkDispatcher + DeepLinkSeams; registered via ShellGraph.deepLinkHandlers (IntentSink path; MainActivity untouched)
- [x] Manifest: pocketdj scheme, autoVerify https jukebox.pocket-dj.com, collection MIME + extension filters
- [x] Tests: DeepLinkParserTest, PendingOpenStoreTest, DeepLinkDispatcherTest; suite 1089 green, assembleDebug green

## Notes / deviations
- ShellActions (SURF-5) and JoinedSessionsStore (JBX-2) do not exist yet, so the dispatcher uses replaceable seams (`ShellGraph.deepLinkSeams`: playItem, joinJukebox, importCollection, mwf). Defaults: play/join open the item's screen via NavRequestBus.post (resolver gives the iOS-style missing message); import shows "Import coming soon"; MwF parks in `deepLinks.pendingMwf`. SURF-5/JBX-2/SET-2/Games must assign the seams.
- The jukebox-join seam must add to JoinedSessionsStore AND open the join panel (acceptance); until JBX-2 it only routes.
- pocketdj scheme filter is scheme-only (covers host and host-less forms); parser validates verbs.
- DiagKey files are not consumed (SVC-5's handler does); dispatcher returns false for them.
- Dispatcher test file is DeepLinkDispatcherTest.kt (not in the owned list but named in unit_tests).
- Device-only: App Links verification (assetlinks.json on website), real browser banner.

## Questions for Levi
- Website needs /.well-known/assetlinks.json with the Android signing cert fingerprint for autoVerify.
