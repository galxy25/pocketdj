# History — Android Phase 1 implementation contract

Extracted from the iOS app in this worktree. Every claim cites `apple/…` file:line.
Scope: the **Plays** timeline (event log + recording semantics + UI). The **Activity**
segment (collection add/heart/remove, iOS F11) is **P2 on Android** — this spec only
reserves its seam (§7).

---

## 1. What History is (and is not)

- History is a **durable, append-only event log** of every song play on this device —
  one row per play, each carrying its own timestamp and the name of the set/mix it
  played in (`apple/PocketDJ/State/PlayHistoryStore.swift:4-11`).
- It is deliberately **NOT** the aggregate play-stats store (one count + one
  last-played per song, used by the storage prune). Same song played three times =
  three timeline rows (`PlayHistoryStore.swift:8-11`). Android P1 needs only the
  event log; an aggregate stats store is a later concern (storage manager is not P1).
- The log is shaped for a future cross-profile merge: every event has a stable UUID
  and the document carries an `installId`; merge = union by event id, re-sort by
  `playedAt` (`PlayHistoryStore.swift:13-19`). Android must preserve both identity
  fields even though no sync exists on Android yet (no CloudKit —
  `docs/ARCHITECTURE-ANDROID.md:49-50`).

---

## 2. On-disk document (local JSON, additive-optional)

iOS persists a single JSON file `pocketdj-play-history.json` in Application Support
(`PlayHistoryStore.swift:21-22,122-127`), written **atomically** on every mutation
(`PlayHistoryStore.swift:258-261`). Android mirrors it.

**Android file:** `filesDir/pocketdj-play-history.json` (app-private). Write via
temp-file + `rename` (atomic replace). Save synchronously-ordered after every
mutation (record / clear / replaceAll), as iOS does
(`PlayHistoryStore.swift:172,187,234`).

### Document shape (iOS `PlayHistoryStore.Document`, `PlayHistoryStore.swift:77-82`)

```json
{
  "schemaVersion": 1,
  "installId": "<uuid-string>",
  "events": [ { …PlayEvent… } ]
}
```

- `schemaVersion` — currently **1** (`let playHistorySchemaVersion = 1`,
  `PlayHistoryStore.swift:276`).
- `installId` — stable identity of THIS install; generated as a fresh UUID string
  when no readable document exists (`PlayHistoryStore.swift:110-120`).
- `events` — oldest → newest; **insertion order == chronological for live plays**
  (`PlayHistoryStore.swift:84-85`).

### PlayEvent shape (iOS `PlayHistoryStore.PlayEvent`, `PlayHistoryStore.swift:62-74`)

| field | type | required | meaning |
|---|---|---|---|
| `id` | UUID string | yes | stable event identity (merge/dedupe key) |
| `songId` | string | yes | catalog song id (namespaced ids come through as-is) |
| `playedAt` | number (epoch **ms**, double) | yes | when the play happened |
| `source` | string token | yes | which surface — see tokens below |
| `contextId` | string | optional | set/mix collection id (absent for Browser singles) (`:68-69`) |
| `contextName` | string | optional | set/mix display name **snapshot at record time** (`:58-61,70-71`) |
| `title` | string | optional | song-title snapshot (history stays readable after the song leaves the catalog) (`:61,72`) |
| `artist` | string | optional | artist snapshot (`:61,73`) |

`contextName`/`title`/`artist` are snapshots resolved at record time — never
re-derived on read except as a *fallback preference* (live catalog first, snapshot
second; see §6 row rendering).

### `source` tokens — persisted raw values, NEVER rename

