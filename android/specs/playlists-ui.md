# Android Phase 2 — Playlists tab UI implementation contract

Source of truth: the iOS app under `apple/PocketDJ/` in this worktree. Every claim
below cites `file:line` in that tree. Where Android P2 deliberately cuts scope, the
cut is stated explicitly in §12/§13. Companion spec: the collections **document
schema + store** contract is §1 here (there is no separate collections.md yet);
playback plumbing is `specs/playback.md`; the Browse surfaces this tab launches
from are `specs/browse.md`.

Iron law (ported from iOS, same as every other spec): **every on-disk document
decodes leniently** — non-identity fields optional with defaults, unknown fields
ignored, so a later field addition never wipes a saved doc. iOS goes further for
collections and this spec requires the same two extra protections (§1.6):
per-element **lossy list decode** for playlists (`Models/CollectionsSchema.swift:206-230`)
and **atomic writes** (`State/CollectionsStore.swift:1680`). Android: `PdjJson.lenient`
(`data/settings/AppSettingsStore.kt:9,83`) + the `PlayHistoryStore` atomic-write /
corrupt-quarantine pattern.

**Shape-compatibility law (from the task/architecture):** the Android collections
document must keep the SAME field names/semantics as iOS
(`Models/CollectionsSchema.swift`) so a future S3 cross-device sync can merge
them. Ids travel verbatim; Android never re-namespaces an id.

---

## 1. The collections document (shape-compatible with iOS)

### 1.1 File + top-level doc

- iOS persists ONE JSON file `pocketdj-collections.json` in Application Support
  (`State/CollectionsStore.swift:118-122`), written atomically on every mutation
  (`:1676-1680`). Android: one `pocketdj-collections.json` under app `filesDir`,
  atomic temp-file+rename writes, all mutations through a single store class
  (`CollectionsStore` analogue) that saves after each op.
- Top-level shape (`Models/CollectionsSchema.swift:519-560`):

```
CollectionsDocument {
  schemaVersion: Int          // current = 7 (:61)
  pockets:   [Pocket]
  playlists: [Playlist]       // LOSSY per-element decode (§1.6)
  setlists:  [Setlist]
  folders:   [PlaylistFolder]
  lastAddTarget: AddTarget?         // optional/back-compat
  recentAddTargets: [AddTarget]?    // optional/back-compat (F11 MRU, §8.2)
}
```

- Every array/optional coalesces to empty/nil on decode failure — a missing key
  can never wipe the rest of the doc (`:544-559`).
- On load, drop any persisted reserved "Now Playing" setlist (id
  `set_now_playing` / playlistId `pls_now_playing`) — it is per-session scratch
  and must never show after relaunch (`State/CollectionsStore.swift:102-105`,
  reserved ids declared `Models/CollectionsSchema.swift:72-73`).

### 1.2 Ids (mint EXACTLY these prefixes — `Models/CollectionsSchema.swift:620-627`)

| Entity | Prefix | Factory |
|---|---|---|
| Pocket | `pkt_` + lowercase UUID | `:622` |
| Playlist | `pls_` + uuid | `:623` |
| Setlist | `set_` + uuid | `:624` |
| Playlist node | `nd_` + uuid | `:625` |
| Pocket note | `pnt_` + uuid | `:626` |
| Folder | `fld_` + uuid | `:627` |

### 1.3 Pocket (`Models/CollectionsSchema.swift:95-183`)

```
Pocket { id, name, kind: "harmonic"|"performance" (default harmonic, :63),
         description?, songIds: [String], albumIds: [String],
         childPocketIds: [String], notes: [PocketNote],
         folderId?,                       // nil = top level (:104-105 v4)
         songRepeats: {songId: Int},      // per-song loop count sidecar (:106-110)
         sourcePlaylistId?, sourceName?, sourceSongIds?,   // v6 provenance (:111-121)
         sourceSyncEnabled?, sourceSyncedAt?,
         lastPlayedAt?,                   // v7 "Recently played" key (:122-125)
         createdAt, updatedAt }           // epoch MILLISECONDS (Double on iOS)
PocketNote { id, text, position }         // (:79-94)
```

- `memberCount = songIds + albumIds + childPocketIds` — notes NEVER count
  (`:132-133`). `isEmpty` includes notes (`:132`).
- `hasSource = sourcePlaylistId != nil`; `syncsWithSource = hasSource &&
  (sourceSyncEnabled ?? true)` (`:135-139`).

### 1.4 Playlist / nodes / folders (`Models/CollectionsSchema.swift:233-390`)

```
PlaylistNode { nodeId, kind: "song"|"album"|"pocket"|"text"|"sequence",
               songId?, albumId?, pocketId?, text?,       // leaf refs, one per kind
               name?, targetMs?, children?: [PlaylistNode], // sequence (chapter)
               note?, repeatCount? }                       // (:233-260)
PlaylistFolder { id, name, createdAt, updatedAt }          // flat, no member list (:298-319)
Playlist { id, name, description?, sequences: [PlaylistNode], // every entry kind=sequence
           targetMs?, folderId?,                            // (:321-333)
           sourcePlaylistId?, sourceName?, sourceSongIds?,  // v6, same as Pocket
           sourceSyncEnabled?, sourceSyncedAt?, lastPlayedAt?,  // v7
           createdAt, updatedAt }
```

