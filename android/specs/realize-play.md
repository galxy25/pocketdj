# Realize + Play — Android Phase 2 implementation contract

**Audience:** an engineer building the Android Playlists phase who has never seen the
iOS app. Every claim cites the iOS source of truth (`file:line` relative to the repo
root, `apple/…` unless noted). Where Android Phase 2 deliberately cuts scope, the cut
is called out as **P2 cut** with the later phase noted.

Sources of truth:

- `apple/PocketDJ/Models/CollectionsSchema.swift` — the collections document (Pocket / Playlist / Setlist shapes)
- `apple/PocketDJ/Performance/RealizeEngine.swift` — `realize()` (template → frozen performance)
- `apple/PocketDJ/Performance/SeededRNG.swift`, `Harmonics.swift`, `Interpolate.swift` — the engine's deterministic math
- `apple/PocketDJ/Models/CollectionCatalog.swift` — static membership resolution (playlist/pocket → songs)
- `apple/PocketDJ/State/CollectionsStore.swift` — realize/playNow entry points, history-context resolution
- `apple/PocketDJ/Playback/SetlistPlayer.swift` — queue semantics, skip-unplayable, advance
- `apple/PocketDJ/PocketDJApp.swift:381-399` — how a play is attributed to History

Existing Android surfaces this builds ON (do not re-invent):

- `android/app/src/main/java/com/levi/pocketdj/playback/PlaybackController.kt` — the Media3 facade (queue build, clip windows, per-item `PlayContext` extras)
- `android/app/src/main/java/com/levi/pocketdj/playback/PlayEvents.kt` — `PlayContext` + the play-event bus History consumes
- `android/specs/playback.md` §2.3, §3, §5 — manifest resolution ladder, analog clipping, queue rules
- `android/specs/history.md` §2, §4 — event shape + source tokens

---

## 1. The three tiers (mental model)

- **Pocket** — a reusable, LIVE bag of songs/albums/nested pockets (a DAG). Edits to a
  pocket auto-update the next play (`RealizeEngine.swift:8-10`).
- **Playlist** — an ordered TEMPLATE: a tree of sequences ("chapters") containing
  song/album/pocket/text nodes (`CollectionsSchema.swift:321-345`,
  `RealizeEngine.swift:3-16`).
- **Setlist** — a FROZEN, persisted performance instance produced by realizing a
  playlist ("Play → freeze"). One playlist → many setlists ("takes")
  (`CollectionsSchema.swift:482-484`, `CollectionsStore.swift:1079-1093`).

On top of these sits the reserved, reusable **"Now Playing" setlist** — the ▶ Play /
🔀 Shuffle target for playlists, pockets, albums, artists and read-only source
playlists. It is a *literal-order snapshot*, NOT a realize run (§5).

---

## 2. Collections document (on-disk, shape-compatible with iOS)

iOS persists ONE JSON file `pocketdj-collections.json` in Application Support
(`CollectionsStore.swift:118-122`), pretty-printed + sorted keys
(`CollectionsSchema.swift:572-574`). Android: `filesDir/pocketdj-collections.json`,
atomic temp-file + rename writes, save after every mutation — same doctrine as the
Android `PlayHistoryStore` (specs/history.md §2). **Field names/semantics below are
LOAD-BEARING:** a future S3 cross-device sync merges these documents, so ids travel
verbatim and names must match iOS exactly.

### 2.1 Envelope (`CollectionsDocument`, `CollectionsSchema.swift:519-565`)

```jsonc
{
  "schemaVersion": 7,              // collectionsSchemaVersion (CollectionsSchema.swift:61)
  "pockets":   [ …Pocket… ],
  "playlists": [ …Playlist… ],
  "setlists":  [ …Setlist… ],
  "folders":   [ …PlaylistFolder… ],
  "lastAddTarget":    { "kind": "pocket"|"playlist", "id": "…", "sequenceId": "…"? },  // optional
  "recentAddTargets": [ …AddTarget… ]                                                  // optional
}
```