`browser | playlist | pocket | album | setlist | mix | artist`
(`PlayHistoryStore.swift:27-29`: "Raw values are the persisted tokens — never
rename"). Android: an enum with explicit `@SerialName` for each token. Human labels
(`PlayHistoryStore.swift:31-42`): Browser, Playlist, Pocket, Album, Set list, Mix,
Artist. Icons per source (iOS SF Symbols, `PlayHistoryStore.swift:44-55`) — map to
the nearest Material Symbols on Android (list/queue-music/stack/album/queue-music/
tune/mic equivalents).

### Additive-optional decode (iron law)

- All optional fields decode leniently with defaults; **unknown keys are ignored**
  (kotlinx.serialization: `Json { ignoreUnknownKeys = true; encodeDefaults = true }`).
  A later field addition must never wipe a saved doc.
- Kotlin data classes: every field beyond the four required PlayEvent fields has a
  default (`null`); `Document.schemaVersion` defaults to `1`, `events` defaults to
  `emptyList()`, so decoding an older/newer doc always succeeds.
- iOS behavior on unreadable file: fall back to a fresh empty log + new `installId`
  (`PlayHistoryStore.swift:110-120`). Android matches — but because of the lenient
  decode above, "unreadable" should only ever mean corrupt JSON, never a schema
  evolution.

### Cap

Append-only logs grow without bound: cap at **20 000 events**, dropping the
**oldest** past the cap (`PlayHistoryStore.swift:106-108,170,239-245`). After a trim,
rebuild the derived indexes (§3).

---

## 3. In-memory store contract

Android: a single process-wide store (e.g. `PlayHistoryStore` singleton, injected),
main-thread confined for mutation like the iOS `@MainActor` store
(`PlayHistoryStore.swift:23-25`), exposing Compose-observable state.

State (`PlayHistoryStore.swift:84-99`):

- `events: List<PlayEvent>` — the log, oldest → newest.
- `installId: String`.
- `revision: Int` — monotonic, bumped on **every real mutation**; the UI keys its
  recompute on this (not on `events.size`, which is pinned once the cap is hit)
  (`PlayHistoryStore.swift:88-90,171`). On Android a `mutableIntStateOf` works.
- Two derived, **non-persisted** indexes rebuilt from `events` on load / trim /
  replace (`PlayHistoryStore.swift:96-99,247-256`):
  - `lastPlayedIndex: Map<songId, Double>` — songId → most-recent `playedAt`
    (built with `max`, `:251`).
  - `countIndex: Map<songId, Int>` — songId → number of events (`:252`).
- Reads: `lastPlayedAt(songId): Double?` and `playCount(songId): Int`
  (`PlayHistoryStore.swift:176-179`).

### record() — the one write path (`PlayHistoryStore.swift:149-174`)

```
record(songId, title?, artist?, context: {source, contextId?, contextName?},
       nowMs = now-epoch-ms): PlayEvent?
```

1. `songId` empty → ignore, return null (`:155`).
2. **30-second same-song dedup** (`recountWindowMs = 30_000`,
   `PlayHistoryStore.swift:101-104`): if `last = lastPlayedIndex[songId]` exists AND
   `nowMs >= last` AND `nowMs - last < 30_000` → **drop** (same listen: a seek /
   restart, or the double-hook where two engines both fire for one play). Return
   null, record nothing (`:156-163`).
   - **Direction guard is load-bearing:** an *older* timestamp (`nowMs < last`,
     e.g. out-of-order or clock-skewed) is a genuinely distinct play and IS
     recorded — the `nowMs >= last` clause exists so a negative delta never reads
     as "within the window" (`:158-161`).
3. Append `PlayEvent(id = new UUID, songId, playedAt = nowMs, source, contextId,
   contextName, title, artist)` (`:164-167`).
4. `lastPlayedIndex[songId] = max(existing ?? 0, nowMs)` (`:168`) — max, not
   assignment, so an out-of-order append can't move last-played backwards.
5. `countIndex[songId] += 1` (`:169`).
6. If `events.size > 20_000` trim oldest + rebuild indexes (`:170,239-245`).
7. `revision += 1`; save (`:171-172`).

`nowMs` is injectable for tests; production callers use the default now
(`:149-154`). Keep that seam on Android.

### Other mutations

- `clear()` — wipe events, **keep installId** (Settings ▸ Storage "clear history")
  (`PlayHistoryStore.swift:229-235`). Android P1: expose from Settings.
- `replaceAll(newEvents)` — test/merge seam: swap the whole log, re-cap, rebuild
  indexes, persist (`:181-188`).
- iOS also has `reloadFromDisk()` for cloud sync pulls (`:263-273`) — **no Android
  P1 counterpart** (no profile sync on Android, `docs/ARCHITECTURE-ANDROID.md:49-50`);
  don't build it.
- Demo seed seam: iOS seeds deterministic varied plays when `PDJ_SEED_HISTORY` is
  set and the log is empty, with a `PDJ_SEED_HISTORY_COUNT=N` large-set knob for
  paging tests (`PlayHistoryStore.swift:195-227`). Android: same seam via
  instrumentation args / debug BuildConfig flag — needed to screenshot/UI-test a
  populated History deterministically.

---

## 4. Recording trigger — WHO calls record, WHEN

**Trigger semantics: a play is recorded on TRACK START — the moment a new song id
begins playing — not on a listened-duration threshold.** All three iOS engines fire
on start/transition; the 30 s window in the store (not the caller) absorbs overlaps:

- **Rip/local playback** (`RipsStore`): `onPlay` fires when `nowPlaying.songId`
  *changes* — both in `play()` (`apple/PocketDJ/State/RipsStore.swift:560-562`) and
  in `setNowPlaying()` (`RipsStore.swift:606-610`). Same-song restart does not
  re-fire (id unchanged); the store's window catches anything that slips through.
- **Playback coordinator** (source-aware provider matcher): `onPlay(song.id)` fires
  the moment a provider claims the play
  (`apple/PocketDJ/Playback/PlaybackCoordinator.swift:112-122`). Rips + coordinator
  can BOTH fire for one burned play; the re-count window absorbs the overlap
  (`PlaybackCoordinator.swift:73-77`, `apple/PocketDJ/PocketDJApp.swift:369-372`).
- **Mix engine** (P3 on Android): `onSongPlayed` fires in the single transport
  funnel only on an actual not-playing → playing transition; an idempotent re-issue
  (seek/restart while already playing) records nothing
  (`apple/PocketDJ/Mix/MixEngine.swift:590-604`).

### Wiring (iOS `PocketDJApp.swift:369-407`) → Android P1 mapping

iOS hooks every play into BOTH the aggregate stats and the history log
(`PocketDJApp.swift:398-401`). Android P1 has only the history log.

**Android P1:** the Media3 playback service is the single recording site. In the
`Player.Listener`:

- `onMediaItemTransition(mediaItem, reason)` → if the new item's song id differs
  from the previously-noted id, call `record(...)`. This reproduces the
  "id-changed" gate of `RipsStore.swift:562` for both user-initiated plays and
  auto-advance.
- A repeat-one loop or seek-to-start of the same item must NOT produce new rows —
  the id gate plus the store's 30 s window guarantee that, matching iOS.
- Record **on start**, immediately — do not wait for N seconds of playback.

### Context resolution at the hook site (iOS `PocketDJApp.swift:374-407`)

iOS resolves the context the collapsed songId-only hook drops:

- Non-Mix plays (`recordNonMixHistory`, `PocketDJApp.swift:380-397`): if the song is
  in the **running sequencer queue**, attribute it to that run's **captured** origin
  — `source` = captured kind (fallback `setlist`), `contextId` = the run's
  `sourceSetlistId`, `contextName` = captured name. Otherwise it is a standalone
  **Browser** single: `{source: browser, contextId: null, contextName: null}`
  (`PlayHistoryStore.swift:140-147` — `PlayContext.browser`). Title/artist are
  resolved from the live catalog at record time (`PocketDJApp.swift:382-383`).
- The origin is **captured once at queue-start** (`SetlistPlayer.play()` captures
  `historyContextProvider(sourceSetlistId)` into `capturedHistoryContext`,
  `apple/PocketDJ/Playback/SetlistPlayer.swift:60-65,186-192`) so a later rename or
  a newer play-now mid-navigation can't retag earlier rows (`PocketDJApp.swift:386-392`).
- Kind resolution (`CollectionsStore.historyContext`,
  `apple/PocketDJ/State/CollectionsStore.swift:1232-1248`): the reserved Now
  Playing setlist takes its kind from where play-now originated
  (album/playlist/pocket/artist/browser); a real setlist is `(setlist, its name)`;
  a browser single carries no name.
- Mix plays: `source = mix`, `contextId` = current mix-session id, `contextName` =
  Auto-DJ source label during an auto-mix else the manual session name
  (`PocketDJApp.swift:400-407`). **P3 on Android.**

**Android P1 scope:** Phase 1 is Browser + Settings + History + Jukebox
(`docs/ARCHITECTURE-ANDROID.md:63-65`) — no playlists/setlists/mix yet, so every P1
play records with `PlayContext.browser` **except** album-context playback if the
Browser plays an album as a queue: then record
`{source: album, contextId: albumId, contextName: albumName}` captured at
queue-start (the iOS captured-origin doctrine above). Build the context plumbing as
a `PlayContext(source, contextId?, contextName?)` value passed into the playback
service with the queue, so P2 (playlists/setlists) and P3 (mix) only add new
callers, not new store shapes.

---

## 5. Timeline data → rows (iOS `HistoryView.buildItems`)

- **Timeline mode: one row per event** (`apple/PocketDJ/Views/HistoryView.swift:313-320`),
  displayed newest-first via the default sort (§6). Row identity is the **event
  UUID**, never the songId — a song played three times is three rows
  (`apple/PocketDJ/Browse/BrowseModel.swift:11-24`, `PlayRef.eventId`).
- **Group-by-song mode exists in iOS but is permanently off** — the mode picker was
  removed (Levi 2026-07-18: the two reads were indistinguishable); the grouping
  engine stays one flag away (`HistoryView.swift:100-104,295-311`). **Android P1:
  do not build the grouped mode or its toggle.** Do keep per-song counts (§6 row).
- **Catalog resolution with snapshot fallback:** resolve the live catalog song by
  `songId`; when the song has left the catalog, render a minimal song from the
  event's `title`/`artist` snapshots so history stays readable
  (`HistoryView.swift:324-328`).
- Per-row search key = `title + artist + albumName`, case- and diacritic-folded
  (`HistoryView.swift:335-337`).
- Recompute keys: the row set must rebuild when the catalog revision OR the history
  `revision` changes (`HistoryView.swift:43-49` — keying on `history.revision`, not
  the event count, because the count pins at the cap).

---

## 6. Timeline UI (Compose, P1)

Screen: `HistoryScreen` — dark theme, Material 3, accent `#6EA8FF`, matching the
existing `com.levi.pocketdj` skeleton style.

### Structure (top → bottom), mirroring iOS `HistoryView`

1. **Segmented control** `Plays | Activity` at the top
   (`HistoryView.swift:19-24,92-97`, a11y id `history-tab-picker`). On Android P1
   render both segments but the **Activity** segment shows a placeholder empty
   state (§7) — the control itself ships now so the P2 seam is visible.
2. **Search field** — filters by title or artist, prompt "Search title or artist"
   (`HistoryView.swift:76`).
3. **Toolbar actions** (Plays segment only — hidden on Activity,
   `HistoryView.swift:259-273`): **Sort** and **Filter** buttons opening sheets;
   the filter icon shows a "filled/active" variant when any filter is active
   (`HistoryView.swift:265-270`). A11y ids `history-sort`, `history-filter`.
4. **The list** — plain list of play rows, paged (below).

### Default order & sort/filter

- History drives its own filter/sort state with a **distinct persistence key** so
  it never clobbers the Browser's, defaulting to
  **`lastPlayedAt` descending = most-recently-played first**
  (`HistoryView.swift:26-32`, key `"pdj.history.v1"`). Android: persist History's
  query/filters/sort under its own DataStore/prefs key; default sort
  last-played-desc.
- History reuses the Browser's filter/sort machinery plus one **history-only
  field**: `lastPlayedAt` ("Last played") — numeric epoch-ms, **sortable**, filter
  op **between** only (the date-range filter, "played between May and August 2026")
  (`BrowseModel.swift:144-148`). The value comes from the row's play event
  (`BrowseModel.swift:191-192`); the filter clause min/max hold epoch-ms and the
  sheet renders date pickers for this field
  (`apple/PocketDJ/Views/FilterSheet.swift:126-127,178-182`).
- Android P1 minimum: search + sort (last-played asc/desc at minimum, plus
  whatever song sorts the P1 Browser ships) + the date-range filter. Share the
  Browser's filter/sort engine — History passes `historyMode` to include the
  history-only field (`apple/PocketDJ/Browse/BrowseState.swift:75-78,104`,
  `BrowseModel.swift:152-156`).

### Row (`HistoryView.swift:231-256`)

Standard song row (artwork thumb, title, artist — the shared Browser row), with a
**context line** beneath, aligned under the text (past the thumbnail):

```
[source-icon] {SourceLabel} · {contextName} · {relative time}          {N plays}
```

- Context label: `"{source.label} · {contextName}"`, or just the label when the
  event has no context name (`HistoryView.swift:254-256`).
- Relative time: abbreviated relative formatter ("2h ago") from `playedAt`
  (`HistoryView.swift:342-350`). Android: `DateUtils.getRelativeTimeSpanString`
  (abbreviated) or equivalent.
- **`N plays` count** shown only when the song's play count > 1
  (`HistoryView.swift:243-246`, a11y id `history-count-{songId}`). In timeline mode
  every row's `PlayRef.count` is 1 on iOS (`HistoryView.swift:316-318`), so the
  badge never shows there. **Android P1 (deliberate spec choice, task requirement
  "per-song play counts"): populate each timeline row's count from
  `countIndex[songId]`** so the badge reads "this song has N plays total" — the
  data comes from the store's existing `playCount()` read (§3); rendering rule
  (only when > 1) stays iOS-identical.
- Tap row → navigate to song detail (`HistoryView.swift:196-199`).

### Paging (History can hold 20k events)

Render only a growing **prefix** of the filtered+sorted rows — page size **120**,
growing by a page when the last rendered row appears
(`BrowseState.swift:430-451`, `HistoryView.swift:36-41,189-212`). A filter/sort/
mode change restarts paging at one page; a catalog refresh must NOT reset a
scrolled-in budget (`HistoryView.swift:56-68`). On Android, `LazyColumn` already
virtualizes rendering, but the *filter/sort compute* over up to 20k rows must still
run off the main thread (iOS runs it off the main actor, `HistoryView.swift:9-11`)
— a `snapshotFlow`/coroutine on `Dispatchers.Default`, keyed on
`(catalogRevision, historyRevision, filterSortSignature)`. Cap the submitted list
growth the same way if compose-side cost warrants; page size seam
(`PDJ_PAGE_SIZE`-style override, `BrowseState.swift:433-440`) is worth keeping for
tests.

### Empty states (`HistoryView.swift:214-229`)

- No events at all: clock icon, "No plays yet", caption "Songs you play in a Mix,
  Playlist, Pocket, Set list, or the Browser show up here." (a11y id
  `history-empty`).