- A new playlist gets ONE chapter named **"Default"** (`sequences[0]`,
  `Models/CollectionsSchema.swift:635-638`); `sequences[0]` is the default add
  target everywhere.
- Folder membership is by `folderId` on the playlist/pocket — the folder itself
  carries no member list (`:298-301`). Folders hold BOTH playlists and pockets
  (`Views/PlaylistsView.swift:60-63`).
- Repeat counts: nil/≤1 ⇒ play once; clamp 1…99 via the normalize/store pair
  (`Models/CollectionsSchema.swift:181-201`, max `:188`). Persist nil for 1.

### 1.5 Setlist — the frozen ▶ Play instance (`Models/CollectionsSchema.swift:392-509`)

```
TrackSource = "explicit" | "pocket" | "autofill"          // (:395)
SetlistTrack { songId, artist, name, bpm?, camelot?, lengthMs?,   // SNAPSHOT (:413-421)
               source (default explicit), sequenceName?, note?,
               isText?,                // true = free-text cue row, no audio (:426)
               pocketId?, mixSuggestions? (DEFERRED seam, :398-411), repeatCount? }
Setlist { id, playlistId, name?, seed, generatedAt, totalMs, tracks } // (:481-509)
```

- Tracks are snapshotted (artist/name/bpm/camelot/length inline) so a setlist
  reads standalone even if the catalog changes (`:413-415`).
- `perPlayMs` = lengthMs if > 0 else the engine default (210 s); `shownMs` =
  perPlayMs × normalizedRepeat — totals count all repeats (`:437-447`).
- Reserved Now Playing set: id `set_now_playing`, playlistId `pls_now_playing`,
  seed `"now-playing"`, upserted last-writer-wins, never listed (`:66-73`,
  `State/CollectionsStore.swift:1149-1156`; `setlists(forPlaylist:)` filters it).

### 1.6 The two decode insurances (MUST-PORT)

1. **Lossy playlist decode**: `playlists` decodes per-element — one corrupt or
   unknown-kind element drops that element only, never zeroes the list
   (`Models/CollectionsSchema.swift:206-230,547-551`). Same for `PlaylistNode.children`
   recursion (`:288-296`). History lesson baked into the code comment: pre-v5 a
   single unknown node kind wiped ALL playlists and the next save persisted the
   loss (`:207-213`). Android: element-wise `runCatching` decode of `JsonArray`
   entries via `PdjJson`.
2. **Unknown `kind` strings still drop the node/playlist** (that is the point of
   lossiness) — do NOT map unknown kinds to a default (`:279-283`).

### 1.7 AddTarget (`Models/CollectionsSchema.swift:510-518`)

```
AddTarget { kind: "pocket"|"playlist", id, sequenceId? }  // sequenceId: playlists only
```
MRU list `recentAddTargets`: deduped by (kind,id) ignoring sequenceId,
move-to-front, capped at **10** (`State/CollectionsStore.swift:16-23,798-806`).

---

## 2. Playlists tab — top level

Android nav slot already exists: `Playlists("playlists", …, phase 2)`
(`navigation/PocketDjDestination.kt:25`).

### 2.1 User | Shared mode tabs (F3)

- Segmented control docked at the TOP of the screen, above the list — two
  segments labeled **"Yours"** and **"Shared"** (`Views/PlaylistsView.swift:8-16,234-241`).
- Selection is **UI-only state, persisted OUTSIDE the collections doc** (iOS:
  `@AppStorage("pdj.playlists.mode")`, `:6-7,72`). Android: a field in the
  browse-session-style UI snapshot or `AppSettingsStore` — never in
  `pocketdj-collections.json`.
- Yours = editable playlists + pockets + folders; Shared = read-only
  source-derived index playlists ("From your sources") (`:60-64,251-268`).
- Search scopes to the ACTIVE tab: User counts playlist+pocket matches only,
  Shared counts source matches only (`:18-26,124-128`).

### 2.2 Search

- One search field over the whole tab; prompt per mode: "Search playlists and
  pockets" / "Search source playlists" (`:244-246`).
- Trimmed query; case- and diacritic-insensitive SUBSTRING match against NAMES
  only (`:103-110`).
- While searching, the list is REPLACED by flattened results: folder nesting and
  per-source grouping collapse away — a match surfaces regardless of container
  (`:112-123,422-450`). Results ordered by the active collection sort (`:115-123`).
- No matches in the active tab ⇒ standard "no results for query" placeholder
  (`:423-427`).

### 2.3 Collection sort (F1)

