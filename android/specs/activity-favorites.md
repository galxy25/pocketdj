# Collection Activity + Favorites — Android Phase 2 implementation contract

Extracted from the iOS app in this worktree. Every claim cites `apple/…` file:line.
Scope: the **Activity** segment of History (iOS F11 — the append-only log of user
add / heart / unheart / remove acts on collections) and the **decision on favorites
(♥)** for Android P2. Companion to `specs/history.md` §7, which reserved this seam.

**P2 cut (the decision, up front):**

- **SHIP in P2:** `CollectionActivityStore` (the full 4-kind event schema),
  the `ActivityHook` seam on the Android collections store firing **add/remove**
  from the user-facing choke points, and the **live Activity segment** in
  `HistoryScreen` (replacing the P1 placeholder).
- **DEFER:** the favorites store (♥ toggle, Browse favorite filter, heart-in-
  collection-rows) — with the heart **seam stubbed** so heart/unheart events plumb
  straight in later with zero activity-store changes. Rationale in §6.

---

## 1. What the activity log is (and is not)

- A **device-local, append-only log of user collection acts**: every ADD of an item
  to a pocket/playlist, every ♥ / un-♥ of a song, every REMOVE of an item from a
  collection. It powers the Activity segment of History
  (`apple/PocketDJ/State/CollectionActivityStore.swift:4-7`).
- It is deliberately a **separate store from PlayHistoryStore**, not extra rows in
  the play log: PlayEvent is song-play-centric — its 30 s re-count window and the
  `countIndex`/`lastPlayedIndex` it maintains feed "recently played" reads, and an
  add/heart/remove has **no re-count window and no per-song aggregate**; bolting it
  onto PlayEvent would corrupt those reads
  (`CollectionActivityStore.swift:9-14`). Android mirrors this: a new store, a new
  file, zero wipe-risk to the play log.
- **User-only guarantee (the load-bearing invariant):** events are recorded ONLY
  for acts the user performs. Source-sync reconcile, document decode/seed, cloud
  pulls, and seeds never produce events
  (`apple/PocketDJ/State/CollectionsStore.swift:58-62`,
  `apple/PocketDJ/State/FavoritesStore.swift:78-83`). See §4 for the exact choke
  points.
- Shaped for a future cross-profile merge exactly like the play log: stable
  per-event UUID + a document `installId`; merge = union by event id, re-sort by
  `at` (`CollectionActivityStore.swift:17-19,151-158`). Android must preserve both
  identity fields even though no sync exists on Android
  (`docs/ARCHITECTURE-ANDROID.md:49-52`). Event ids travel **verbatim** — never
  case-normalize (iOS encodes UUIDs uppercase, Android's `UUID.toString()` is
  lowercase; both are fine, dedupe is exact-string).

---

## 2. On-disk document (local JSON, additive-optional)

iOS persists `pocketdj-collection-activity.json` in Application Support
(`CollectionActivityStore.swift:14,105-110`), written **atomically** on every
mutation (`CollectionActivityStore.swift:178-181`).

**Android file:** `filesDir/pocketdj-collection-activity.json`, temp-file + rename
atomic write, save synchronously-ordered after every mutation — the exact
`PlayHistoryStore.kt` idiom
(`android/app/src/main/java/com/levi/pocketdj/data/history/PlayHistoryStore.kt:237-257`).

### Document shape (iOS `CollectionActivityStore.Document`, `CollectionActivityStore.swift:60-77`)

```json
{
  "schemaVersion": 1,
  "installId": "<uuid-string>",
  "events": [ { …ActivityEvent… } ]
}
```

- `schemaVersion` — currently **1** (`let collectionActivitySchemaVersion = 1`,
  `CollectionActivityStore.swift:207`).
- `installId` — stable identity of THIS install, the merge attribution key;
  a fresh UUID when no readable document exists
  (`CollectionActivityStore.swift:62-63,94-103`).