- **Iron law (additive-optional):** every field except ids/names decodes leniently
  with a default; unknown keys ignored; a missing key can NEVER wipe the doc
  (`CollectionsSchema.swift:550-565`). kotlinx.serialization via the shared `PdjJson`.
- **Lossy per-element decode (the v5 lesson):** the `playlists` array must drop a
  single undecodable playlist WITHOUT zeroing the list — iOS wraps it in
  `LossyDecodableArray` because one bad element once wiped every playlist and the
  next save persisted the loss (`CollectionsSchema.swift:204-231, 557-559`). Kotlin:
  decode each array element to `JsonElement` first, then `runCatching` the typed
  decode per element. Apply to `playlists` and (defensively) nested `children`.
- Migration: iOS migrates `schemaVersion < 7` docs forward, but every step v0→v7 is a
  no-op identity (all changes were additive; `CollectionsSchema.swift:578-618`).
  Android: accept any version ≤ 7, write 7.

### 2.2 Ids (`CollectionsFactory`, `CollectionsSchema.swift:620-627`)

Lowercased-UUID suffixes: `pkt_` pocket, `pls_` playlist, `set_` setlist, `nd_`
node, `pnt_` pocket note, `fld_` folder. **Reserved ids** (`CollectionsSchema.swift:71-72`):

```
nowPlayingSetlistId  = "set_now_playing"
nowPlayingPlaylistId = "pls_now_playing"
```

### 2.3 Pocket (`CollectionsSchema.swift:97-137`)

| field | type | default | notes |
|---|---|---|---|
| `id`, `name` | string | required | |
| `kind` | `"harmonic"` \| `"performance"` | `harmonic` | (`:63,100`) |
| `description` | string? | nil | |
| `songIds` | [string] | [] | catalog song ids, order kept |
| `albumIds` | [string] | [] | expand to album trackList at resolve time |
| `childPocketIds` | [string] | [] | the DAG edges |
| `notes` | [PocketNote] | [] | `{id, text, position}` (`:79-82`) |
| `folderId` | string? | nil | |
| `songRepeats` | {songId: int} | {} | per-song loop counts (`:111`) |
| `sourcePlaylistId`/`sourceName`/`sourceSongIds`/`sourceSyncEnabled`/`sourceSyncedAt` | optional | nil | source-follow provenance |
| `lastPlayedAt`, `createdAt`, `updatedAt` | epoch-ms double | 0/nil | |

### 2.4 PlaylistNode (`CollectionsSchema.swift:233-254`)

`kind ∈ song | album | pocket | text | sequence`; payload per kind: `songId` /
`albumId` / `pocketId` / `text`; sequences carry `name`, `targetMs` (realize budget,
ms), `children`; any node may carry `note` (performer cue) and song nodes
`repeatCount` (`:244-252`). `Playlist` (`:321-345`) = `id`, `name`, `description?`,
`sequences` (each `.kind == sequence`; `sequences[0]` is the default chapter),
`targetMs?`, `folderId?`, source-follow fields, `lastPlayedAt?`, timestamps.

### 2.5 SetlistTrack + Setlist (`CollectionsSchema.swift:415-509`)

```jsonc
// SetlistTrack — a FROZEN snapshot row
{ "songId": "…", "artist": "…", "name": "…",          // snapshot (survives catalog changes)
  "bpm": 120.1?, "camelot": "8A"?, "lengthMs": 234567?,
  "source": "explicit" | "pocket" | "autofill",        // provenance (TrackSource, :395)
  "sequenceName": "…"?, "note": "…"?,
  "isText": true?,                                      // free-text cue, no audio
  "pocketId": "…"?,                                     // set when source == "pocket"
  "repeatCount": 3? }                                   // absent ⇒ play once

// Setlist
{ "id": "set_…", "playlistId": "pls_…", "name": "…"?,
  "seed": "…",                                          // re-realizing with this seed reproduces the tracks
  "generatedAt": 1750000000000, "totalMs": 3600000, "tracks": [ … ] }
```

Derived values (must match iOS bit-for-bit — they feed both display AND the player's
end boundary, `CollectionsSchema.swift:438-448`):

