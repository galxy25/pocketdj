# Settings ▸ Storage — Android P2-addenda implementation contract

Extracted from the iOS app in this worktree. Every claim cites `apple/…` or
`android/…` file:line, or a named SDK class. Format mirrors the existing
`android/specs/*.md` (see `history.md`).

Scope: a **Storage** screen reachable from Settings that (a) shows measured
on-disk usage per category with human-readable sizes, and (b) offers per-category
**Clear** actions wired to the real Android stores/caches — never touching the
settings DataStore or the install identity. This is the **Android cut** of the
iOS storage manager; the iOS-specific machinery it deliberately drops is
enumerated in §5 (Deferred).

---

## 1. iOS reference: what Settings ▸ Storage is

`apple/PocketDJ/Views/StorageView.swift` is one `Form` screen
(`StorageView.swift:45-128`) whose job is (its own header doc,
`StorageView.swift:4-12`): see what burned music + session recordings cost on
disk, pick where they live, delete downloaded media (by artist / by collection /
all), delete session recordings, and set a soft storage cap the once-a-day prune
enforces. The invariant repeated throughout: **every delete removes DOWNLOADED
media only — songs stay in the catalog and in every pocket/playlist/set list, and
can be burned again** (`StorageView.swift:11-12,376-378`).

The iOS sections, top to bottom (`StorageView.swift:46-62`):

| Section | iOS source | Android disposition |
|---|---|---|
| Usage: burnt music + session recordings (count · bytes) | `:137-158` | **Reshaped** — Android has no burns/recordings; §2 measures the categories Android actually has |
| Burnt-music folder picker | `:182-208` | **Deferred** (§5) — no burns store, no SAF folder model |
| Mix-session folder picker | `:216-242` | **Deferred** (§5) — no recordings |
| Soft storage cap + Prune now | `:271-336` | **Deferred** (§5) — the cap prunes burns; no burns store to prune |
| Delete downloaded music (by artist / collection / all) | `:340-379,619-770` | **Deferred** (§5) — no burns store |
| Delete session recordings | `:383-416` | **Deferred** (§5) — no recorder |
| Producer studio usage + folders + delete | `:423-611` | **Deferred** (§5) — no Producer tab on Android |