- `events` — append-only, **oldest → newest** (`CollectionActivityStore.swift:79-80`).

**Lenient decode is field-by-field on iOS** (`CollectionActivityStore.swift:71-76`):
a missing `events` ⇒ `[]`, a missing `installId` ⇒ a fresh one, a missing/odd
`schemaVersion` ⇒ current, unknown keys ignored — an empty or forward-version file
loads degraded rather than resetting the store
(`CollectionActivityStore.swift:57-59`). Android: `PdjJson.lenient` + defaults on
every field (iron law — adding a field later must never wipe a saved doc).
Corrupt-JSON quarantine-to-`.bak` + transient-IO salvage: copy the
`PlayHistoryStore.kt` mechanism verbatim (`PlayHistoryStore.kt:59-97,188-235`) —
iOS silently falls back to empty here (`CollectionActivityStore.swift:96-102`),
but the Android history store already raised that bar and this store should match
its sibling.

### ActivityEvent shape (iOS `CollectionActivityStore.ActivityEvent`, `CollectionActivityStore.swift:44-54`)

| field | type | required | meaning |
|---|---|---|---|
| `id` | UUID string | yes | stable event identity (merge/dedupe key) |
| `at` | number (epoch **ms**, double) | yes | when the act happened (`:47`) |
| `kind` | string token | yes | `add \| heart \| unheart \| remove` (below) |
| `itemId` | string | yes | the song/album/child-pocket/studio id acted on |
| `itemTitle` | string | optional | display-title **snapshot at record time** (`:39-40`) |
| `collectionId` | string | optional | the pocket/playlist acted on; **nil for heart/unheart** (`:41-42`) |
| `collectionKind` | string | optional | `"pocket"` / `"playlist"` (`AddTarget.Kind` raw, `apple/PocketDJ/Models/CollectionsSchema.swift:513`); nil for hearts (`:52`) |
| `collectionName` | string | optional | collection-name **snapshot at record time** (`:39-40,53`) |

Snapshots exist so a row stays readable after the item leaves the catalog or the
collection is renamed/deleted (`CollectionActivityStore.swift:39-40`). A nil
`itemTitle` ⇒ the row falls back to the id (`:43`, §5 rendering).

### `kind` tokens — persisted raw values, NEVER rename