- Toolbar sort menu (up/down-arrows icon), one tap picks one of THREE orders,
  checkmark on the active one (`Views/PlaylistsView.swift:554-571`):
  `recentlyPlayed` ("Recently played") · `name` ("A–Z") · `lastUpdated`
  ("Last updated") (`Settings/SettingsStore.swift:50-66`).
- Persisted write-through in settings (iOS `SettingsStore.collectionSort`,
  `Settings/SettingsStore.swift:172`; missing key ⇒ **`.name` default on fresh
  install AND upgrade** `:270,456`). Android: a nullable string field in
  `AppSettingsStore` coalescing to `"name"`.
- Comparator — port EXACTLY (`Settings/SettingsStore.swift:68-89`):
  - `name`: locale-aware case-insensitive ascending.
  - `lastUpdated`: `updatedAt` DESC, tie-break name.
  - `recentlyPlayed`: `lastPlayedAt ?? 0` DESC (never-played sorts LAST), then
    `updatedAt` DESC, then name.
- Applies to: User-tab top-level playlists, top-level pockets, each folder's
  members, each Shared source group's members, and search results
  (`Views/PlaylistsView.swift:115-123,309,326,339-340,375`).
- Source playlists sort with NEUTRAL keys (`updatedAt=0`, `lastPlayedAt=nil`) so
  every order degrades to A–Z for them (`Models/IndexModels.swift:43-50`).
- `lastPlayedAt` is stamped ONLY by the play funnel (`markPlayed`), which writes
  directly WITHOUT touching `updatedAt` — playback must never look like an edit
  (`State/CollectionsStore.swift:1660-1674`).

### 2.4 User tab sections (in order)

1. **"Your playlists"** — top-level (folderId == nil) playlists, active sort
   (`Views/PlaylistsView.swift:308-320`). In-section captions: no playlists at
   all ⇒ "No playlists yet — tap + to create one."; playlists exist but all
   foldered ⇒ "All your playlists are in folders below." (`:311-317`).
2. **"Pockets"** — top-level pockets; the SECTION IS HIDDEN entirely when the
   user has zero pockets (no empty header) (`:324-334`); all-foldered caption
   mirrors playlists (`:328-330`).
3. **One section per folder**, folders ordered by name case-insensitive
   (`State/CollectionsStore.swift:740-743`), each a collapsible group (§2.6).

Whole-tab empty state (no playlists AND no pockets): icon + "No collections
yet" + the one-line pocket/playlist definitions + two buttons "New Playlist"
(prominent) / "New Pocket" (`Views/PlaylistsView.swift:283-295`).

### 2.5 Toolbar (5 actions, left→right trailing — `Views/PlaylistsView.swift:573-595`)

| Icon | Action |
|---|---|
| sort arrows | sort menu (§2.3) |
| import | file importer — **DEFERRED on Android P2** (§13) |
| folder+ | New Folder name dialog |
| stack | New Pocket name dialog |
| + | New Playlist name dialog |

All create dialogs: single text field, Create/Cancel, trimmed, empty ⇒ no-op
(`:184-187,203-207,649-653`).

### 2.6 Folders (collapse memory)

- Folder row: folder icon + name + member COUNT (playlists+pockets in it) on the
  trailing edge (`:341-355`). Expand/collapse chevron.
- **Collapsed folder ids persist across launches** — iOS stores the COLLAPSED
  set under UserDefaults key `pdj.playlistFolders.collapsed` (missing ⇒
  expanded, i.e. folders default OPEN) (`:95-96,607-622`).
- Folder long-press/context menu: Rename folder / Delete folder (`:357-362`).
- Delete confirmation: "The folder's playlists and pockets move back to the top
  level. This can't be undone." — deletion un-folders members, never deletes
  them (`:662-667`, `State/CollectionsStore.swift:772-780`).
- Empty-folder caption: "Empty folder — move a playlist or pocket in with its ⋯
  menu." (`:344-347`).

### 2.7 Shared tab — per-source collapse (F2)

- One section "From your sources", footer: "Read-only playlists from your
  enabled sources. Play one, or duplicate it into an editable playlist."
  (`Views/PlaylistsView.swift:371-390`).
- Groups = source playlists grouped by `sourceName`, ordered by the app's
  `availableSources` first-seen order; any group not in that list appends
  alphabetically (`:32-47,392-395`). Group header: box icon + source name +
  playlist count (`:376-382`).
- **Collapse-by-default with remembered EXPANSIONS**: the persisted set is the
  EXPANDED source names (key `pdj.sources.expanded`); a never-touched source is
  absent ⇒ collapsed. This is deliberately the INVERSE of the folder key so the
  default needs no seeding (`:49-57,624-634`).
- Empty state (no source playlists at all): "No source playlists" + "Playlists
  from your enabled sources (Apple Music, vinyl, imports…) appear here. Enable a
  source in Settings, or add playlists to one." (`:297-304`).