Almost every iOS control is bound to `BurnStore` (downloaded media) or the mix
recorder — **neither exists on Android yet** (`android/di/AppGraph.kt` has no burn
or recording store). So the Android Storage screen keeps the iOS *shape and copy
doctrine* (measured usage rows + destructive-but-safe clears + "your library is
never touched" reassurance) but points it at the caches/docs Android does have.

### iOS behaviors that ARE parity-load-bearing (carry them over)

- **Measured on appear + re-measured after every mutation.** iOS measures in
  `refreshUsage()` on `.task` and after each delete/prune
  (`StorageView.swift:67-76,160-170`). Android: measure on screen entry (off the
  main thread) and re-measure after each Clear.
- **Human byte formatting.** iOS uses
  `ByteCountFormatter.string(fromByteCount:countStyle:.file)`
  (`StorageView.swift:172-175,645`) — decimal (1000-based) units, "12.3 MB".
  Android parity: `android.text.format.Formatter.formatFileSize(context, bytes)`
  (also decimal/SI). Never hand-roll unit math.
- **"—" placeholder before measurement.** iOS renders `—` when the byte count is
  still `nil` (`StorageView.swift:173`). Android: show a placeholder until the
  first async measure resolves.
- **Delete never destroys user identity or library.** iOS clears download files
  only, keeping the catalog + collections (`StorageView.swift:11-12`). Android's
  transcription of this invariant: **a Clear never deletes the settings DataStore
  (`pocketdj-settings.preferences_pb`) and never regenerates the install id.**
  History/activity clears explicitly KEEP `installId` (§3).
- **Confirmation on every destructive action.** iOS gates each delete behind a
  `confirmationDialog` (`StorageView.swift:363-373,390-410`). Android: an
  `AlertDialog` per Clear (the existing Settings pattern,
  `SettingsScreen.kt:334-394`).
- **Enable-while-anything-clearable.** iOS enables a delete button while a byte
  count remains even if the logical count is 0, so orphaned bytes are always
  reclaimable (`StorageView.swift:362,546`). Android: enable a Clear when its
  measured bytes > 0 (never grey out a non-empty cache).

---

## 2. The Android categories — what to measure and how

Five rows. Each is real on-disk state owned by an existing Android store/cache.
All measured sizes are **bytes on disk**; all clears re-measure immediately after.

### 2.1 Catalog index cache

- **What:** the offline-first catalog cache — one `<sha256(url)>.json` (raw index
  bytes, the ~33 MB documents) plus a sibling `<sha256>.meta.json` validators
  file per source, and any `.part` temp mid-refresh
  (`android/data/catalog/CatalogService.kt:52-54,89,149`).
- **Directory:** `filesDir/catalog-cache/` (`android/di/AppGraph.kt:67-68`).
- **Measure:** recursive sum of file lengths in the directory
  (`dir.walkBottomUp().filter { it.isFile }.sumOf { it.length() }`), off the main
  thread. Directory may not exist yet → 0.
- **Clear:** `graph.catalogService.clearCache()` — deletes every file in the dir
  (`CatalogService.kt:131-134`). This is exactly the existing Settings "Clear
  cache" store call (`SettingsScreen.kt:349`), but here it should **not**
  auto-refresh the catalog (Storage is a cost view; leave refetch to the user /
  next launch). Re-derivable: the next catalog load refetches.
- **Safety:** re-derivable cache; destroys no user content.

### 2.2 Artwork cache (Coil)

- **What:** Coil's image disk + memory cache — album/song artwork thumbnails
  fetched by `coil.compose.AsyncImage` (`android/screens/browse/BrowseComponents.kt:25`,
  `android/screens/history/HistoryScreen.kt:70`). No custom `ImageLoaderFactory`
  is registered (no Application subclass — `android/app/src/main/AndroidManifest.xml`
  sets no `android:name`), so `AsyncImage` resolves the **default singleton**
  `ImageLoader`; its default disk cache lives at `context.cacheDir/image_cache/`.
- **Handle:** `context.imageLoader` (Kotlin extension, import `coil.imageLoader`)
  → the same singleton `AsyncImage` populates.
- **Measure:** read Coil's own counters — **do not walk the directory**:
  `coil.disk.DiskCache.getSize(): Long` (bytes on disk) via
  `context.imageLoader.diskCache?.size` (verified in `coil-base-2.7.0`:
  `DiskCache.size:Long`, `maxSize:Long`, `directory:okio.Path`, `clear()`).
  Optionally add `MemoryCache.size:Int` (bytes) but the disk figure is the
  user-meaningful one; spec the disk size as the row value, `null`/0 when
  `diskCache` is absent.
- **Clear:** `context.imageLoader.apply { diskCache?.clear(); memoryCache?.clear() }`
  (`coil.disk.DiskCache.clear()`, `coil.memory.MemoryCache.clear()`). Re-derivable:
  artwork refetches on next display.
- **Safety:** re-derivable cache; destroys no user content.

### 2.3 Collections document — MEASURED-ONLY (no Clear)

- **What:** `pocketdj-collections.json` — the user's pockets / playlists /
  setlists / folders (`android/data/collections/CollectionsStore.kt:1485`,
  `FILE_NAME`), a single file in `filesDir` (`android/di/AppGraph.kt:126`).
- **Measure:** `File(filesDir, CollectionsStore.FILE_NAME).let { if (it.isFile) it.length() else 0L }`.
- **Clear: NONE.** This row is **display-only** (a size figure, no button).
  Rationale — this is the parity-correct call and a **locked decision**: this
  document is irreplaceable **user-created content**, not a cache. iOS's storage
  manager *never* destroys collections — it deletes downloaded media and keeps
  every collection intact (`StorageView.swift:11-12,376-378,730`). A one-tap
  "wipe all your playlists" has no iOS analogue and is a footgun. `CollectionsStore`
  *has* a `clear()` (`CollectionsStore.kt:1342-1354`) but it is a test/reset seam,
  **not** to be surfaced here.
- Show the size for transparency ("this is what your library metadata costs"), so
  the user understands the total; offer no destructive action.

### 2.4 Play-history document

- **What:** `pocketdj-play-history.json` — the append-only play log
  (`android/data/history/PlayHistoryStore.kt:261`, capped at 20 000 events),
  single file in `filesDir`.
- **Measure:** `File(filesDir, PlayHistoryStore.FILE_NAME).length()` (0 when absent).
- **Clear:** `PlayHistoryStore.get(context).clear()` — wipes events but **KEEPS
  `installId`** (`PlayHistoryStore.kt:152-159`; the clear sets
  `salvagePending=false`, rebuilds empty indexes, publishes, saves). This is the
  same store call the existing Settings "Clear play history" already uses
  (`SettingsScreen.kt:381`). `clear()` does synchronous file IO → run off-main
  (`Dispatchers.Default`), exactly as Settings does (`SettingsScreen.kt:379-382`).
- **Safety:** destroys the play timeline only; identity + settings + collections
  untouched. (This deliberately **duplicates** the affordance already in the
  Settings root, §4.)

### 2.5 Collection-activity document

- **What:** `pocketdj-collection-activity.json` — the History ▸ Activity log
  (add/remove events; `android/data/activity/CollectionActivityStore.kt:211`,
  `FILE_NAME`), single file in `filesDir` (`android/di/AppGraph.kt:116`).
- **Measure:** `File(filesDir, CollectionActivityStore.FILE_NAME).length()` (0 when absent).
- **Clear:** `graph.collectionActivity.clear()` — resets the in-memory log and
  deletes the file (`CollectionActivityStore.kt:130-137`, keeps `installId` in the
  fresh state). Blocking-ish IO → off-main.
- **Safety:** destroys the activity timeline only; the collections it references
  are untouched.

### Row order & grouping

Group as iOS does — one "usage" cluster with reassurance footer text. Suggested
order: Catalog cache · Artwork cache · Collections · Play history · Activity.
Caches (re-derivable) first, then user docs. Total-on-device line optional.

---

## 3. The clear contract (iron rules)

1. **Never** delete `filesDir/pocketdj-settings.preferences_pb` (the settings
   DataStore, `android/di/AppGraph.kt:62`) or the jukebox prefs
   (`pocketdj-jukebox.preferences_pb`, `JukeboxGraph.kt:30`). No clear on this
   screen touches DataStore.
2. **Never** regenerate the install id. History/activity `clear()` both preserve
   `installId` by construction (`PlayHistoryStore.kt:152-159`,
   `CollectionActivityStore.kt:130-137`); do not add any path that mints a new one.
3. **Collections doc is display-only** (§2.3). No Clear button.
4. Every Clear is behind an `AlertDialog` confirmation; after confirm, run the
   store/cache call off the main thread, then re-measure that row (and optionally
   all rows).
5. Additive-optional persistence is untouched here — this feature adds **no** new
   on-disk document. It only measures + clears existing ones. (No schema change,
   so the iron law in the ground rules is trivially satisfied.)

---

## 4. Relationship to the existing Settings rows

`SettingsScreen.kt` already exposes two of these actions inline: **Clear cache**
(catalog, `:173,349`) and **Clear play history** (`:306,381`). The Storage screen
is a superset that adds *measured sizes* + the Coil/activity categories. Decision
(locked): **keep both** — leave the two existing Settings rows as-is (they're the
quick path), and add the Storage screen as the full accounting view. This mirrors
iOS, where the folder pickers moved *into* Storage but the app kept quick actions
elsewhere; do **not** rip the two rows out of Settings for this cut (smaller diff,
no regression to the shipped Settings UI/tests).

### Navigation

Add a Storage entry point from Settings. Settings is reached via
`SETTINGS_ROUTE = "settings"` (`android/MainActivity.kt:78,154,291`). Add a
sibling route `"settings/storage"` (a `composable` in the same `NavHost`) with a
row/button in `SettingsScreen` that navigates to it; the top-bar title map
(`MainActivity.kt:122-133`) gets a `"settings/storage" -> "Storage"` case, and the
back-arrow already appears for any non-tab route (`MainActivity.kt:118-120`).
`SettingsScreen` currently takes no nav callback — thread an `onOpenStorage: () ->
Unit` param (or pass the `NavController`) the way other detail navigations are
wired.

---

## 5. Deferred (no Android backing yet) — note, do not build

State each in the UI only as far as parity honesty requires (i.e. **omit** the
sections entirely rather than show dead controls):

- **Downloaded / burnt music** (usage, delete by artist / by collection / all):
  bound entirely to iOS `BurnStore` (`StorageView.swift:132,161,340-379,619-770`).
  **No Android burns store exists** (`android/di/AppGraph.kt` — none). Omit.
- **Session recordings** (`StorageView.swift:383-416`): bound to `MixSessionStore`
  / `MixRecorder`. No Android recorder. Omit.
- **Soft storage cap + daily LRP prune + "Prune now"**
  (`StorageView.swift:271-336`, engine `apple/PocketDJ/State/StorageManager.swift`,
  ordering signal `apple/PocketDJ/State/PlayStatsStore.swift`): the prune evicts
  **burned** media LRP-first (`StorageManager.swift:58-101`); with no burns store
  there is nothing to prune. **Also note:** Android has **no `PlayStatsStore`
  equivalent** — the play *log* (`PlayHistoryStore`) exists, but the aggregate
  count+last-played map the prune orders by (`PlayStatsStore.swift:20-24,82-83`)
  is not built on Android (already flagged non-P1 in `android/specs/history.md:16-18`).
  Omit the cap section. When burns land later, the cap + `PlayStatsStore` come with
  them.
- **Burnt-music / mix-session folder pickers** (`StorageView.swift:182-242`):
  security-scoped bookmarks over user folders — an iOS/macOS model; on Android
  this is Storage Access Framework, and there is no burn/recording content to
  relocate. Omit.
- **Producer studio** usage/folders/delete (`StorageView.swift:423-611`): no
  Producer tab on Android. Omit.

The Android screen therefore ships **five measured rows** (§2), with clears on
four of them (all but collections).

---

## 6. Emulator-verifiable vs device-only

Everything in this cut is **emulator-verifiable** — no device-only hardware,
background tasks, or entitlements are involved:

- **Measure:** boot the pocketdj AVD, browse (populates Coil artwork cache + loads
  catalog cache), play songs (writes play-history), add/remove a collection item
  (writes activity + collections). Open Settings ▸ Storage → each row shows a
  non-zero human size. Screenshot.
- **Clear:** tap a Clear, confirm, verify the row drops to a placeholder / ~0 and
  the underlying file/dir is gone (`adb shell run-as com.levi.pocketdj ls
  files/` and `.../cache/image_cache`). Verify Settings DataStore
  (`files/pocketdj-settings.preferences_pb`) and collections doc still present, and
  that `PlayHistoryStore.installId` is unchanged across a history clear.
- No device-only aspects (unlike iOS's BGTask daily prune, which would be
  device/background-only — but that's deferred anyway, §5).

---

## 7. Android module sketch

```
com.levi.pocketdj
├── screens/settings/
│   ├── SettingsScreen.kt        // + onOpenStorage nav param, "Storage" row
│   └── StorageScreen.kt         // NEW — §2 rows + §3 clears (Compose, Material 3)
└── (no new data/ files — reuses CatalogService, coil.imageLoader,
     CollectionsStore, PlayHistoryStore, CollectionActivityStore)
```

`StorageScreen` responsibilities:
- Hold five `mutableStateOf<Long?>` byte counts, `null` until measured.
- `LaunchedEffect`/`rememberCoroutineScope` → measure all off `Dispatchers.Default`
  on entry; re-measure the affected row after each Clear.
- Directory-size helper (catalog): `walkBottomUp().filter{isFile}.sumOf{length()}`.
- Coil size via `context.imageLoader.diskCache?.size` (Long, bytes).
- Human size via `android.text.format.Formatter.formatFileSize(context, bytes)`.
- One `AlertDialog` per clearable row (Catalog · Artwork · History · Activity),
  copy modeled on iOS "downloaded/derivable content removed; library & settings
  kept" (`StorageView.swift:371-377`).

### Tests to write (encode the contract)

- Measuring an empty `filesDir`/cache dir yields 0, not a crash (missing dir).
- Catalog clear removes `catalog-cache/*` and re-measure → 0
  (`CatalogService.clearCache()`).
- History clear empties events but `installId` is **unchanged**
  (`PlayHistoryStore.clear()` — `PlayHistoryStore.kt:152-159`).
- Activity clear empties events, file deleted, install id preserved
  (`CollectionActivityStore.clear()`).
- Collections doc row has **no** clear path (compile-time: no CollectionsStore
  mutation reachable from StorageScreen).
- A clear never edits the settings DataStore (no `AppSettingsStore` write from the
  screen).
- Byte formatting returns a non-empty human string for a known size.
```
