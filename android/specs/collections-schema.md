# Collections document — Android Phase 2 implementation contract

Extracted from the iOS app in this worktree. Every claim cites `apple/…` file:line.
Scope: the **on-disk collections document** (pockets / playlists / setlists /
folders / add-target memory), its id conventions, the store's mutation choke
points, the USER vs SHARED (source-derived) distinction, and the exact Android P2
carry/omit decisions. The realize() engine's *algorithm* is out of scope here (it
gets its own spec); this contract covers everything realize reads and writes
(`Setlist`/`SetlistTrack` shapes, snapshotting rules, repeat semantics).

---

## 1. Vocabulary (locked — mirrors PWA + iOS)

(`apple/PocketDJ/Models/CollectionsSchema.swift:14-23`)

- **Pocket** — a named, REUSABLE, nestable (DAG, cycle-guarded) grouping of
  harmonically-similar items (songs + albums + child pockets + free-text notes).
  `performance` kind reserved (`CollectionsSchema.swift:63`).
- **Playlist** — a TEMPLATE: ordered Sequences ("chapters") of Nodes
  (`song | album | pocket | text | sequence`); `sequences[0]` is the default
  chapter (`CollectionsSchema.swift:17-18,320-325`).
- **Setlist** — a FROZEN instance produced by ▶ Play → realize: albums expanded
  to tracks, over-budget pockets sampled, temporal gaps autofilled, then the
  concrete ordered tracks are frozen with per-track snapshots so the setlist
  reads standalone (`CollectionsSchema.swift:19-23,413-415`). One playlist →
  many setlists.
- **Folder** — a FLAT named group; membership lives on the member
  (`Playlist.folderId` / `Pocket.folderId`), the folder itself carries no member
  list (`CollectionsSchema.swift:298-301`).

---

## 2. Document shape

### 2.1 Top level (`CollectionsDocument`, `CollectionsSchema.swift:519-565`)

```json
{
  "schemaVersion": 7,
  "pockets":   [ …Pocket… ],
  "playlists": [ …Playlist… ],
  "setlists":  [ …Setlist… ],
  "folders":   [ …PlaylistFolder… ],
  "lastAddTarget":     { …AddTarget… },
  "recentAddTargets":  [ …AddTarget… ]
}
```

| field | required | decode default | notes |
|---|---|---|---|
| `schemaVersion` | no | `0` (⇒ migrated) | current = **7** (`CollectionsSchema.swift:61`) |
| `pockets` | no | `[]` | plain lenient array (`:553`) |
| `playlists` | no | `[]` | **LOSSY per element** — see §4 (`:554-557`) |
| `setlists` | no | `[]` | (`:558`) |
| `folders` | no | `[]` | v3 (`:559`) |
| `lastAddTarget` | no | `null` | "Add-to remembers last" (`:560`) |
| `recentAddTargets` | no | `null` (→ `[]` in store) | MRU, most-recent first (`:525-531,561-563`) |

There are **no cloud/device-mode fields in the document**. iOS cloud sync is
whole-file LWW: `CloudSyncService` syncs the same on-disk file the store owns
(`syncFileURL`, `apple/PocketDJ/State/CollectionsStore.swift:40-42`) and pulls
land via `reloadFromDisk()` (`CollectionsStore.swift:1684-1698`). Android P2 is
**device-local only** (no CloudKit — `docs/ARCHITECTURE-ANDROID.md:49-52,177-179`);
because sync metadata never entered the document shape, a future S3 whole-doc LWW
sync needs **no schema change** — keep it that way.

### 2.2 schemaVersion + migrations (`CollectionsSchema.swift:24-61,567-616`)

Version history — **every migration so far is the identity no-op** because every
addition was an optional field whose lenient-decode default IS the migrated value
(`CollectionsMigration.migrate`, `CollectionsSchema.swift:578-616`):