- Android data source: `IndexJSON.playlists` already modelled
  (`data/catalog/IndexModels.kt:21,46`); tag each with its source name at merge
  time (iOS `SourcePlaylist` = IndexPlaylist + sourceName,
  `Models/IndexModels.swift:31-41`).

### 2.8 Rows

**Playlist row** (`Views/PlaylistsView.swift:453-470`): list icon (accent) ·
name · subtitle `"<n> chapter(s) · <stats.summary>"` where `stats.summary` =
`"<count> song(s) · <m:ss runtime>"` (§10). Tap → playlist detail. Swipe
trailing: Delete (destructive, immediate — the ⋯/context-menu delete is the
confirmed path `:490-491`, the swipe is not confirmed `:467-469`). Context menu
(`:472-492`): Rename · Move to folder ▸ (Top level when foldered / each folder,
checkmark on current / New folder…) · Delete.

**Pocket row** (`:495-547`): stack icon · name · subtitle
`"<memberCount> item(s) · <stats.summary>"` (memberCount per §1.3). Context
menu adds **"Add to playlist…"** ▸ every playlist — inserts a pocket-REF node
into the playlist's default chapter (`:534-544`,
`State/CollectionsStore.swift` `addPocketRef`). Swipe trailing: Delete.

**Source row** (`:398-417`): list icon (accent2) · name · sourceName capsule
badge + `"<n> song(s)"`. Tap → read-only source detail (§4). No swipe/context
actions (read-only).

---

## 3. Create / rename / delete flows (all name dialogs share one pattern)

- Create/rename: single-TextField dialog, trim whitespace, empty ⇒ no-op
  (`Views/PlaylistsView.swift:184-221`).
- Delete playlist (confirmed): "Delete this playlist? / This also deletes its
  set lists. This can't be undone." — deletion CASCADES to its setlists
  (`:197-201`, `State/CollectionsStore.swift:253-258`).
- Delete pocket (confirmed): "Removes the pocket and unnests it from any parent.
  Its items aren't deleted. This can't be undone." (`:216-221`) — the store also
  strips the pocket id from parents' `childPocketIds` and playlists' pocket
  nodes.
- Delete folder: §2.6.

---

## 4. Read-only source playlist detail (`Views/PlaylistsView.swift:673-752`)

Actions section, then "Songs":

| Row | Behavior |
|---|---|
| ▶ Play | realize songIds → NEW persisted transient setlist, open its detail (no autostart) (`:724-726`, store `realize(songIds:name:)` `:1095-1111`) |
| Shuffle | in-place shuffle-play WITHOUT duplicating: `playNow(songIds:, shuffle: true, source: .playlist, originId: source.id)` then open Now Playing autostarting (`:727-734`) |
| Duplicate as editable playlist / **Open editable copy** | FIND-OR-CREATE: if a duplicate of this source already exists, the button relabels ("Open editable copy", different icon) and OPENS it instead of minting a rival (`:682,696-700,735-746`; single primitive `duplicateForSource` `State/CollectionsStore.swift:401-429`, matching on sourcePlaylistId+sourceName with a legacy nil-sourceName concession `:414-427`) |
| Convert to pocket | new pocket of its songs, provenance-stamped, navigate into it (`:701-703,749-751`; store `:534`) |
| Rip / Burn buttons | **DEFERRED on Android P2** (`:704`) |

Footer: `"<resolved> of <total> song(s) resolved from <sourceName>."` — counts
how many ids actually resolve in the merged catalog (`:705-707`).
Songs section: shared song rows, tap → song detail (`:709-717`).

Duplicates are provenance-stamped (`sourcePlaylistId/sourceName/sourceSongIds`)
so the doc stays mergeable with iOS sync semantics
(`State/CollectionsStore.swift:386-397`) — Android P2 stamps provenance even
though its own sync engine is deferred (§13).

---

## 5. Playlist detail (`Views/PlaylistsView.swift:754-1135`)

### 5.1 Layout

1. Stats row: icon + `stats.summary` (`:791-799`).
2. One SECTION PER CHAPTER (`sequences`), reorderable (`:801-804`). Chapter
   header: chapter name + right-aligned per-chapter `stats.summary`
   (`:1049-1057`). Empty chapter caption: "Empty chapter — add items from a
   song/album ▸ Add to…" (`:1015-1017`).
3. **"Set lists"** section (hidden when none): the frozen takes realized from
   this playlist, newest info per row: waveform icon · name ("Set list"
   fallback) · `"<n> track(s) · <m:ss>"`; context menu Rename/Delete;
   swipe-delete (`:806-811,1077-1095`). The reserved Now Playing set never
   appears here (§1.5).

### 5.2 Node rows (`:1097-1134`)