`add | heart | unheart | remove` (`CollectionActivityStore.swift:24-26`: "Raw
values are the persisted tokens — never rename"). Android: an enum with explicit
`@SerialName` per token — **define all four now** even though P2 emits only
`add`/`remove` (§6): the schema is the future-proof part, and rendering (§5) must
already handle all four so a future favorites slice / merged doc needs no
migration.

iOS icons per kind (`CollectionActivityStore.swift:29-36`): add `plus.circle`,
heart `heart.fill`, unheart `heart.slash`, remove `minus.circle`. Android nearest
Material equivalents: `AddCircleOutline` / `Favorite` / `HeartBroken` /
`RemoveCircleOutline`.

### Cap

**20 000 events**, drop the **oldest** past the cap
(`CollectionActivityStore.swift:91-92,134,173-176`). Same constant and trim
direction as the play log.

---

## 3. In-memory store contract

Android: `data/activity/CollectionActivityStore.kt`, a process-wide singleton
mirroring `PlayHistoryStore.kt`'s shape — internal lock, `StateFlow<State>` with
`(events, installId, revision)`, revision-keyed recompute
(`PlayHistoryStore.kt:34-57`).

State (iOS `CollectionActivityStore.swift:79-84`):

- `events: List<ActivityEvent>` — oldest → newest.
- `installId: String`.
- `revision: Int` — monotonic, bumped on **every real mutation**; the History view
  keys recompute on this (`:83-84`). (Not on `events.size` — pins at the cap.)
- **No derived indexes.** Unlike the play log there is no count/last-played index —
  the log is aggregate-free by design (`CollectionActivityStore.swift:12-13,150-151`).

### record() — the one write path (`CollectionActivityStore.swift:123-138`)

```
record(kind, itemId, itemTitle = null,
       collectionId = null, collectionKind = null, collectionName = null,
       atMs = now-epoch-ms): ActivityEvent?
```

1. `itemId` empty → ignore, return null (`:129`).
2. **No dedup window** — every user act is its own event (deliberate contrast with
   `PlayHistoryStore.record`'s 30 s window; adding one would eat a legitimate
   quick add-then-remove).
3. Append `ActivityEvent(id = new UUID, at = atMs, kind, itemId, itemTitle,
   collectionId, collectionKind, collectionName)` (`:130-133`).
4. If over cap, trim oldest (`:134`).
5. `revision += 1`; save (`:135-137`).

`atMs` is injectable for tests; production callers use the default now (`:123-128`).

### Other mutations

- `replaceAll(newEvents)` — test/merge seam: swap, re-cap, bump, persist
  (`CollectionActivityStore.swift:141-146`).
- `clear()` — deletes the on-disk file entirely (no residual empty JSON), resets
  events, **keeps installId**, bumps revision (`:160-169`). On iOS its only caller
  is account deletion (`apple/PocketDJ/Services/AccountDeletionService.swift:179`)
  — there is **no per-store Settings "clear activity" control**; Android matches
  (build the method for tests/future, wire no UI to it).
- `merge(with:)` / `reloadFromDisk()` — union-by-event-id cross-profile/cloud
  seams (`:151-158,195-204`). **No Android P2 counterpart** (no profile sync on
  Android, `docs/ARCHITECTURE-ANDROID.md:49-52`); don't build them. The UUID ids +
  installId in the doc are what keep them buildable later.

---

## 4. Choke points — WHO fires events, WHEN (the heart of this spec)

iOS keeps the store UI-agnostic: `CollectionsStore` exposes a nil-safe closure
seam `onActivity: ((ActivityHook) -> Void)?` wired at app init to
`CollectionActivityStore.record`
(`CollectionsStore.swift:56-63`, `apple/PocketDJ/PocketDJApp.swift:307-314`).
The hook payload mirrors the event minus id/timestamp
(`CollectionsStore.swift:65-74`).

**Android:** the P2 collections store exposes the same seam (a settable
`onActivity: ((ActivityHook) -> Unit)?` or equivalent), wired in `AppGraph`
(`android/app/src/main/java/com/levi/pocketdj/di/AppGraph.kt` — hand-rolled lazy
singletons; wire where the collections store is constructed). Keeping the seam —
rather than injecting the activity store into the collections store — preserves
iOS's unit-test property (a test sets a counting closure,
`CollectionsStore.swift:57-58`).

### ADD events — fired ONLY from the Add-to funnel

The **only** add emissions are in the `AddTarget`-wrapper methods — the funnel the
Add-to sheet and App Intents call:

- `addSong(_:to: AddTarget, repeatCount:)` → `emitAddActivity`
  (`CollectionsStore.swift:822-835`, emission `:834`)
- `addAlbum(_:to: AddTarget)` → `emitAddActivity`
  (`CollectionsStore.swift:836-844`, emission `:843`)
- `emitAddActivity` (`:850-854`): `kind=add`, `itemTitle` = catalog/studio title
  snapshot via `activityTitle` (`:812-817`: song name → album name → studio title →
  nil), `collectionId` = target id, `collectionKind` = `"pocket"`/`"playlist"`,
  `collectionName` = the **plain** collection name (`plainCollectionName`,
  `:856-863` — never the "Playlist › Chapter" form, so an ADD and REMOVE of the
  same list read consistently, `:846-849`).

**The low-level membership methods do NOT emit** — `addSong(toPocket:)`
(`:174-176`), `addAlbum(toPocket:)` (`:177-179`), `addSong(toPlaylist:)`
(`:270-275`), `addAlbum(toPlaylist:)` (`:276-278`), `addNode` (`:261-269`). This
is what makes the user-only guarantee cheap: reconcile and internal code call the
low-level paths freely.