- Events exist but filters exclude everything: "No plays match your filters" +
  "Adjust the filters or date range to see more."

---

## 7. Activity seam (P2 — do not build the store now)

iOS's second segment shows the **collection activity** timeline (add/heart/
remove events from `CollectionActivityStore`) as its own plain
reverse-chronological list, deliberately OUTSIDE the filter/sort machinery — a
merge into Plays was rejected because activity rows have no clean song identity to
sort/filter alongside plays (`HistoryView.swift:19-24,116-135`). Rows render
"Added X to Y / Hearted X / Removed …" headlines from event snapshots with a
relative time (`HistoryView.swift:137-172`); empty state at
`HistoryView.swift:174-186`.

**Android P1 seam:**

- Ship the `Plays | Activity` segmented control now (§6.1); the Activity segment
  renders the iOS empty-state copy ("No collection activity yet" / "Adding a song
  to a playlist or pocket, hearting a song, or removing one shows up here.",
  `HistoryView.swift:178-180`).
- Structure the screen as `when (tab) { Plays -> …; Activity -> ActivityContent() }`
  where `ActivityContent` is a standalone composable taking a (currently absent)
  activity-store parameter — P2 drops in `CollectionActivityStore` + real rows
  without touching the Plays side, exactly the iOS shape (`HistoryView.swift:99-113`).
- Do **not** define the activity event schema now; it belongs to the P2 collections
  work.

---

## 8. Android module sketch (P1)

```
com.levi.pocketdj
├── history/
│   ├── PlayHistoryStore.kt      // §2-§3: doc + record()/clear()/indexes/revision
│   ├── PlayEvent.kt             // @Serializable PlayEvent + PlaySource + Document
│   └── PlayContext.kt           // (source, contextId?, contextName?) + Browser const
├── playback/
│   └── …PlaybackService.kt      // Media3 service: onMediaItemTransition → record()
└── screens/
    └── HistoryScreen.kt         // §6 UI + §7 seam
```

Unit tests to port (they encode the contract): dedup inside/outside the 30 s
window; the `nowMs >= last` direction guard (older timestamp records); max-based
`lastPlayedIndex` update; cap-trim drops oldest and rebuilds counts; lenient decode
of a doc with unknown fields / missing optionals; revision bump on record-at-cap;
empty songId ignored.