| kind | Render |
|---|---|
| song | shared collection song row; tap → song detail. Unresolvable id ⇒ "(missing song)" placeholder row (`:1099-1116,1132-1134`). Studio ids (`smp_`/`lp_`/`ptn_`/`tk_`): iOS renders a studio row (`:1108-1115`) — Android P2 has no Studio, render "(missing song)" (honest degrade, same as iOS with the seam unwired) |
| album | album name + stack icon, tap → album detail (`:1117-1119`) |
| pocket | pocket name + stack-play icon, tap → pocket detail (`:1121-1123`) |
| text | italic quoted note row, not tappable (`:1125-1126`) |
| sequence | indented sub-chapter label (display-only) (`:1127-1128`) |

Per-row actions (`:1019-1047`): swipe trailing = Remove; swipe leading = Move
up / Move down (disabled at the ends); long-press menu = Move up / Move down /
Remove. Drag-reorder within a chapter (`onMove` → `moveNodes` `:1042-1044`) —
Android: chapter-scoped drag reorder plus the explicit up/down actions.

### 5.3 Chapter action rows (inside each chapter — `:1062-1075`)

- "Add note" → text dialog, appends a `.text` node to that chapter
  (`:1174-1184`).
- "Rename chapter" → dialog (`:1163-1173`).
- "Delete chapter" — shown ONLY when the playlist has >1 chapter (the last
  chapter can't be deleted) (`:1071-1074`).

### 5.4 Toolbar (`:819-864`)

- Play (▶) and Shuffle: disabled when total item count is 0 (`:824-834`,
  `itemCount` `:787`). Both call `playNow(playlistId:, shuffle:)` — literal
  resolved order (or shuffled), UPSERT the reserved Now Playing setlist, stamp
  `lastPlayedAt`, open the Now Playing setlist detail autostarting
  (`:964-978`; store `:1195-1204`, `playNow(songIds:)` semantics `:1113-1160`).
  Guard: don't push a second Now Playing screen if it's already on top — re-tap
  just re-snapshots and restarts (`:779-781,968-978`).
- Device/cloud `PlaybackModeToggle` (`:820-822`): **DEFERRED** (Android P2 is
  cloud-stream/rip-only; no burns yet).
- ⋯ overflow menu (kept to 4 toolbar items so compact width never overflows —
  `:835-838`): Make set list (realize → frozen take, push WITHOUT autoplay,
  disabled when empty `:840-842,980-984`) · Add chapter (`:843-844,1153-1157`)
  · Edit order toggle (`:845-847`) · Rename… · Export… (**DEFERRED**) · Convert
  to pocket (`:853-855,1006-1010`) · source-sync items when `hasSource`
  (**DEFERRED**, §13) · Rip/Burn (**DEFERRED**) · Delete playlist (confirmed,
  cascade message, pops back on delete `:873-882`).

---

## 6. Pocket detail (`Views/PocketsView.swift:9-304`)

### 6.1 Sections (in order — `:42-125`)

1. Stats row + footer: "Total resolved songs (own + album tracks + nested
   pockets, deduped). Runtime sums known track lengths." (`:45-55`).
2. **"Nested pockets"** (hidden when none): child pocket rows, tap-through,
   swipe Remove (removes the NESTING, not the child), drag-reorder (`:56-68`).
3. **"Albums (n)"**: album rows, swipe Remove, drag-reorder (`:69-77`).
4. **"Songs (n)"**: shared song rows, swipe Remove, drag-reorder (`:78-102`).
   Studio ids: same "(missing)" degrade as §5.2 on Android.
5. **"Notes (n)"** (hidden when none): italic note rows; TAP opens
   edit-note dialog (Save / Remove / Cancel; save-empty removes) (`:103-118,182-197`);
   swipe Remove; drag-reorder.
6. Empty pocket: "Empty. Add songs or albums from their detail view ▸ Add to…,
   or add a note below." (`:119-122`).

### 6.2 Toolbar (`:134-172`)

▶ Play / Shuffle (disabled when the pocket resolves to zero songs, `:33,139-149`)
→ `playNow(pocketId:, shuffle:)`: DAG-resolved song order (own songs → album
tracks → nested pockets, cycle-guarded, deduped — §10), stamps `lastPlayedAt`,
opens Now Playing autostarting (`:293-303`, store `:1206-1214`). ⋯ menu: Add
note (`:152-153,173-181`) · Edit order · Rename… · Export… (**DEFERRED**) ·
source-sync items when converted-from-source (**DEFERRED**) · Rip/Burn
(**DEFERRED**) · Delete pocket (confirmed, unnest message `:208-214`).

---

## 7. Setlist detail (`Views/SetlistDetailView.swift`)

The FROZEN, read-only performance ("Spin these tracks, in this order" — `:12-16`).

### 7.1 Layout

- Header stats: total duration · track count · generated date (`:92-107`).
- One flat, reorderable track list; section header = chapter legend: ordered
  distinct chapter names joined " · " + `"<n> · <m:ss>"` total (`:457-481`).
- Track row (`:365-405`): row number · shared song-row content fed from the
  FROZEN snapshot (catalog lookup only for art/tap-through; a vanished song
  still renders from the snapshot) · provenance badges column (`:409-431`):
  "pocket" badge when source=pocket, "↔ bridge" when autofill, none for
  explicit (`:448-455`); chapter badge when a real named chapter (not
  "Default") (`:414-417`); tap row → song detail when the song still resolves
  (`:393-397`).