| bump | added | default on old docs |
|---|---|---|
| v1→v2 | `Pocket.notes` | `[]` (`:24-26`) |
| v2→v3 | `Playlist.folderId` + doc `folders` | `nil` / `[]` (`:27-31`) |
| v3→v4 | `Pocket.folderId` | `nil` (`:32-35`) |
| v4→v5 | **no shape change** — lossy per-element playlist decode + studio ids riding existing string arrays (`:36-45`) |
| v5→v6 | source provenance ×5 on Pocket AND Playlist | all `nil` = hand-made (`:46-53`) |
| v6→v7 | `lastPlayedAt` on Pocket AND Playlist | `nil` = never played (`:54-60`) |

Migration mechanics: decode → if `schemaVersion < 7`, run `migrate` (which just
stamps `schemaVersion = 7`) (`CollectionsCodec.decode`,
`CollectionsSchema.swift:567-571,613`). **Android: implement the same** — a
`migrate(doc)` that stamps the version, kept as an explicit seam even while it's
identity, exactly like iOS keeps each step's comment visible.

**Iron law restated for this doc:** additive-only; never remove/repurpose a
field; a new field = optional + default + version bump (`CollectionsSchema.swift:12`).

### 2.3 Encoding

iOS persists pretty-printed with **sorted keys** (`CollectionsCodec.encode`,
`CollectionsSchema.swift:572-575`) and **omits absent optionals** (standard
Codable). Android needs shape-compatibility, not byte-compatibility: use the
shared `PdjJson.lenient` (`android/app/src/main/java/com/levi/pocketdj/data/PdjJson.kt`
— `ignoreUnknownKeys`, `coerceInputValues`, `encodeDefaults`, `explicitNulls=false`).
`explicitNulls=false` matters: iOS omits `nil` keys; never write JSON `null` for
absent optionals. `encodeDefaults=true` writing `"songRepeats": {}` etc. is fine —
iOS decodes those leniently.

---

## 3. Record shapes

### 3.1 Pocket (`CollectionsSchema.swift:97-179`)

Every field decodes leniently per-field (`try?` + default, `:158-178`); a missing
`id` even mints a fresh one (`:160`) — a Pocket can essentially never fail to decode.

| field | type | default | meaning |
|---|---|---|---|
| `id` | string | fresh `pkt_…` | (`:160`) |
| `name` | string | `""` | |
| `kind` | `"harmonic"` \| `"performance"` | `harmonic` | (`:63,162`) |
| `description` | string? | `nil` | |
| `songIds` | [string] | `[]` | ordered, **set-like** (adds dedupe, `CollectionsStore.swift:174-176`); studio ids ride here verbatim (§6) |
| `albumIds` | [string] | `[]` | ordered, deduped |
| `childPocketIds` | [string] | `[]` | the DAG edges, cycle-guarded on add (§7) |
| `notes` | [PocketNote] | `[]` | v2, ordered free-text (`:105`) |
| `folderId` | string? | `nil` | v4; nil = top level |
| `songRepeats` | {songId: int} | `{}` | per-song loop count sidecar (membership is set-like so songId keying is unambiguous, `:107-111`) |
| `sourcePlaylistId` | string? | `nil` | v6 provenance (§8) |
| `sourceName` | string? | `nil` | v6 — disambiguates playlist ids across sources (`:115-116`) |
| `sourceSongIds` | [string]? | `nil` | v6 — three-way-merge base snapshot (`:117-119`) |
| `sourceSyncEnabled` | bool? | `nil` | v6 — **nil ⇒ enabled** (`:120-121,137`) |
| `sourceSyncedAt` | double? (epoch ms) | `nil` | v6 |
| `lastPlayedAt` | double? (epoch ms) | `nil` | v7 — stamped OUTSIDE mutate (§7) |
| `createdAt` / `updatedAt` | double (epoch ms) | `0` | |

Derived (do not persist): `memberCount = songIds + albumIds + childPocketIds`
counts — **notes never count** toward members/count/runtime
(`CollectionsSchema.swift:131-133`); `hasSource = sourcePlaylistId != nil`;
`syncsWithSource = hasSource && (sourceSyncEnabled ?? true)` (`:134-137`).

