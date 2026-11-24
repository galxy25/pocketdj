state: implemented

## Summary
- `PocketMomentCache` (data/pockets/wheel): StateFlow<PocketWheelSnapshot>; `attach(revisions)` debounces 5 s then rebuilds on Dispatchers.Default (collectLatest cancels a stale build); persists device-local `pocketdj-pocket-wheel-cache.json` (atomic write, instant paint at construction, always one rebuild per launch); folds into the palette (frees slots of collections absent from `liveCollectionIds`, fav_songs kept); `makeInput` adds the `fav_songs` pseudo-collection from FavoritesStore. `clearLocal()` bumps a generation so an in-flight build can never resurrect the wheel.
- `PocketsGraph` (di): 9th FeatureModule ("pockets"), wires all seams, `wheelClearLocal()` (registered clearers, cache, palette), `registerWheelClear {}` for the run store / motion timeline packages, resetHook.
- Delete history (StorageService clearPlayHistory in AppGraph) and account deletion (module resetHook, already iterated by AccountDeletionService localStores) call it.

## Tests
15 new (PocketMomentCacheTest). Full suite: 6418 tests, 0 failures; :app:assembleDebug green.

## Deviations / touched outside owned files
- AppGraph.kt: pocketsGraph lazy + in features list; clearPlayHistory also wheelClearLocal; INTENT_SINK step also starts the wheel watcher (no new StartStep, so StartupPlan tests untouched).
- CollectionsGraph.kt: `pocketsCollectionsInput()` private -> public (reused for the wheel).
- An empty build deletes the cache file instead of writing it (so Delete history leaves no file; iOS would write an empty snapshot).
- Motion timeline / opt-in / run store do not exist yet: they must call `pocketsGraph.registerWheelClear`.
- assembleRelease not run (no manifest/gradle/proguard/library change).

## Questions for Levi
None.