- Cue rows (`isText == true`): numbered, "cue" badge, italic text (`:367-378`).
- Per-track note: "＋ note" / "📝 <note>" button under the row → note dialog
  (Save/Clear/Cancel) (`:433-444,193-207`).
- Reorder (drag) + swipe-delete + context-menu delete, ALL DISABLED while this
  set is playing (queue-index desync guard) (`:112-130`).
- Missing setlist (deleted behind the screen): "Set list gone" placeholder
  (`:136-139`).

### 7.2 Transport + toolbar

- `isPlaying` is SOURCE-AWARE: this screen shows the running transport only if
  the app-scoped sequencer is running THIS setlist id (`:59-62`).
- iOS-idle layout: ▶ (starts the set; disabled when no playable tracks) · Edit ·
  ⋯ overflow (`:227-233`). While playing: centered ⏮ ⏯ ⏭ cluster; prev/next
  step the SET, middle toggles pause/resume; secondary actions collapse into ⋯
  (`:217-226,272-290`). No dedicated Stop — pause or leave (`:292-306`).
- ⋯ overflow (`:312-338`): Add note (appends a cue to the END — "drag it into
  place with Edit" `:177-187`) · Rip/Burn (**DEFERRED**) · Rename · Export CSV
  (**DEFERRED**) · disabled "Edit order" entry while playing · Delete set list.
- Playable items = tracks with `isText != true` and non-empty songId, played
  with `perPlayMs` boundaries and `repeatCount` loops (`:74-86`).
- Playback keeps running when the user navigates away (app-scoped player,
  `:21-24,144-146`). Android: drive the Media3 queue via `PlaybackController`
  (`playback/PlaybackController.kt:57`) with `PlayContext(SOURCE_SETLIST /
  SOURCE_PLAYLIST / SOURCE_POCKET, contextId, contextName)`
  (`playback/PlayEvents.kt:17-37` — tokens shipped in P1 exactly for this).
- **Android queue policy** (sources reality — no MusicKit): queue manifest-hit
  tracks only, mirroring `playAlbumQueue` ("Manifest hits only — metadata-only
  tracks are skipped in queues", `playback/PlaybackController.kt:214-218`,
  `specs/playback.md:333-337`). Surface a skipped-count line in the header when
  tracks were dropped. Starting a set stamps `markPlayed` on its origin
  playlist/pocket (`Views/SetlistDetailView.swift:65-71`).
- iOS's "No burned files" device-mode alert (`:163-169`) does not apply
  (device/burn mode deferred); its Android analogue is "none of these tracks
  are playable yet" when the playable queue is empty.

---

## 8. Add-to-Collection sheet (`Views/AddToCollectionView.swift`)

### 8.1 Launch points (verified — there is NO Browse-row long-press add on iOS)

- Song detail toolbar `＋` (plus.circle) → sheet with `.song(id)`
  (`Views/SongDetailView.swift:60-62,67`).
- Album detail toolbar `＋` → `.album(id)` (`Views/AlbumDetailView.swift:66-68,74`).
- Studio rows (`.studio`) — **DEFERRED** (no Studio on Android until P4)
  (`AddToCollectionView.swift:11,343-356`).

Android: an Add icon in `SongDetailSheet` (`screens/browse/SongDetailSheet.kt:50`)
and `AlbumDetailScreen` (`screens/browse/AlbumDetailScreen.kt:57`) opening a
modal bottom sheet.

### 8.2 Sheet content (top → bottom)

1. **"Recent" quick-add (F11)** (`:35-39,84-101`): the MRU add-targets,
   filtered to targets that STILL RESOLVE (deleted collections drop out,
   `lastTargetLabel != nil`), capped at the **top 3** (store keeps 10 so
   drop-outs backfill, §1.7). Row: kind icon (stack = pocket, list = playlist)
   · label · re-add glyph. One tap adds + dismisses. Label for a playlist
   target includes its remembered CHAPTER when not the default
   (`State/CollectionsStore.swift:866`).
2. **"Pockets"** (`:103-117`): every pocket, checkmark when the item is already
   a member (`:300-306` — songs check `songIds`, albums `albumIds`); tap adds
   (idempotent — store adds dedupe) + dismisses. Last row: inline **"New
   pocket"** text field + Add button (disabled while blank) that creates AND
   adds in one tap (`:113-116,327-338`).
3. **"Playlists"** (`:119-146`): each playlist row adds to its DEFAULT chapter
   (`sequences[0]`) (`:122-126`); when a playlist has >1 chapter, indented
   sub-rows per chapter add to that specific chapter (`:127-136`). Footer:
   "Tapping a playlist adds to its default chapter." (`:142-145`). Inline
   **"New playlist"** create-and-add row (`:138-141`).
4. **"From your sources"** (`:167-234`): SONG adds only, hidden for albums or
   when no source playlists exist (`:43-48,176-178`). Rows name-ordered
   (`:47-49`). Row subtitle states the consequence BEFORE the tap:
   `"<sourceName> · adds to your local copy"` when a duplicate exists, else
   `"· makes a local copy"` (`:186-190,208-211`). Checkmark when the song is in
   the source snapshot OR its local duplicate (`:229-234`). Tap → find-or-create
   the duplicate via `duplicateForSource` + append to its default chapter, then
   a RESULT ALERT explains exactly what happened (already-present / created a
   copy / added to your copy) (`:237-275`).
   **Android wording (no MusicKit)**: use iOS's own no-write-back branch —
   footer base + "Apple Music playlists can't be edited from this device, so
   the add stays on this device." (`:215-226`, the `canWriteBack == false`
   path); never emit the write-back lines (`:257-267`) and (until the sync
   engine ships, §13) drop "The copy keeps following the original" from the
   created-copy message (`:246`).