**PocketNote** (`CollectionsSchema.swift:74-93`): `{id (pnt_…), text, position}`,
all lenient. `position` is the note's slot in the pocket's UNIFIED member
ordering (children, albums, songs, notes laid out as one list) so a note can sit
*between* songs (`:74-78`).

### 3.2 PlaylistNode (`CollectionsSchema.swift:231-296`)

Flat, `kind`-discriminated, recursive (matches the PWA JSON):

```json
{ "nodeId": "nd_…", "kind": "song|album|pocket|text|sequence",
  "songId"?, "albumId"?, "pocketId"?, "text"?,          // leaf refs, one per kind
  "name"?, "targetMs"?, "children"?,                    // sequence (chapter) fields
  "note"?, "repeatCount"? }
```

- `nodeId` and `kind` are **REQUIRED — a missing one throws** (`:284-285`), and an
  **unknown `kind` string throws** (`:277-279`); the enclosing lossy array then
  drops just that node (§4).
- Every optional decodes via `decodeIfPresent` — a present-but-wrong-type value
  still throws (drops the node) (`:273-294`).
- `children` recurses through the lossy array, so a bad grandchild drops only
  itself (`:279-281,292`).
- `targetMs` = realize budget for a chapter (reserved) (`:244`).
- `note` = performer cue (`:247`).
- `repeatCount` = total plays before advance; nil/absent ⇒ once (§5) (`:248-252`).

### 3.3 Playlist (`CollectionsSchema.swift:321-390`)