**Consequence, verified:** an add into an **index-playlist mirror**
(`addSong(_:toIndexPlaylist:)`, `:467-486`) routes through the low-level
`addSong(toPlaylist:)` (`:476`) and therefore logs **no activity event** on iOS.
Android must reproduce this — do not "fix" it.

### REMOVE events — the five user-facing removal paths, each emitting exactly once

All via `emitRemoveActivity` (`:334-341`), which snapshots collection name
**before** mutation and resolves `itemTitle` via `activityTitle` unless overridden:

| path | emission | notes |
|---|---|---|
| `removeSong(_:fromPocket:)` | `CollectionsStore.swift:205-209` | name captured pre-mutation `:206` |
| `removeAlbum(_:fromPocket:)` | `:218-222` | |
| `removeChildPocket(_:fromPocket:)` | `:226-232` | itemId = child pocket id, itemTitle = child pocket's own name `:228,230-231` (the catalog can't name a pocket) |
| `removeNode(_:fromPlaylist:)` | `:321-329` | itemId = the node's songId ?? albumId ?? pocketId ?? nodeId, snapshotted **before** the mutation `:322-326`; a text/cue node falls back to nodeId |
| *(pocket/playlist DELETE)* | — | **no event**: `deletePocket` `:165-169` / `deletePlaylist` `:254-258` emit nothing — deleting a whole collection is not an item removal |

### NEVER-fire paths (the guarantee, verified)

`onActivity` is invoked at exactly two sites in the whole store — `:337`
(`emitRemoveActivity`) and `:851` (`emitAddActivity`). In particular
`reconcilePocket` (`:664`) and `reconcilePlaylist` (`:691`) — the source-sync
three-way merge that adds/removes members to follow Apple Music — mutate the
arrays directly and emit nothing (`:58-62`: "NEVER from source-sync reconcile …
or from a decode/seed"). Android: the sync/reconcile machinery (whatever P2
builds of it) must never route through the emitting funnel. **Unit-test this:**
a reconcile that adds and removes members produces zero activity events.

### HEART / UNHEART events — a different seam entirely (deferred, §6)

Hearts do **not** flow through the collections store
(`CollectionsStore.swift:61-62`: "HEART events are logged separately from the
app's `FavoritesStore.onChanged`, not here"). On iOS the app wires
`favorites.onChanged` → `record(kind: entry.favorited ? .heart : .unheart,
itemId: entry.songId, itemTitle: live-catalog name)` with all three collection
fields nil (`PocketDJApp.swift:559-568`, record `:564-566`;
`CollectionActivityStore.swift:41-42`). `onChanged` fires **only** for
user-originated toggles — never a cloud pull (`FavoritesStore.swift:195,221-223`),
never the tester seed (`:78-83,199-216`), never `clear()` (`:225-233`) — so the
user-only guarantee holds by construction. This wiring is the stub Android leaves
behind (§6).

---

## 5. HistoryScreen Activity segment goes LIVE (replacing the P1 placeholder)

Today's Android placeholder: `HistoryScreen.kt` renders a two-segment
`Plays | Activity` control (testTags `history-tab-picker`, `history-tab-activity`,
`android/app/src/main/java/com/levi/pocketdj/screens/history/HistoryScreen.kt:150-167`)
and `ActivityContent()` is a hardcoded empty state with testTag
`history-activity-empty` (`HistoryScreen.kt:440-453`), selected via
`when (selectedTab) { … else -> ActivityContent() }` (`:168,243`). **P2 change:**
pass the activity store's state + the merged catalog + `onSongClick` into
`ActivityContent` and drop in real rows — the Plays side is untouched, exactly the
iOS shape (`apple/PocketDJ/Views/HistoryView.swift:99-113`).

### List semantics (iOS `HistoryView.activityContent`, `HistoryView.swift:116-135`)

- **Newest first**: render `events.reversed()` (the log is oldest→newest)
  (`:118,127`).
- A **plain reverse-chronological list** — deliberately OUTSIDE the Plays
  filter/sort/search machinery; a merge into Plays was rejected because activity
  rows have no clean song identity to sort/filter alongside plays
  (`HistoryView.swift:19-22,118-121`). No search field, no paging machinery
  needed at P2 volume (a `LazyColumn` over the reversed list; the 20k cap bounds
  it).
- The Plays toolbar (search/sort/filter) is **hidden on the Activity segment**
  (`HistoryView.swift:261`; Android already scopes it inside `selectedTab == 0`,
  `HistoryScreen.kt:168-179`).
- Recompute keys off the store's `revision` (and catalog identity, for live-title
  resolution) — never `events.size`.