- `perPlayMs` = 0 if `isText == true`, else `lengthMs > 0 ? lengthMs : 210_000`
  (the engine's `defaultTrackMs`, `RealizeEngine.swift:52`).
- `shownMs` = `perPlayMs × normalizedRepeat(repeatCount)`.
- `normalizedRepeat(raw)` = `raw == null ? 1 : raw.coerceIn(1, 99)`;
  `storedRepeat(n)` persists `null` for ≤1, else the clamped value
  (`CollectionsSchema.swift:187-201`).

---

## 3. Pocket resolution (`resolvePocketSongs`)

The one algorithm used by realize, playNow, and counts
(`RealizeEngine.swift:86-113`; membership mirror `CollectionCatalog.swift:102-126`):

Flatten pocket P into its effective ordered songs:

1. P's own `songIds` (resolved via `songsById`; missing ids skipped),
2. then each of P's `albumIds` → the album's `trackList` → songs (in track order),
3. then RECURSIVELY each `childPocketIds` entry, same rule.

- **Cycle/revisit guard:** a `seen: MutableSet<pocketId>` shared across the whole
  walk — a pocket contributes ONCE even if referenced twice, and cycles terminate
  (`RealizeEngine.swift:97-98`).
- **Dedupe by songId,** first-seen order preserved (`RealizeEngine.swift:88-92,109-113`).

Playlist static membership (`songs(inPlaylist:)`, `CollectionCatalog.swift:87-97`):
walk every chapter's children — song → itself, album → trackList expanded, pocket →
`resolvePocketSongs` with the `seen` set shared across the WHOLE playlist (a pocket
referenced in two chapters counts once), text → nothing, sub-sequence → recurse.
This resolution (NOT the realize engine) is what ▶ Play uses (§5).

---

## 4. The realize engine (Playlist template → frozen tracks)

> **Phase 2 realizes LITERALLY** (aligned with `specs/playlists-ui.md` §11.2/§13,
> which is authoritative for the Playlists UI). `RealizeEngine.realize` expands
> the template in order — songs/albums/pockets(DAG order)/text — and tags EVERY
> track `source: explicit`. The harmonic pocket-sampling, `targetMs` budget
> prefix-fitting, and autofill/bridging described in §4.3–§4.4 below are
> **DEFERRED**: the pure math primitives (§4.1, §4.6) are ported + unit-tested,
> but `realize`/`buildSetlist` do not run them, so the realized order matches the
> playlist's static membership and ▶ Play (the §10 / §5 invariant). §4.3–§4.4
> document the deferred engine for the later slice that lights it up; the setlist
> doc shape is identical either way.

`RealizeEngine.realize(playlist, ctx, opts)` is PURE + DETERMINISTIC: no store, no
I/O, no input mutation; all randomness comes from `seededRng(seed ?? playlist.id)`
so the same seed reproduces the exact setlist on every device/runtime
(`RealizeEngine.swift:14-16,315-343`).

### 4.1 Deterministic PRNG — port bit-for-bit (`SeededRNG.swift:10-38`)

- `fnv1a(seed)`: 32-bit FNV-1a over the string's **UTF-16 code units**
  (`h = 0x811c9dc5; for unit: h = (h xor unit) * 0x01000193` with wrapping UInt32 math).
- `mulberry32(seed)`: the JS mulberry32 sequence with `Math.imul` semantics —
  Kotlin: do all math in `Int` (wrapping `*`/`+` match `imul`), convert with
  `ushr`/`toUInt()`, final value `(t xor (t ushr 14)).toUInt().toDouble() / 4294967296.0`.
- `seededRng(seed) = mulberry32(fnv1a(seed))` — returns `() -> Double` in [0,1).

The engine's ONLY rng use is the pocket anchor pick:
`anchorIdx = (rng() * n).toInt()` (`RealizeEngine.swift:213`).

### 4.2 Inputs (`RealizeCtx`, `RealizeEngine.swift:19-30`)

`songsById`, `albumsById`, `pocketsById`, and `candidates` = every catalog song with
BOTH `bpm` AND `camelot` (the autofill pool, built in
`CollectionsStore.makeCtx`, `CollectionsStore.swift:1027-1041`). A song's genre
lives on its ALBUM (`ctx.genre(of:)`, `RealizeEngine.swift:26-29`) — Android:
`albumsById[song.albumId]?.genre`.

### 4.3 Per-sequence realization (`RealizeEngine.swift:167-231`)

For each top-level sequence (chapter), with a playlist-wide `used: Set<songId>`:

- **Budget:** `targetMs = min(own targetMs if > 0 else ∞, inheritedRemainingMs)`;
  top level inherits ∞ (`:174-176`).
- **Per child node** (`placeNode`, `:187-223`), passing `remaining = targetMs − placedSoFarMs`:
  - `song` → place if resolvable; **deduped** against `used` (`:194-196,226-231`).
  - `text` → always placed, NEVER deduped, 0 ms (`:199-200`).
  - `album` → every `trackList` song in order, each deduped (`:202-207`).
  - `pocket` → resolve (§3) → `anchorIdx = floor(rng()·n)` → order as a greedy
    nearest-neighbour **harmonic chain** from the anchor (`harmonicChain`,
    `:119-145`: repeatedly append the unused song with the smallest
    `harmonicDistance` to the current one) → if a budget is active, keep the chain
    **prefix that fits** (`fitPrefix`, `:149-160`: always ≥1 song when non-empty;
    stop before the first song that would overflow, except the first) → place each,
    deduped, `source = pocket`, carrying `pocketId` (`:208-218`).
  - `sequence` (sub-chapter) → recurse with `inheritedRemainingMs = remaining` (`:219-221`).
- **Duration accounting:** a song contributes `length > 0 ? length : 210_000`,
  × `normalizedRepeat(node.repeatCount)` (`:70-78`).
- **Autofill** (only when a finite budget is set; `:183, 240-276`): repeat up to
  **200** times (`autofillCap`, `:55`): stop if remaining budget < shortest unused
  mixable candidate (`:284-293`); rank adjacent placed pairs (skipping pairs touching
  a text cue) worst-first by `harmonicDistance`; for the worst seam compute the
  midpoint `TargetPoint` via `interpolatePath(a, b, 1)` and snap the nearest unused
  candidate that fits (`nearestCandidate` with `maxMs = remaining`); insert it after
  the seam with `source = autofill`; re-rank and repeat.

### 4.4 Output (`RealizeEngine.swift:295-343`)

Each placement snapshots to a `SetlistTrack` (songId/artist/name/bpm/camelot/
lengthMs + source/sequenceName/note/pocketId, `repeatCount` via `storedRepeat`);
text cues become `isText: true` rows with `songId: ""`. `totalMs` = Σ over non-text
tracks of `lengthMs > 0 ? lengthMs : 210_000` (`:336-340` — NOTE: totalMs here does
NOT multiply by repeatCount; the store's edit paths recompute via `shownMs`, which
does — `CollectionsStore.swift:1340-1342`. Copy iOS exactly).

`buildSetlist` wraps the result in a fresh `Setlist` — the only non-deterministic
bits (new `set_` id, `generatedAt`) live in the wrapper (`:348-362`).

### 4.5 Store entry points (`CollectionsStore.swift:1073-1116`)

- `realize(playlistId, seed=null, name=null)`: seed defaults to a **fresh uid** —
  a different "take" each Play; name defaults to `"<playlist name> — take N"`
  (N = existing setlist count for that playlist + 1); appends the setlist + saves
  (`:1070-1093`).
- `realize(songIds, name)`: builds a TRANSIENT one-chapter playlist (not persisted)
  around the literal ids and runs the standard path — this is the read-only source
  playlist's ▶ Play (`:1095-1116`; caller `Views/PlaylistsView.swift:723-726`).

### 4.6 Harmonic math (ports required by 4.3)

All pure; Android already has the two shared primitives —
`Camelot.rank`/`parse` (`screens/browse/Fmt.kt:41-59`, matches iOS
`Support/Format.swift:26-38`: rank = hour×2 + (B?1:0), `keys` = 1A,1B…12B, 24
entries) and `Genre.category` (`screens/browse/Genre.kt:90`). Move/share them out of
`screens/browse` rather than duplicating.

`Harmonics` (`Performance/Harmonics.swift`):

- `camelotDistance` (`:49-58`): nil if either unparseable; same code → 0; hourGap =
  min(|a−b|, 12−|a−b|); adjacent hour same mode → 1; same hour different mode
  (relative major/minor) → 1; else `gap + (modesDiffer ? 1 : 0)`. Max 7
  (`maxCamelotSteps`, `:120`).
- `bpmDistance` (`:62-84`): nil unless both finite > 0; fold b by ×2/÷2 (≤4 times)
  while it shrinks the gap (half/double-time aware); normalize by spread 30, clamp [0,1].
- `genreDistance` (`:89-91`): same `Genre.category` → 0 else 1.
- `sentimentDistance` (`:96-104`): 1 − Jaccard of lowercased/trimmed keyword sets;
  either empty/nil → 0.5.
- `artistDistance` (`:109-113`): equal (case-insensitive, trimmed, non-empty) → 0 else 1.
- `harmonicDistance` (`:125-152`): weighted blend of
  (key: camelot/7, bpm, genre, artist, sentiment); DROP nil axes and renormalize by
  the active weight sum; all-nil → 0.5. `DEFAULT_WEIGHTS` = key 0.35, bpm 0.3,
  genre 0.2, artist 0.05, sentiment 0.1 (`:28`).

`Interpolate` (`Performance/Interpolate.swift`):

- `interpolatePath(from, to, steps)` (`:57-85`): point i has
  `ratio = (i+1)/(steps+1)`; bpm linear lerp (nil unless both anchors have bpm);
  camelot stepped along the SHORTER arc of the 24-slot wheel with JS
  `Math.round`-toward-+∞ semantics (`:31-44` — replicate `floor(x + 0.5)`);
  category = from's while ratio < 0.5 else to's ("Other" → nil, `:47-51`).
- `nearestCandidate(target, candidates, used, genreOf, weights, maxMs)` (`:90-119`):
  eligibility = not used, bpm AND camelot present, `candidateMs ≤ maxMs`
  (candidateMs = length > 0 ? length : 210_000); score =
  wKey·camelotDist + wBpm·bpmDist + wGenre·genreDist (nil axes dropped, NO
  renormalization here); ties → FIRST candidate in catalog order (determinism).

**P2 cut inside the engine:** studio-id synthetic injection
(`CollectionsStore.swift:1027-1041,1119-1147`) — Android has no Studio until
Phase 4; unknown `smp_`/`lp_`/`ptn_`/`tk_` ids simply drop like any unresolvable id
(which is exactly iOS's behavior when the lookup is unwired). Keep the studio-id
STRIP on any rip/burn-facing resolver per specs/playback.md §3.

---

## 5. `playNow` — the reserved, reusable Now Playing setlist

**This is the actual ▶ Play path.** Realize (§4) is the *"📋 Realize"* action that
mints a frozen take; ▶ Play / 🔀 Shuffle instead snapshot the LITERAL resolved order
into the reserved `set_now_playing` setlist and start the sequencer on it
(`CollectionsStore.swift:1112-1160`, `Views/PlaylistsView.swift:963-978`).

`playNow(songIds, name, shuffle, source, repeats, originId)`
(`CollectionsStore.swift:1119-1160`):

1. Record `nowPlayingSource = source` and `nowPlayingOriginId = originId` (history +
   navigation origin, §7).
2. Map ids → `SetlistTrack` snapshots from the live catalog; **unresolvable ids are
   DROPPED**; each row carries `repeatCount = storedRepeat(repeats[id] ?? 1)`.
3. `if shuffle: tracks.shuffle()` — **unseeded** system random, fresh each call
   (`:1148`). No realize, no dedup, no autofill, no pocket sampling.
4. `totalMs = Σ shownMs`; bump a monotonic `nowPlayingRevision` (an on-screen detail
   view re-snapshots on it, `:1149`).
5. **UPSERT** the reserved setlist: `id = set_now_playing`,
   `playlistId = pls_now_playing`, `seed = "now-playing"`, name = the collection's
   name; replace-in-place if present else append; save (`:1149-1157`).

Typed entry points — each ALSO stamps the collection's `lastPlayedAt` first
(`markPlayed`, the single funnel; `:1195-1212, 1666-1673`):

| call | ids | source token | repeats | originId |
|---|---|---|---|---|
| `playNow(playlistId, shuffle)` | `playableIds(forPlaylist:)` = §3 playlist membership (`:968-971`) | `playlist` | songId→repeatCount from the template's song nodes, later-wins (`:1216-1231`) | playlistId |
| `playNow(pocketId, shuffle)` | `playableIds(forPocket:)` = §3 pocket resolution (`:973-977`) | `pocket` | `pocket.songRepeats` | pocketId |
| album ▶ (`Views/AlbumDetailView.swift:82`) | album track ids | `album` | — | albumId |
| artist ▶ (`Views/ArtistDetailView.swift:79`) | artist's song ids | `artist` | — | artist key |

**Read-only source playlists (`IndexPlaylist` — "From your sources", incl. Apple
Music playlists) — shuffle-in-place semantics** (`Views/PlaylistsView.swift:672-735`):

- ▶ **Play** → `realize(songIds: source.songIds, name: source.name)` — a frozen
  setlist take, pushed WITHOUT autoplay (`:723-726`).
- 🔀 **Shuffle** → `playNow(songIds: source.songIds, name: source.name,
  shuffle: true, source: .playlist, originId: source.id)` + open Now Playing
  autoplaying — **no duplication into an editable playlist required**; the
  read-only source is never mutated, the shuffle lives entirely in the reserved
  Now Playing snapshot (`:727-735`).

Editable playlist/pocket ▶/🔀 both route through `playNow` + open the Now Playing
setlist autoplaying; if it is already on screen, no second push — the revision bump
restarts it (`Views/PlaylistsView.swift:963-978`).

**Lifecycle of the reserved docs:** purged at store launch (`CollectionsStore.swift:103`,
also on profile reload `:1696`) and hidden from setlist listings
(`:141` returns `[]` for `pls_now_playing`). A durable-session restore can later
re-materialize the doc from the live queue (`materializeNowPlayingSetlist`,
`:1166-1189`) — **P2 cut** (no durable playback sessions on Android yet).

---

## 6. Queue semantics (what the sequencer must do)

iOS `SetlistPlayer` (`Playback/SetlistPlayer.swift`) is an index-cursor sequencer
over an item list. The P2-relevant contract:

### 6.1 Items

`Item = (id, title, artist, lengthMs?, repeatCount?, uid)` — `uid` is per-INSTANCE
row identity because a song can repeat in a set; `id` alone can't identify a row
(`SetlistPlayer.swift:23-40`). Queue rows are built from a setlist's tracks by
filtering `isText != true && songId non-empty`, with
**`lengthMs = perPlayMs` and `repeatCount` carried separately** — the player ends
each SINGLE play at `perPlayMs` and loops `repeatCount` times
(`Views/SetlistDetailView.swift:73-87`). (`Intents/IntentServices.swift:188-192`
maps `lengthMs: shownMs` without repeatCount — a simplification on the intents path;
Android follows the SetlistDetailView shape.)

### 6.2 Core rules

- `play(items, sourceSetlistId)`: no-op for empty; a fresh `play` REPLACES whatever
  ran — that is the only thing that stops a set besides `stop()` and natural end
  (`SetlistPlayer.swift:183-208`). The run is tagged with the source setlist id so
  a detail screen knows whether IT is the one playing (`:47-51`), and the history
  context + navigable origin are **captured once at `play()` time** so a later
  `playNow` can't retag an in-flight run (`:60-73,188-192`).
- Playing a saved (real) setlist: `sequencer.play(playableItems(setlist),
  sourceSetlistId: setlistId)`, after stamping the parent playlist's
  `lastPlayedAt` (`Views/SetlistDetailView.swift:65-71`; harmless no-op for the
  reserved ids).
- `index` into the queue is the cursor (never track id — repeats);
  `currentSongId = queue[index].id` while running (`:42-53`).
- **Advance:** natural end → if `playsRemaining > 1` decrement + replay the SAME
  track, else `index += 1`; past the end → stop/tear down (`:633-646,677-692`).
- **skipPrevious:** `index = max(0, index − 1)`, restart — never below the top
  (`:267-274`). skipNext = manual advance (`:260-263`).
- **Live-queue edits** mutate ONLY the upcoming tail `queue[index+1…]`; the current
  slot and played head are never touched; removals/jumps address rows by `uid`, not
  position, because taps race playback (`:276-408`). P2 needs at minimum: reorder,
  remove, append, insert-next, jump-to-upcoming (P1's Jukebox accept already needs
  an insert seam).
- History is recorded on **track start**, not on a listened-duration threshold —
  rows jumped over are NOT recorded (`:377-385`, and the P1 Android bus already
  matches: `playback/PlayEvents.kt:38-44`).

### 6.3 Skip-unplayable policy (what iOS does, and the Android mapping)

iOS resolves each track's source FRESH at its turn (`playCurrent`,
`SetlistPlayer.swift:694-797`):

- burned local file → play; **device mode** with no burned file → skip immediately
  (`:739-758`);
- else stream via the coordinator (Apple Music → rip-on-demand); a **dead source**
  (coordinator error / no server / unresolvable) means no end event will ever fire →
  `advanceToNext()` NOW (`:13-15,770-773`);
- a whole-queue-unplayable device run raises a one-shot "nothing playable" banner
  instead of ending silently (`:103-110,681-687`).

**Android P2 policy** (no MusicKit, no burns — locked decisions,
`docs/ARCHITECTURE-ANDROID.md:47-54`): resolve every queue id through
`PlayResolver` at queue-build time, EXACTLY like the P1 album queue
(`playback/PlaybackController.kt:215-219`): keep `PlayAction.Stream` hits (with
their analog clip windows), **skip metadata-only/AM-only rows**, and surface the
skip count ("Playing m of n — k not playable on Android"). An all-skipped queue is
the iOS banner case: fail with a message, never start silently.
**P2 cut:** no per-row rip-on-demand inside a setlist run (single-track ▶ keeps its
P1 rip ladder); a rip-required row is skipped like metadata-only. Revisit when burns
land. Unbounded-analog rows (durationMs null): clip start only — the item runs to
the album file's natural end; do NOT queue-truncate here (that P1 rule,
`PlaybackController.kt:234-241`, exists for *album* up-next; in a setlist the next
row is usually a different file). Accept the tail-overrun for P2 and note it.