5. Every successful add records the target into the MRU (`:289-298`,
   `State/CollectionsStore.swift:798-806`) — EXCEPT source-playlist adds, which
   deliberately do NOT set the remembered target (`:462-467` comment in store).
6. "Done" toolbar button dismisses (`:154`).

---

## 9. Persisted UI-state keys (all OUTSIDE the collections doc)

| iOS key | Meaning | Default | Cite |
|---|---|---|---|
| `pdj.playlists.mode` | Yours/Shared tab | user | `Views/PlaylistsView.swift:72` |
| `pdj.playlistFolders.collapsed` | COLLAPSED folder ids | missing ⇒ expanded | `:607-622` |
| `pdj.sources.expanded` | EXPANDED source names | missing ⇒ collapsed | `:49-57,624-634` |
| `SettingsStore.collectionSort` | sort order raw string | `name` | `Settings/SettingsStore.swift:172,270` |

Android: same four values in `AppSettingsStore` (additive-optional fields —
adding them must not disturb existing settings docs, per the store's own
contract `data/settings/AppSettingsStore.kt:79-83`). Keep the
inverted-set semantics EXACTLY (collapsed-folders vs expanded-sources).

---

## 10. Counts / runtime resolution (`Models/CollectionCatalog.swift`)

`Stats { count, runtimeMs }` (`:37`); display `summary` =
`"<count> song(s) · <Fmt.duration(runtimeMs)>"` (`:138-143`); runtime sums
`length ?? 0` (unknown lengths count 0 — no 210 s padding in STATS, unlike
setlist `perPlayMs`).

- **Pocket resolution** (`resolvePocketSongs` `:100-127`): own `songIds` in
  order → each album's trackList → nested child pockets recursively;
  CYCLE-GUARDED (`seen` set) and DEDUPED by songId across the whole walk.
- **Playlist resolution** (`songs(inPlaylist:)` `:60-98`): walk every chapter's
  children; song → itself, album → its trackList, pocket → pocket resolution,
  sub-sequence → recurse, text → nothing. The `seen` pocket set spans the WHOLE
  playlist so a pocket referenced in two chapters counts ONCE (`:63-66,93-98`).
- Per-chapter stats use the same walk scoped to one chapter (`:87-91`).
- Unresolvable ids simply drop out of count/runtime (compactMap semantics).
- These SAME resolved orders are what ▶ Play feeds `playNow` (store
  `playableIds(forPlaylist/forPocket)` → `:1195-1214`), so the subtitle numbers
  and what actually plays can never disagree.

---

## 11. Play semantics summary (Android P2)

1. Playlist/Pocket ▶ Play/Shuffle and source-playlist Shuffle → build the
   reserved Now Playing setlist doc (literal resolved order; shuffle re-orders
   fresh per tap; unresolvable ids dropped; totals from `shownMs`) and upsert
   under `set_now_playing` (`State/CollectionsStore.swift:1113-1160`), then
   open Setlist detail with autoplay.
2. Source-playlist ▶ Play and playlist "Make set list" → persist a NEW frozen
   setlist and open it WITHOUT autoplay (`Views/PlaylistsView.swift:724-726,980-984`).
   P2 realizes LITERALLY (all tracks `source: "explicit"`); the iOS
   RealizeEngine's harmonic autofill/bridging is deferred — the doc shape is
   identical either way.
3. Setlist play drives one Media3 queue via `PlaybackController` with
   `PlayContext` playlist/pocket/setlist tokens (already reserved,
   `playback/PlayEvents.kt:24-30`) so History attributes rows correctly
   (`specs/history.md` context labels).
4. `markPlayed` stamps `lastPlayedAt` (never `updatedAt`) on the origin
   playlist/pocket at play start (`State/CollectionsStore.swift:1660-1674`,
   `Views/SetlistDetailView.swift:65-71`).

---

## 12. Android P2 cut — what ships

- Collections document store: full §1 shape (schemaVersion 7, verbatim field
  names), lenient + lossy decode, atomic writes, id factories, launch-time
  reserved-setlist cleanup.