### Row (`HistoryView.swift:137-151`)

```
[kind-icon]  {headline, max 2 lines}
             {relative time, caption}
```

- Icon = the kind's symbol (§2 mapping); **heart tinted with the accent color,
  the other three kinds with the secondary accent** (`:139-141`). Android:
  `MaterialTheme.colorScheme.primary` for heart, `onSurfaceVariant` (the P1 row
  convention) for the rest.
- Relative time from `at` — same abbreviated formatter as the Plays rows
  (`:145`, `HistoryView.swift:342-350`; Android already uses
  `DateUtils.getRelativeTimeSpanString`-style rendering in Plays).
- Row testTag: `activity-row` (iOS a11y id, `:150`).
- **Tap → song detail only when `itemId` resolves in the live catalog**; otherwise
  the row is inert (`HistoryView.swift:130`). Android: `catalog.songsById[itemId]`
  → `onSongClick(itemId)`.

### Headline wording (`HistoryView.swift:153-164`) — copy is exact

| kind | headline |
|---|---|
| add | `Added {item} to {coll}` |
| heart | `Hearted {item}` |
| unheart | `Removed heart from {item}` |
| remove | `Removed {item} from {coll}` |

- `{coll}` = `collectionName ?? "a collection"` (`:157`).
- `{item}` display-title precedence (`displayTitle`, `:166-172`): **live catalog
  song name → live catalog album name → event's `itemTitle` snapshot (if
  non-empty) → raw `itemId`**. Resolved/snapshot titles are wrapped in curly
  quotes (`“…”`); the raw-id fallback is unquoted (`:168-171`). Live-first means
  a rename shows fresh; the snapshot keeps departed items readable.
- Render **all four kinds** even though P2 only emits add/remove (§2, §6).

### Empty state (`HistoryView.swift:174-186`)

Keep the placeholder's exact copy — it was already lifted from iOS: title
"No collection activity yet", caption "Adding a song to a playlist or pocket,
hearting a song, or removing one shows up here." (`:178-180`,
`HistoryScreen.kt:449-450`), testTag `history-activity-empty` stays.

---

## 6. Favorites (♥): DEFERRED — and what the stub looks like

### Why defer (verified intertwinement analysis)

- **Hearts are cleanly separable from the Playlists work.** Heart activity flows
  through `FavoritesStore.onChanged` only (`CollectionsStore.swift:61-62`,
  `PocketDJApp.swift:559-568`) — zero coupling to the collections store's
  add/remove choke points. Deferring hearts costs the Activity feature nothing.
- **The ♥ control is app-wide, not Playlists-scoped.** iOS's `FavoriteHeart` is
  "the ONE favorite control, shared by every song surface" — Browse rows, song
  detail, album track table, collection rows
  (`apple/PocketDJ/Views/CollectionSongRow.swift:308-339`), plus the Browse
  favorite/not-favorite filter woven into the browse engine
  (`apple/PocketDJ/Browse/BrowseState.swift:65-68,205-211,343-345`) and the F10
  lock-screen/CarPlay/widget surfaces (`PocketDJApp.swift:569-581`). Porting ♥
  honestly means retrofitting the shipped P1 Browse surfaces — that is its own
  slice, not a Playlists-phase rider.