Media3 gives auto-advance, repeatCount is NOT native: implement per-item repeat by
`setMediaItems` with the item duplicated `normalizedRepeat` times consecutively
(simplest faithful mapping: N consecutive queue entries with the same songId +
same uid-group), OR intercept `MEDIA_ITEM_TRANSITION` — choose duplication; it
keeps ExoPlayer's gapless preload and needs no custom advance logic. History dedup
is unaffected (the 30 s same-song window collapses the repeats,
specs/history.md §4).

---

## 7. Play context for History (P2 extensions)

iOS attribution (`PocketDJApp.swift:381-399`): a play of a song **in the running
queue** is attributed to the run's CAPTURED context —
`(source = captured kind, contextId = sourceSetlistId, contextName = captured
name)`; anything else is a plain `browser` single.

Captured context resolution (`CollectionsStore.historyContext`,
`CollectionsStore.swift:1237-1249`):

| run source | source token | contextId | contextName |
|---|---|---|---|
| Now Playing run started from a playlist | `playlist` | `set_now_playing` | playlist name |
| … from a pocket | `pocket` | `set_now_playing` | pocket name |
| … from an album / artist / source-playlist-shuffle | `album` / `artist` / `playlist` | `set_now_playing` | that collection's name |
| a REAL (frozen) setlist | `setlist` | the setlist id | setlist name (e.g. "Roadtrip — take 3") |
| single-row ▶ | `browser` | null | null |