- Playlists tab: Yours|Shared tabs (F3), search (per-tab scope, flattening),
  sort menu (F1, persisted, exact comparator), Your playlists / Pockets /
  folder sections, folder collapse memory, Shared per-source
  collapse-by-default with remembered expansions (F2), all empty states, all
  create/rename/delete/move-to-folder flows, pocket "Add to playlist…"
  (pocket-ref nodes).
- Source playlist detail: Play (frozen setlist) / Shuffle (in-place) /
  Duplicate-find-or-create / Convert-to-pocket, resolved-count footer,
  provenance stamping.
- Playlist detail: chapters (add/rename/delete-guarded), node rows with
  up/down + drag reorder + remove, notes, Play/Shuffle → Now Playing, Make set
  list (literal realize), Convert to pocket, Set lists section, delete cascade.
- Pocket detail: nested pockets/albums/songs/notes sections with reorder +
  remove, note add/edit, Play/Shuffle (DAG-resolved), delete/unnest.
- Setlist detail: frozen snapshot rows + provenance/chapter badges + cue rows,
  per-track notes, add-note-at-end, rename/delete, reorder+delete locked while
  playing, source-aware transport over the Media3 queue (manifest-hits-only),
  markPlayed stamping.
- Add-to sheet from song/album detail: Recent top-3 (F11), kind icons,
  checkmarks, inline create-new pocket/playlist, per-chapter targets,
  source-playlist local-copy adds with Android-honest wording, MRU recording.

## 13. Explicit defers (each needs its own later slice)

| Deferred | Reason | iOS cite |
|---|---|---|
| Export/import (.pdjcollection zip, CSV) + the toolbar import button | custom UTI + file-type plumbing; iOS lesson: exporter needs explicit extension | `Views/PlaylistsView.swift:222-227,895-904,953-962`, `Views/PocketsView.swift:215-224` |
| Rip / Burn / Stemify buttons + burn names + device/cloud PlaybackModeToggle | burns/offline store don't exist on Android yet | `Views/PlaylistsView.swift:704,858`, `Views/SetlistDetailView.swift:163-169` |
| Art/metadata editing (EditSong/EditAlbum/EditAudioAnalysis) | Browse-side feature, untouched by P2 | `Views/SongDetailView.swift:66` |
| Source-sync engine (auto reconcile, "Sync with source" toggle, "Sync from source now") | three-way-merge engine; P2 stamps provenance so docs stay mergeable | `Views/PlaylistsView.swift:924-951`, `Views/PocketsView.swift:236-261` |
| Apple Music write-back of source adds | impossible — no MusicKit on Android (locked decision) | `AddToCollectionView.swift:236-275`, `docs/ARCHITECTURE-ANDROID.md:47-54` |
| Studio items (`.studio` add path, studio rows, repeat-count stepper UI) | Producer is Phase 4; studio ids degrade to "(missing song)" like iOS's unwired seam | `AddToCollectionView.swift:58-81`, `Views/PlaylistsView.swift:1108-1115` |
| RealizeEngine harmonic autofill / bridging / targetMs budgets / mixSuggestions | engine port is its own contract; P2 realizes literal order | `State/CollectionsStore.swift:1079-1093`, `Models/CollectionsSchema.swift:398-411` |
| Siri pocket-builder banner / App Intents / CloudKit sync / durable playback sessions | no Android counterpart planned (recorded decision) | `Views/PlaylistsView.swift:134-148`, `docs/ARCHITECTURE-ANDROID.md:148-150` |
| Favorites ♥ in collection rows | favorites store not on Android yet | `Views/CollectionSongRow.swift:15` |

## 14. Known risks

1. **Doc merge fidelity**: any drift in field names/optionality breaks the
   future S3 merge with iOS docs — test by round-tripping a REAL iOS
   `pocketdj-collections.json` through the Android codec and diffing JSON.
2. **Timestamps are epoch ms as JSON numbers (iOS `Double`)** — Android must
   write them so iOS's `Double` decode accepts them (plain numeric ms; Long
   serializes fine, but never seconds).
3. **Lossy decode is load-bearing**: skipping §1.6 reintroduces the exact
   total-loss bug iOS shipped and fixed (`Models/CollectionsSchema.swift:207-213`).
4. **updatedAt vs lastPlayedAt separation**: stamping `updatedAt` on play (or
   `lastPlayedAt` via the generic mutate path) silently corrupts both sort
   orders (`State/CollectionsStore.swift:1660-1665`).
5. **Queue-vs-list desync**: allowing setlist reorder/delete while its queue is
   playing desyncs Media3 indices — the iOS lock (`Views/SetlistDetailView.swift:120-130`)
   must be ported, not approximated.
6. **duplicateForSource must stay the ONLY duplicate path** (manual button AND
   add-sheet), else users get rival copies of one source playlist
   (`State/CollectionsStore.swift:401-417`).