- **Most of iOS `FavoritesStore`'s complexity serves Apple Music two-way sync and
  CloudKit — both impossible/absent on Android** (no MusicKit, no CloudKit,
  `docs/ARCHITECTURE-ANDROID.md:47-54`): owner-gated push (`FavoritesStore.swift:17-20`),
  `applyRemote` reconcile (`:174-196`), tester seeding (`:27-31,199-216`),
  `pushedAtMs`/`pendingPushes` (`:50-53,123-130`). A P2 port would be either
  dishonest (dead plumbing) or a redesign — neither belongs inside the Playlists
  phase.

### The stub Android P2 ships

1. `ActivityKind` defines all four tokens; the store records any kind (§2, §3) —
   nothing favorites-shaped is missing from the schema.
2. Rendering handles heart/unheart rows (§5) — already correct the day hearts land.
3. **Do NOT build** `FavoritesStore`, the ♥ button, or the Browse favorite filter.
   No dead UI (the P1 doctrine that dropped the aoss toggle,
   `docs/ARCHITECTURE-ANDROID.md:132-135`).

### Contract for the future favorites slice (so the deferral is honest)

When hearts land (own branch, post-Playlists), the minimal Android store must:

- Persist `filesDir/pocketdj-favorites.json` **shape-compatible** with iOS
  (`FavoritesStore.swift:95,55-61`): `{schemaVersion: 1, entries: [{songId,
  favorited, atMs, appleMusicId?, pushedAtMs?}], seedVersion?}` — keep
  `appleMusicId`/`pushedAtMs`/`seedVersion` as optional fields Android never
  writes, so a future S3 cross-device sync can merge iOS and Android docs.
- Keep **tombstone doctrine**: un-♥ is stored as `favorited: false`, not a deleted
  row (`FavoritesStore.swift:21-25,39-41`) — "never touched" ≠ "deliberately
  unfavorited", and any future sync/seed depends on the distinction.
- Expose an `onChanged(entry)` fired **only by user toggles** (`:78-83`), and wire
  it exactly like iOS: `activity.record(kind = if (entry.favorited) heart else
  unheart, itemId = entry.songId, itemTitle = live-catalog name)`
  (`PocketDJApp.swift:559-566`). That wiring is the entire integration — the
  activity store needs zero changes.
- Maintain a derived `favoriteIds: Set<String>` for O(1) row reads / the Browse
  filter hot path (`FavoritesStore.swift:63-69`).

---

## 7. Android module sketch (P2)

```
com.levi.pocketdj
├── data/activity/
│   ├── CollectionActivityStore.kt   // §2-§3: doc + record()/clear()/replaceAll/revision
│   └── ActivityModels.kt            // @Serializable ActivityEvent + ActivityKind + Document
├── data/collections/                // (the Playlists-phase store, own spec)
│   └── …CollectionsStore.kt         // exposes onActivity: ((ActivityHook) -> Unit)?  (§4)
├── di/AppGraph.kt                   // constructs both; wires onActivity → record  (§4)
└── screens/history/HistoryScreen.kt // §5: ActivityContent(state, catalog, onSongClick)
```

Unit tests to port (they encode the contract):

- record: empty itemId ignored; every field round-trips; NO dedup window (two adds
  1 s apart = two events); cap-trim drops oldest; revision bumps at cap.
- Lenient decode: unknown keys ignored; missing `events`/`installId`/
  `schemaVersion` load degraded, never reset; corrupt JSON quarantines to `.bak`.
- Choke points (against the collections store): each of the five remove paths and
  the two AddTarget adds emits exactly one hook with the right snapshots
  (pre-mutation collection name; `removeNode` itemId fallback chain);
  **low-level adds and reconcile emit nothing**; index-playlist add emits nothing.
- Rendering: headline wording per kind incl. `"a collection"` and raw-id
  fallbacks; newest-first order; tap inert for unresolvable itemId.