Android: the plumbing ALREADY exists — `PlayContext` rides every MediaItem's request
extras and is captured once at queue build (`playback/PlaybackController.kt:306-325`,
`playback/PlayEvents.kt:14-16`). P2 adds the companions
`PlayContext.playlist/pocket/setlist/artist(id, name)` next to the existing
`album(...)` (`playback/PlayEvents.kt:33-36`) and passes the table above at
queue-build. Tokens are the persisted history values — never rename
(specs/history.md §2). The navigable origin (`originCollection`,
`CollectionsStore.swift:1255-1268` — the Up Next header's "open collection" button)
is a UI nicety: keep `nowPlayingOriginId` in the store so the seam exists, wire the
button when the Now Playing screen grows one.

---

## 8. Android P2 surface map (what to build, on what)

1. **`data/collections/CollectionsModels.kt`** — §2 shapes via `PdjJson`
   (additive-optional + lossy playlist elements).
2. **`data/collections/CollectionsStore.kt`** — load/save
   `filesDir/pocketdj-collections.json` (atomic write, corrupt-quarantine like
   `PlayHistoryStore`); CRUD for pockets/playlists/folders; `resolvePocketSongs` /
   `playableIds(...)` (§3); `realize(playlistId)` / `realize(songIds, name)` (§4.5);
   `playNow(...)` upsert (§5); `historyContext` (§7); purge reserved docs at init.
3. **`engine/`** (pure, unit-test-first): `Prng.kt` (§4.1 — test against known
   seed→sequence vectors generated from the Swift/TS impl), `Harmonics.kt`,
   `Interpolate.kt`, `RealizeEngine.kt` (§4.3-4.4). Share `Camelot`/`Genre` from
   browse.
4. **`playback/PlaybackController.kt` additions** — `playQueue(items:
   List<QueueItem>, context: PlayContext)`: resolve per §6.3, build MediaItems with
   clip windows + context extras (reuse `mediaItem(...)`,
   `PlaybackController.kt:306-343`), `setQueueAndPlay(queue, startIndex = 0)`;
   expose queue state (current index, upcoming) for the Now Playing screen; repeat
   expansion per §6.2/6.3.
5. **`screens/playlists/`** — Playlists tab (replaces the P2 placeholder):
   list + folders, playlist detail (chapters/nodes), pocket detail, setlist detail
   (frozen rows, ▶ Play All), read-only source playlists from the catalog's
   `IndexPlaylist` (`data/catalog/IndexModels.kt:46-50`) with Play/Shuffle per §5.

---

## 9. Phase-2 cut summary

**Ships:** collections document + store (§2), pocket DAG resolution (§3), LITERAL
realize (template order, all tracks `explicit` — the harmonic engine of §4.3–§4.4
is DEFERRED; its math primitives §4.1/§4.6 are ported + tested), playNow reserved
Now Playing setlist with shuffle + read-only-source shuffle-in-place (§5), queue
playback with skip-unplayable + repeatCount (§6), history context extensions (§7),
setlist post-Play edits (rename/delete/remove-track/reorder/add-note —
`CollectionsStore.swift:1316-1379`).

**Deferred (with phase/reason):**

- Harmonic realize engine (pocket sampling, `targetMs` budget prefix-fitting,
  autofill/bridging — §4.3–§4.4) — its own later slice; P2 realizes literal order
  (specs/playlists-ui.md §11.2/§13). Math primitives (§4.1/§4.6) already ported.
- Studio synthetic songs in realize/playNow — Phase 4 (no Studio on Android).
- Rip-on-demand inside a setlist queue; burns/offline/device-mode — with the
  offline/burns phase (P1 cut carried forward, specs/playback.md §5).
- Durable playback sessions + `materializeNowPlayingSetlist` restore — later phase
  (iOS `PlaybackSessionStore`, `SetlistPlayer.swift:805-881`).
- Mix suggestions on tracks (`mixSuggestions` — deferred on iOS too,
  `CollectionsSchema.swift:429`), CSV/`.pdjcollection` export-import
  (`CollectionsStore.swift:1385-…`), source-follow auto-sync of duplicated
  playlists, favorites, Activity history segment.
- Live HLS rows in a setlist queue (P1 nice-to-have carried forward).