**Unlike Pocket, Playlist has REQUIRED fields**: `id`, `name`, `sequences`,
`createdAt`, `updatedAt` all decode with plain `try` (`:373-388`) — a playlist
missing one is dropped *by the document's lossy `[Playlist]`* (that playlist
only, never the list, `:368-372`). Optionals: `description`, `targetMs`,
`folderId` (v3), the five v6 provenance fields (same names + semantics as
Pocket's, `:328-334`), `lastPlayedAt` (v7).

`sequences` — every entry is a `.sequence` node; `sequences[0]` is the default
chapter (`:320,325`); decodes lossy-per-element (`:368-378`).

### 3.4 PlaylistFolder (`CollectionsSchema.swift:301-318`)

`{id (fld_…), name, createdAt, updatedAt}` — all lenient with defaults. Flat: no
member list; membership is the member's `folderId`.

### 3.5 Setlist + SetlistTrack (`CollectionsSchema.swift:392-506`)

**Setlist** (`:481-506`, all fields lenient): `{id (set_…), playlistId, name?,
seed, generatedAt, totalMs, tracks: [SetlistTrack]}`. `seed` defaults to
`playlistId` when missing (`:501`); re-running realize with the same seed
reproduces the setlist (`:485-486`).

**SetlistTrack** (`:415-478`, all fields lenient — `songId`/`artist`/`name`
default to `""`):

| field | meaning |
|---|---|
| `songId` | catalog/studio id; `""` for pure text rows |
| `artist`, `name`, `bpm?`, `camelot?`, `lengthMs?` | the SNAPSHOT — frozen at Play so the setlist reads standalone after catalog/pocket changes (`:413-415`) |
| `source` | `"explicit" \| "pocket" \| "autofill"` (`TrackSource`, `:395`); default `explicit` |
| `sequenceName?` | chapter label |
| `note?` | performer cue |
| `isText?` | `true` = free-text cue, no backing item/audio (`:427`) |
| `pocketId?` | set when `source == "pocket"` (`:428`) |
| `mixSuggestions?` | **DEFERRED / reserved seam** — shape exists so lighting it up needs no migration (`MixSuggestion`, `:397-411,429`); carry-through only |
| `repeatCount?` | frozen loop count, nil ⇒ once (`:430-432`) |

Derived duration rules (must match on Android — totals and player boundaries
depend on them):
- `perPlayMs` = `0` for text rows, else `lengthMs` when `> 0`, else
  **`defaultTrackMs = 210_000`**
  (`CollectionsSchema.swift:437-443`, `apple/PocketDJ/Performance/RealizeEngine.swift:52`).
- `shownMs` = `perPlayMs × normalizedRepeat(repeatCount)` — a looped row counts
  all its plays in `totalMs` / runtime labels (`:444-447`).
- Row identity for UI lists: `"\(songId)#\(name)"` — songId may repeat
  (cues/blanks), never key rows by songId alone (`:435-436`).

### 3.6 AddTarget (`CollectionsSchema.swift:510-517`)

`{kind: "pocket"|"playlist", id, sequenceId?}` — `sequenceId` only for
playlists (the chapter last added to).

---

## 4. Lossy per-element decode — the v5 insurance (MUST-PORT)

(`LossyDecodableArray`, `CollectionsSchema.swift:204-229`; disaster rationale
`:36-45,209-213`: pre-v5, ONE unknown-kind node threw the whole `[Playlist]`
decode, the document's lenient `try?` yielded `playlists = []`, and the **next
save() destroyed every playlist**.)

Rules, verbatim:
1. The document's `playlists` array, every playlist's `sequences` array, and every
   node's `children` array decode **per element**: an element that fails drops
   THAT ELEMENT ONLY (`CollectionsSchema.swift:554-557,368-378,279-281`).
2. A **non-array** value where an array is expected still throws to the caller
   (absorbed by the field's own leniency at the document level) (`:223-228`).
3. Unknown `kind` ⇒ that node fails ⇒ dropped by its enclosing array (`:277-279`).
4. `encode` stays symmetric with the synthesized shape — round-trip bytes stable
   for known kinds (`:281`, proven by
   `apple/Tests/Unit/CollectionsLossyDecodeTests.swift:149`).

**Android implementation notes (kotlinx.serialization):**
- Implement via two-phase decode: read the array as `List<JsonElement>`, decode
  each element individually with `runCatching { PdjJson.lenient.decodeFromJsonElement(…) }`,
  drop failures. (A `JsonTransformingSerializer` can't swallow per-element
  failures.)
- **TRAP — `coerceInputValues` + enum defaults:** `PdjJson.lenient` sets
  `coerceInputValues = true`, which coerces an unknown enum value **to the
  property default if one exists**. `PlaylistNode.kind` must have **NO default**
  so an unknown kind FAILS the node (and gets dropped), instead of being
  silently rewritten to some known kind — which would corrupt data and then
  persist the corruption. Same for required `nodeId`. Write a test for exactly
  this (port `CollectionsLossyDecodeTests.swift:22,47,70,94`).
- Pocket/Setlist/Folder/Note leniency (per-field defaults) falls out of Kotlin
  defaults + `ignoreUnknownKeys`; Playlist's five REQUIRED fields must have **no
  defaults** so a broken playlist drops (lossy list), matching iOS §3.3.

---

## 5. Repeat-count convention (`CollectionMembership`, `CollectionsSchema.swift:187-202`)

The ONE place the convention lives — every consumer agrees:
- `maxRepeat = 99` (`:190`).
- `normalizedRepeat(raw?) → Int ≥ 1`: nil ⇒ 1, else clamp 1…99 (`:192-195`).
- `storedRepeat(count) → Int?`: **nil for ≤ 1** (keeps the serialized node/track
  free of the key), else the clamped count (`:197-201`).

Storage sites: `PlaylistNode.repeatCount` (per node) and `Pocket.songRepeats`
(sidecar map, because pocket membership is a flat string array)
(`CollectionsSchema.swift:107-111,248-252`). Removing a song from a pocket also
clears its `songRepeats` entry (`CollectionsStore.swift:205-208`).

---

## 6. Id conventions

(`CollectionsFactory`, `CollectionsSchema.swift:620-628`)

| prefix | entity |
|---|---|
| `pkt_` | pocket |
| `pls_` | playlist |
| `set_` | setlist |
| `nd_` | playlist node |
| `pnt_` | pocket note |
| `fld_` | folder |

All are `prefix + UUID.lowercased()` (`:621-627`). **Catalog ids travel
verbatim** (no Android-side minting — `docs/ARCHITECTURE-ANDROID.md:80-83`), and
**studio ids** (`smp_`/`lp_`/`ptn_`/`tk_`,
`apple/PocketDJ/Studio/StudioModels.swift:792-797`) ride the SAME `songIds`
arrays / `.song` nodes as namespaced strings — deliberately no new node kind, so
older apps degrade at resolution time instead of failing decode
(`CollectionsSchema.swift:41-45`, `CollectionsStore.swift:170-176`). Android P2
has no studio; unresolvable studio ids simply drop at resolution, exactly like
unknown catalog ids (`CollectionsStore.swift:965-967`).

**Reserved Now Playing ids** (`CollectionsSchema.swift:65-72`):
`nowPlayingSetlistId = "set_now_playing"`, `nowPlayingPlaylistId = "pls_now_playing"`.
▶ Play / 🔀 Shuffle upsert a SINGLE reusable setlist under these ids
(last-writer-wins, `CollectionsStore.swift:1149-1157`). It is **never surfaced in
setlist lists/history** (`setlists(forPlaylist:)` filters it,
`CollectionsStore.swift:140-143`) and is **purged on every launch/reload** so a
stale last-session set never shows (`CollectionsStore.swift:101-103,1696`).

---

## 7. Store contract — what mutates where

iOS: `@MainActor @Observable CollectionsStore` (`CollectionsStore.swift:7-9`);
Android: a main-thread-confined singleton in `AppGraph`, Compose-observable state,
same as the P1 stores.

### 7.1 The choke points

- **`mutatePocket(id){…}` / `mutatePlaylist(id){…}`** — EVERY membership/rename/
  reorder edit funnels through these two: apply body → stamp `updatedAt = now`
  → `save()` (`CollectionsStore.swift:1648-1655`). Missing id ⇒ silent no-op.
- **`markPlayed(playlistId:/pocketId:)`** — stamps `lastPlayedAt = now` + save
  **DIRECTLY, bypassing mutate**, so `updatedAt` (the "Last updated" sort signal)
  is never disturbed by playback (`CollectionsStore.swift:1657-1674`;
  design rationale `CollectionsSchema.swift:54-60`). Called from the `playNow`
  funnels only (`CollectionsStore.swift:1195-1213`).
- **`save()`** — re-encodes the WHOLE document from live state and writes
  atomically after every mutation; `recentAddTargets` is written as absent when
  empty (`CollectionsStore.swift:1675-1682`).
- Creation appends + saves (`createPocket`/`createPlaylist`/`createFolder`,
  `CollectionsStore.swift:149-163,248-252,763-767`).

### 7.2 Structural invariants the store enforces (port all)

- **Cycle guard:** `addChildPocket` refuses (returns false) when the child can
  reach the parent via `childPocketIds` (DFS, `CollectionsStore.swift:180-186,
  234-244`); also refuses self-nesting.
- **Dedupe on add:** pocket `songIds`/`albumIds`/`childPocketIds` are set-like —
  add is a no-op if present (`CollectionsStore.swift:174-186`).
- **Delete pocket** ⇒ remove it AND scrub its id from every other pocket's
  `childPocketIds` (`CollectionsStore.swift:165-169`). (Playlist `.pocket` nodes
  keep the dangling ref; it drops at resolution.)
- **Delete playlist** ⇒ **cascade-delete its setlists**
  (`CollectionsStore.swift:254-258`).
- **Delete folder** ⇒ members (playlists AND pockets) fall back to top level
  (`folderId = nil`, `updatedAt` stamped) (`CollectionsStore.swift:772-782`).
- **Remove sequence** refuses when it's the last one (`count > 1` guard,
  `CollectionsStore.swift:291-293`).
- `addNode` appends to the named chapter, else `sequences[0]`
  (`CollectionsStore.swift:261-269`).
- Reorder: `moveNode` by ±1 within a chapter (no-op at the ends), `moveNodes` /
  `moveSequences` / `movePocketSongs|Albums|Children|Notes` by offsets
  (`CollectionsStore.swift:343-378,202-204`).
- **Setlists stay editable post-Play**: remove track / reorder / rename /
  per-track note edit / append text note — each recomputes `totalMs` from
  `shownMs` (`CollectionsStore.swift:1316-1378`).

### 7.3 Add-to memory (`CollectionsStore.swift:14-23,792-844`)

- `lastAddTarget` — set by the target-form adds (`addSong(_:to:)` /
  `addAlbum(_:to:)`), persisted on the document.
- `recentAddTargets` — MRU, most-recent first; **dedupe by (kind,id) IGNORING
  `sequenceId`** (freshest chapter wins), move-to-front, **cap 10**
  (`maxRecentTargets`, `CollectionsStore.swift:23,801-807`). Top entry mirrors
  `lastAddTarget`. UI shows the top 3 that still resolve; the surplus is a buffer
  for deleted collections (`:21-23`).
- The source-playlist add path (§8.3) deliberately does NOT touch either
  (`CollectionsStore.swift:463-466,700` test).

### 7.4 Resolution reads (shape only — engine detail in the realize spec)

Two families, same order, different filtering
(`CollectionsStore.swift:918-982`):
- `songIds(forPlaylist/forPocket/forSetlist)` — albums/pockets expanded, deduped,
  **studio ids stripped** — feeds rip/burn/CSV/storage (money paths).
- `playableIds(…)` — same but studio ids kept — feeds playback only.
Setlist resolvers also drop `isText` rows and empty songIds
(`CollectionsStore.swift:949-954,979-982`).

### 7.5 Persistence file + Android pattern

iOS: `Application Support/pocketdj-collections.json`, atomic write
(`CollectionsStore.swift:118-123,1680`). Unreadable file ⇒ start empty (silent
`try?` decode, `:92-100`).

**Android P2:** `filesDir/pocketdj-collections.json`. Follow the
`PlayHistoryStore.kt` pattern exactly (it's the established Android translation of
this contract): temp-file + rename atomic save synchronously-ordered after every
mutation, **corrupt-quarantine to `.bak`** instead of silently overwriting
unreadable bytes (`android/…/data/history/PlayHistoryStore.kt:23-24,74-75,237-252`)
— an improvement over iOS's silent-empty that the ADDITIVE-OPTIONAL law requires
us to keep. Decode via `PdjJson.lenient` + the custom lossy serializers (§4).

### 7.6 Seams (reserve, don't build)

- `onChange` (post-save hook: iOS Spotlight/Siri reindex,
  `CollectionsStore.swift:51-54`) — keep a nullable callback; Android has no
  consumer yet.
- `onActivity` (add/remove event hook → `CollectionActivityStore`, F11;
  fired ONLY from user-facing add/remove choke points, NEVER from source-sync
  reconcile or decode (`CollectionsStore.swift:56-74`)) — the History spec
  reserved the Activity tab for P2 (`android/specs/history.md` §7); if Activity
  ships in this phase, the hook fires from `addSong(_:to:)`/`addAlbum(_:to:)`/
  `removeSong/removeAlbum/removeChildPocket(fromPocket:)`/`removeNode(fromPlaylist:)`
  (`CollectionsStore.swift:205-232,321-341,834-854`).
- `studioLookup` (`CollectionsStore.swift:76-83`) — nil-safe by contract; Android
  P2 leaves it absent and every consumer degrades to catalog-only.

---

## 8. USER vs SHARED — source-derived index playlists

### 8.1 What SHARED is

Read-only playlists that ship **inside the catalog index**, not in the
collections document: `IndexPlaylist {id, name, songIds}` on `IndexJSON.playlists`
(`apple/PocketDJ/Models/IndexModels.swift:6-29`), tagged with their source name as
`SourcePlaylist` (`IndexModels.swift:34-40`). Android already models both
(`android/…/data/catalog/IndexModels.kt:21,46`, `MergedCatalog.kt:6-20`). They are
"From your sources" mirrors (iTunes/Apple Music playlists carried by the
indexer) — **never stored in, or mutated via, the collections document**.

Source playlists sort by NAME under every `CollectionSortOrder` option (neutral
`updatedAt = 0` / `lastPlayedAt = nil` defaults,
`IndexModels.swift:42-49`). The user sort itself is a SETTINGS field
(`SettingsStore.collectionSort`, default `.name`; options
`recentlyPlayed | name | lastUpdated` with exact comparator + tie-breaks at
`apple/PocketDJ/Settings/SettingsStore.swift:47-89`) — on Android it lives in
`AppSettingsStore`, not the collections doc.

### 8.2 Crossing the line: SHARED → USER (provenance, v6)

Two conversions mint an EDITABLE copy and stamp provenance
(`CollectionsSchema.swift:46-53`):
- **Convert-to-pocket**: `convertToPocket(source:)` — deduped ordered songIds,
  stamps `sourcePlaylistId`/`sourceName`/`sourceSongIds`
  (`CollectionsStore.swift:527-544`).
- **Duplicate-as-editable-playlist**: `createPlaylist(_:songIds:source:)`
  (`CollectionsStore.swift:380-397`) via **`duplicateForSource` — the ONE
  find-or-create primitive**. It matches on BOTH `sourcePlaylistId` AND
  `sourceName` (playlist ids are unique only within a source namespace; a legacy
  nil-`sourceName` duplicate matches by id alone) and every caller must go
  through it, or the user ends up with two competing copies
  (`CollectionsStore.swift:399-433`).

### 8.3 Adding a song "to" a source playlist (`CollectionsStore.swift:436-486`)

`addSong(_:toIndexPlaylist:appleMusicId:)` = find-or-create the duplicate +
append to its default chapter, returning
`{playlist, createdDuplicate, alreadyPresent, writeBackEligible, appleMusicId}`.
Two load-bearing negatives:
- **NEVER advances `sourceSongIds`** — the snapshot is the three-way-merge base;
  advancing it early would make the next refresh classify the user's add as a
  source REMOVAL and delete it (`CollectionsStore.swift:456-464`).
- **Never sets `lastAddTarget`** (`:465-466`).

On Android `writeBackEligible` is **always false** — the Apple Music write-back
half (`PlaylistWriteBack`) is MusicKit and impossible
(`docs/ARCHITECTURE-ANDROID.md:48-50`); the add degrades to exactly "the add
stayed local", which iOS defines as the safe failure mode (`:462-464`).

### 8.4 Source sync (three-way merge) — reference semantics

`syncConvertedCollections(with:)` reconciles every `syncsWithSource` item against
the freshly-refreshed catalog playlists; an item whose source is MISSING from the
refresh is left untouched (a disappeared source must never wipe the user's copy)
(`CollectionsStore.swift:613-637`). Per item (`reconcilePocket`
`:663-683` / `reconcilePlaylist` `:690-734`):
- source ADDS = source − snapshot, appended unless the user already has them;
- source REMOVES = snapshot − source, removed (pocket: `songRepeats` entry too;
  playlist: every `.song` node with that id, recursing sub-sequences);
- the user's own adds/removes/reorders live outside both sets and survive;
- snapshot advances to the fresh source membership; `sourceSyncedAt = now`;
- **no-change refresh persists nothing** (guard before mutate, `:675,719`).
Playlist adds land in the DEFAULT chapter (`:722-728`). Manual
"Sync now" ignores the toggles (`syncPocket/PlaylistFromSourceNow`, `:639-651`).
Per-item opt-out: `setSourceSyncEnabled` no-ops on nil-provenance items
(`:603-611`).

**Android P2 decision:** carry all five provenance fields verbatim (decode +
re-encode, never drop), ship convert-to-pocket + duplicate-as-playlist +
`addSong(toIndexPlaylist:)` (they're cheap and unlock the Shared tab), ship
**manual** "Sync from source now" with the exact merge above, and **defer the
automatic on-catalog-refresh sync pass** (plus its global Settings toggle) to a
follow-up slice — it's the piece with catalog-refresh wiring risk and zero data
risk when deferred (fields inert = iOS v5 behavior).

⚠ **Prerequisite fix:** Android's `MergedCatalog.merge` dedupes playlists by
**id alone across sources** (`putIfAbsent(playlist.id, …)`,
`android/…/data/catalog/MergedCatalog.kt:65,85-87`) — but provenance matching
requires `(id, sourceName)` identity (§8.2). Before any provenance work, key
merged playlists by `(id, sourceName)` (iOS keeps same-id playlists from
different sources side by side and matches with the sourceName qualifier,
`CollectionsStore.swift:589-593,621-626`).

---

## 9. Import / export (reference — DEFERRED on Android P2)

For completeness of the contract (Android P2 ships NONE of it):
- Single-item export = a `CollectionsDocument` envelope carrying just that item
  (`CollectionsStore.swift:1382-1392`).
- Every import **mints fresh ids** (pockets, playlists, folders, all node ids)
  and remaps intra-import refs, so an import can never clobber existing
  collections; setlists re-point at reminted playlists or drop
  (`CollectionsStore.swift:1394-1438,1541-1585,1636-1644`).
- Zip interop (`.playlist/.pocket/.pocketdj.zip`, `.pdjcollection` UTI) and
  portable items materialization: `CollectionsStore.swift:1440-1535,1587-1634`.
The fresh-id-mint doctrine is the reason cross-device id stability comes from
whole-doc sync (LWW), never from import — do not invent per-item merge later.

---

## 10. Android P2 document — carry vs omit

**File:** `filesDir/pocketdj-collections.json`, `schemaVersion: 7` written,
migrate-stamp on decode of `< 7` (§2.2), lenient + lossy decode (§4), atomic save
+ `.bak` quarantine (§7.5). All field NAMES verbatim from §2-§3 — the document
must be byte-level interchangeable with an iOS document for the future S3 sync
merge (ids travel verbatim).

| iOS piece | Android P2 |
|---|---|
| Document + all §3 shapes, all field names | **CARRY — full fidelity** (decode + re-encode everything, including fields P2 doesn't act on) |
| Pockets CRUD, notes, DAG + cycle guard, songRepeats | **SHIP** |
| Playlists CRUD, chapters, all 5 node kinds, reorder, node notes/repeats | **SHIP** |
| Folders (flat, both member kinds) | **SHIP** |
| Setlists: realize-frozen instances, Now Playing reserved set + launch purge, post-Play edits | **SHIP** (engine per realize spec) |
| lastAddTarget + recentAddTargets (MRU cap 10) | **SHIP** |
| lastPlayedAt stamps + CollectionSortOrder (in AppSettingsStore) | **SHIP** |
| Provenance fields + convert/duplicate + manual sync-now | **SHIP** (after MergedCatalog `(id, sourceName)` fix, §8.4) |
| Auto source-sync on catalog refresh + global toggle | **DEFER** (fields carried, inert) |
| `mixSuggestions` | carried-but-inert (reserved seam, §3.5) |
| Studio ids / `studioLookup` | carried verbatim in arrays; no resolver (drop at resolution) — P4 |
| CloudKit sync / `reloadFromDisk` | **OMIT** — device-local (open question: S3 sync) |
| Apple Music write-back (`writeBackEligible`) | **OMIT** — always false on Android |
| Import/export (json + zips + `.pdjcollection`) | **DEFER** (§9) |
| `onChange` Spotlight/Siri reindex | seam only (nullable callback) |
| `onActivity` → CollectionActivityStore | fire from the choke points if the Activity tab ships this phase (`android/specs/history.md` §7), else seam only |

**Tests to port** (they encode the contract — remember `xcodegen`'s Android
equivalent: new test files must move the test COUNT):
`apple/Tests/Unit/CollectionsTests.swift` (round-trip, missing-version migrate,
unknown-fields degrade, cycle guard, delete-cleans-parent-refs, last-add-target
persist, convert/duplicate provenance, sync add/remove/preserve-user-edits/
no-op/disabled-skip, repeat normalization + persistence, recent-targets MRU
dedupe/cap/source-add-exclusion) and `CollectionsLossyDecodeTests.swift`
(unknown kind at chapter slot / child / grandchild drops that element only;
undecodable playlist drops that playlist only; known-kind round-trip stable),
plus the §4 Android-specific unknown-enum-coercion trap test.
