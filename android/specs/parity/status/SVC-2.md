state: reviewed

# SVC-2 BurnStore core (ONE offline store)

- [x] BurnModels (BurnItem/BurnDocument/PendingBurn in the iOS field set; BurnState lowercase raw values), BurnFolder (AppPrivateBurnFolder = filesDir/burns; interface for SAF later)
- [x] BurnFileNames (byte-identical sanitize 40 / prefix 150 grapheme-aware, analog/digital prefixes, idToken, stableIdSuffix, cut name, stem-/analysis- names, aux parsing)
- [x] BurnSidecar (header order, em-dash placeholders, Foundation-style sorted pretty Raw JSON, parseForAdoption), BeatGridSidecar (validated parse)
- [x] BurnStore: in-process serial burn loop, STOP at loop top, isFresh, not-ripped error items, disk-full abort, folder probe, analog shared write-once, cut export (+auto-repull), stems (all-or-nothing read, burnStems/burnStemPart, adoptStreamedStems w/ rollback, stemsRemote), beat-grid burn/validate, adoptStreamedFile, removeBurns (shared audio freed with LAST ref), removeAllBurns, sweepOrphanAuxFiles, adoptOrphanedBurns, usage/usageByArtist/approximateBytes/stem usage, planEviction, reconcileOnLaunch, pendingAfterRip (burnWhenRipped/cancel/drain: cleared only when burned > 0)
- [x] BurnReconciler (missing / poisoned <4 KB xml|html), EvictionPlanner (pure, one listing per root, aux credited from every root)
- [x] HttpBurnRips (plain client: no bearer to S3, non-2xx and 200-with-error-document rejected, atomic .part rename, presign 6 h + one retry, HEAD Last-Modified)
- [x] StorageService BURNS + STEMS categories (additive ctor params), StorageScreen meta copy, ServicesGraph.burnStore, AppGraph storage wiring + launch reconcile
- [x] Tests: 76 new JVM tests (BurnFileNames 11, Sidecar 5, BeatGrid 3, Reconciler 4, Eviction 5, BurnStore 24, Stems 11, HttpBurnRips 7, StorageServiceBurns 3, + support); full suite 1143 tests, 0 failures; assembleDebug green

## Deviations / files outside owned set
- New file data/burns/BurnRips.kt (the BurnRips seam + HttpBurnRips + isOutOfSpace) so BurnStore is JVM-testable; test support file BurnTestSupport.kt.
- di/AppGraph.kt: additive StorageService burn lambdas (BURNS excludes stems so the Storage total never double-counts) + a launch `reconcileOnLaunch()` after the onboarding gate.
- screens/settings/StorageScreen.kt: two new `when` branches (BURNS, STEMS) in storageCategoryMeta (exhaustive when).
- Analog shared file: improvement over iOS (which downloads then discards): reuse only when a READY ledger item referencing that file is at least as new as the manifest rippedAt; otherwise re-download (a re-ripped album is not silently stale).
- Not ported here: the background TransferCoordinator path (SVC-3), `ripThenBurn`/recognizer rip->burn lifecycle (recognizer is N/A; generic version belongs with the burn UI), `localUrlForPlayback` scope-release closures (no security-scoped folders on Android; plain File returned).
- `drainPendingAfterRip()` and `flush()` are not yet called from RipJobTracker.onRipReady / ON_STOP; the integrator/BURN-2 wires them (store API ready).
- localUrl* return java.io.File (callers convert to Uri); bytes/durationMs/startMs are Long.
- The iOS ledger fixture in BurnStoreTest is hand-built from the Swift Codable shape (no captured device file available).

## Questions for Levi
- None.

## Review
- Cf format chars in sanitizeToken -> fixed (Cf treated illegal; test added)
- Cancel drops prior READY record -> fixed (prior record restored; test added)
- pendingAfterRip never drained / flush never called -> fixed (launch drain in AppGraph, RipJobTracker.onRipReady drains, BurnStore.flush registered as ServicesGraph flushable)
- Blocking IO on caller dispatcher -> fixed (burn loop runs in withContext(io), injectable dispatcher). Non-suspend mutators (removeBurns, localUrl, init ledger read) remain IO calls; callers must use Dispatchers.IO (documented here).
- ARCHITECTURE-ANDROID.md ledger row -> rejected: the file is not in this package's owned set/was not present for edit by this package; status tracked here. Emulator steps pending (integrator owns the emulator). iOS fixtures are hand-built (noted above).
- StorageScreen/AppGraph touchpoints -> acknowledged: SVC-6 should build on the BURNS/STEMS StorageService categories added here (flagged); not removed to avoid breaking the exhaustive when.
- NIT localUrl memo race -> not fixed (optional). NIT corrupt ledger -> fixed (renamed to .corrupt-<ts>, test added).

fixes applied
