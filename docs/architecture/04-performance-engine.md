# Chapter 4 — Performance Engine: pockets → playlists → setlists (+ the Mix engine)

> Part of the [PocketDJ Architecture Book](../ARCHITECTURE.md). Prereqs:
> [Ch. 1 Foundations](./01-foundations.md), [Ch. 3 Catalog & Data Model](./03-catalog-and-data-model.md).
> This is the **heart of the goal — "Performance Playlists Producer"** — the engine
> that turns reusable templates into ordered sets, **the two-deck Mix board that
> beat-matches and mixes them live** (§7), and the chapter where **AI-assisted
> auto-building will land** (§4).

The product story for these screens is
[Perform From the Crate](../storybook/perform-pockets-playlists-setlists.md) in the
storybook. This chapter is the systems view of the same nouns and the engine that
connects them.

---

## 1. Three nouns, one pipeline

**Why.** A DJ doesn't want a flat list; they want to **compose the shape of a night**
(a warm-up, a peak, closers), keep reusable crates of records that mix well, and then
**roll a concrete, ordered set** they can perform from — and re-roll for a different
feel. Three types model exactly that, and a single function (`realize`) turns the
reusable template into the frozen performance.

```
  Pocket ───────────────┐  reusable, harmonically-coherent crate (DAG, nestable)
  (pkt_)                 │
                         ▼
  Playlist ──────────── realize(seed) ───────────▶  Setlist
  (pls_) TEMPLATE        │   • expand albums → tracks        (set_) FROZEN INSTANCE
  ordered Sequences      │   • sample over-budget pockets    snapshotted tracks
  (chapters, targetMs)   │   • autofill temporal gaps        provenance per track
                         │     with harmonic bridges
                         ▼
                 one Playlist → many Setlists (a performance history)
```

**Reading the diagram.** A **Pocket** is a reusable grouping of harmonically-similar
songs/albums that can **nest** other pockets (a cycle-guarded DAG) — drop a whole
vibe into any set. A **Playlist** is a **template**: ordered **Sequences**
("chapters"), each optionally carrying a time budget (`targetMs`). Hitting ▶ Play
runs **`realize(seed)`**, which (a) expands album nodes to their tracks, (b) **samples**
over-budget pockets down to fit a sequence's budget, and (c) **autofills** temporal
gaps with harmonic **bridge** tracks — then freezes the result as a **Setlist**: a
concrete, ordered, *snapshotted* track list. One template yields many setlists (each
a different "take"), forming a performance history.

---

## 2. The realize engine

**Why.** The whole point of the three-noun pipeline is that the DJ *composes a shape*
once and *rolls a concrete set* many times. That demands a function that is (a) **pure
and deterministic** — same template + same seed ⇒ byte-for-byte the same setlist, so a
performance can be reproduced or shared — and (b) **musically aware** — it must respect
each chapter's time budget *and* smooth the roughest transitions automatically. `realize`
is that function.

**Source of truth.** `src/engine/realize.ts` (the engine), `src/engine/harmonics.ts`
(`harmonicDistance`, `DEFAULT_WEIGHTS`, `HarmonicWeights`), `src/engine/interpolate.ts`
(`interpolatePath`, `nearestCandidate`), `src/lib/prng.ts` (`seededRng` =
`mulberry32(fnv1a(seed))`), `src/types/collections.ts` (shapes). The native port lives
in `apple/PocketDJ/Performance/` (`RealizeEngine.swift`, `Harmonics.swift`,
`Interpolate.swift`, `SeededRNG.swift`) and reproduces the same numbers.

### 2.1 The pipeline at a glance

```
 realize(playlist, ctx, seed):                                   PURE · DETERMINISTIC
   rng  = seededRng(seed ?? playlist.id)        ← mulberry32(fnv1a(seed)): float in [0,1)
   used = ∅  (songIds placed anywhere — dedupes ACROSS chapters + guards autofill)

   for each SequenceNode (chapter) in playlist.sequences, IN ORDER:        ── §2.2 ──
     realizeSequence(seq, inheritedRemaining = ∞):
        targetMs = min(seq.targetMs>0 ? seq.targetMs : ∞, inheritedRemaining)
        hasBudget = targetMs is finite and > 0

        (A) WALK children left→right; each consumes budget BEFORE the next:  ── §2.3 ──
              remaining = hasBudget ? targetMs − placedMs(placed) : ∞
              placeNode(node, remaining):
                SongNode   → ctx.songsById[songId]      source:'explicit'  (dedup)
                TextNode   → no-audio CUE row           source:'explicit'  (NEVER dedup, 0 ms)
                AlbumNode  → album.trackIds in order     source:'explicit'  (dedup each)
                PocketNode → resolvePocketSongs(DAG)  →  source:'pocket'
                               anchorIdx = ⌊rng()·n⌋  → harmonicChain → fitPrefix(remaining)
                Sub-seq    → realizeSequence(node, inheritedRemaining = remaining)  (recurse)

        (B) if hasBudget:  autofill(placed, targetMs)   ← fill the temporal gap  ── §2.4 ──

   snapshot every Placed → SetlistTrack (artist/bpm/camelot/length inline)        ── §2.5 ──
   totalMs = Σ (lengthMs>0 ? lengthMs : DEFAULT_TRACK_MS)   over non-text tracks
   → Performance { tracks, totalMs, stats{ sequences, explicit, pocketSampled, autofilled } }

 buildSetlist(...) = realize(...) wrapped with newSetlistId() + generatedAt (the ONLY
                     non-deterministic bits live in the wrapper, never in realize itself)
```

**Reading the diagram, box by box.**

- **`rng = seededRng(seed ?? playlist.id)`** — every random choice in the run pulls from
  one seeded stream, consumed strictly in walk order. The seed defaults to the playlist
  id (so a fresh playlist still realizes deterministically); `buildSetlist` stores the
  seed it used in `Setlist.seed`, and re-running `realize` with that seed reproduces the
  exact track list. See §2.6.
- **`used` set** — every `songId` placed *anywhere* in the performance is recorded here.
  It dedupes across chapters (a song explicitly placed in chapter 1 won't be re-sampled
  by a pocket in chapter 2) and it is the guard that stops autofill from inserting a song
  already in the set. Text cues are exempt (they carry no song id).
- **`for each SequenceNode … IN ORDER`** — chapters are realized sequentially; their
  placed tracks are concatenated in chapter order, which is what gives the setlist its
  warm-up → peak → closers shape.
- **`targetMs = min(own, inheritedRemaining)`** — the effective budget of a sub-sequence
  is the smaller of its *own* `targetMs` and *whatever the parent has left*, so a
  budget-less sub-chapter under a budgeted parent samples/prefixes to fit the parent's
  leftover time instead of overflowing it.
- **(A) WALK children** — earlier blocks consume budget before later pockets sample, so a
  pocket near the end of a chapter only fills the time the explicit picks left behind. The
  five node kinds are detailed in §2.3.
- **(B) autofill** — runs only under a real budget that isn't yet full; it bridges the
  *worst* harmonic seams first (§2.4).
- **snapshot** — each placement is frozen into a `SetlistTrack` with its metadata copied
  inline (§2.5), so the setlist reads standalone even if the catalog or pockets change.

### 2.2 The catalog context (`RealizeCtx`)

`realize` resolves ids against a read-only **`RealizeCtx`** (`realize.ts`):
`songsById`, `albumsById`, `pocketsById`, and a **`candidates`** pool — *the full catalog
of songs that have BOTH a `bpm` AND a `camelot`*. The candidate pool is the only thing
autofill is allowed to draw bridges from: a bridge must be beat- and key-mixable, so songs
missing either field can never be inserted (they can still be placed explicitly or via a
pocket — they just can't be an *autofill* bridge). The native store builds this context
from `AppModel`'s `songsById` / `albumsById` plus a `candidates` filter on
`bpm != nil && camelot != nil` (`CollectionsStore.realize`).

### 2.3 Resolving the five node kinds

For each chapter the walk turns nodes into ordered `Placed` records:

- **`SongNode`** → `ctx.songsById[songId]`, `source: 'explicit'`, carrying the node's
  `note`. Deduped by `songId`.
- **`TextNode`** → a no-audio **cue** row (`isText: true`), `source: 'explicit'`,
  contributing **0 ms**. Cues are **never** deduped (you may want the same "mic break"
  twice).
- **`AlbumNode`** → expands to `album.trackIds` *in tracklist order*, each resolved via
  `songsById`, each `source: 'explicit'`, each deduped.
- **`PocketNode`** → resolved **lazily** at realize time (so editing a pocket auto-updates
  the next Play). `resolvePocketSongs(pocketId, ctx)` flattens the pocket **DAG** into its
  effective ordered song list: (1) own `songIds`, (2) songs of own `albumIds`
  (`album.trackIds → songsById`), then (3) each child pocket recursively — **in that
  order**. The flatten is **cycle-guarded** by a `seen` set of visited pocketIds and
  **deduped** by `songId` (first-seen order preserved). The resolved songs are then ordered
  into a coherent chain (§2.3.1) and, under a budget, cut to a fitting prefix (§2.3.2).
- **Sub-`SequenceNode`** → `realizeSequence` recurses, *inheriting the parent's remaining
  budget*; its placements already respect `used`, and are concatenated in place.

#### 2.3.1 Pocket ordering — `harmonicChain`

A pocket's effective songs are ordered into a coherent harmonic chain. `harmonicChain`
picks an **anchor** at `anchorIdx = ⌊rng() · n⌋` (the only randomness in pocket handling —
seeded, hence reproducible), then greedily appends the **nearest unused** song by
`harmonicDistance` until all are placed. This is a deterministic nearest-neighbour walk:
ties resolve to the first candidate encountered (stable input order).

`harmonicDistance(a, b, weights)` (`harmonics.ts`) is a weighted blend in `[0,1]` over five
axes — **key** (Camelot-wheel steps, normalized by `MAX_CAMELOT_STEPS = 7`), **bpm**
(half/double-time-aware, clamped at `BPM_SPREAD = 30`), **genre** (0 if same star-map
category else 1), **artist** (0 if same else 1), **sentiment** (1 − Jaccard of keyword
sets). `DEFAULT_WEIGHTS = { key: .35, bpm: .3, genre: .2, artist: .05, sentiment: .1 }`.
It is **null-safe**: any axis whose raw distance is null (missing bpm/key) is *dropped* and
the remaining weights are renormalized, so the blend never collapses toward 0 just because
audio metadata is absent; if every axis is missing it returns the neutral `0.5`.

#### 2.3.2 Budget prefix — `fitPrefix`

Under a finite `remainingMs`, the chain is cut to the prefix whose cumulative duration
fits. `fitPrefix` always returns **≥ 1 song** when the chain is non-empty and the budget is
positive (so a pocket never contributes *nothing* just because its first track overshoots a
tiny budget), then stops at the first track that would overflow. A song's duration is
`lengthMs` when positive, else `DEFAULT_TRACK_MS = 210_000` (3:30).

### 2.4 Harmonic autofill — bridging the worst seams

**Why.** After the explicit picks and sampled pockets are placed, a budgeted chapter
usually has *time left over* and *rough transitions* between some adjacent tracks. Autofill
spends the leftover time **buying smoothness**: it inserts catalog tracks that bridge the
roughest adjacencies first.

```
 autofill(placed, targetMs):                          (only when hasBudget; placed ≥ 2)
   repeat up to AUTOFILL_CAP (200) times:
     remaining = targetMs − placedMs(placed)
     shortest  = min songMs over UNUSED mixable candidates   (bpm AND camelot present)
     if shortest == null  OR  remaining < shortest:  STOP     ← nothing more can fit

     seams = indices i where placed[i] AND placed[i+1] are songs (skip cue-adjacent seams)
     sort seams by harmonicDistance(placed[i], placed[i+1]) DESCENDING   ← worst first

     for i in seams (worst → best):
        target = interpolatePath(placed[i].song, placed[i+1].song, 1)[0]   ← ONE midpoint
        bridge = nearestCandidate(target, candidates, used, weights, maxMs = remaining)
        if bridge exists and not used:  pick this seam;  break
     if no seam yielded a fitting bridge:  STOP

     splice bridge into placed AT i+1   (source:'autofill');   used.add(bridge.id)
```

**Reading it, line by line.**

- **`remaining` / `shortest` gate.** Each pass recomputes the leftover budget and the
  *shortest* still-usable mixable candidate. If even that won't fit, autofill stops — the
  chapter is as full as it can get.
- **`seams` + worst-first sort.** Only adjacencies where *both* sides are real songs are
  bridgeable (a cue has no key/tempo to bridge across). The seams are ranked by
  `harmonicDistance` **descending** so the engine smooths the *roughest* transition it can
  before touching the easy ones.
- **`interpolatePath(from, to, 1)` → one midpoint `TargetPoint`.** `interpolatePath`
  (`interpolate.ts`) lays out evenly-spaced bridge targets between two anchors; here we ask
  for a single midpoint (`ratio = 1/2`). A `TargetPoint` carries a **linear-lerped bpm**, a
  **Camelot code stepped toward the target along the shorter wheel arc** (24-slot wheel via
  `stepCamelot`, rounding to a discrete slot), and the **genre category** in force at that
  ratio (`from`'s while `ratio < 0.5`, else `to`'s). Any axis whose anchors lack data is
  `null`.
- **`nearestCandidate(target, …, maxMs = remaining)`.** Picks the catalog song closest to
  that target. Eligibility: not in `used`, has **both** bpm and camelot, and `songMs ≤
  maxMs`. Score = `wKey·camelotDistance + wBpm·bpmDistance + wGenre·genreDistance`, with
  null axes dropped (a target with no key ranks purely on bpm+genre). Passing
  `maxMs = remaining` means a single too-long harmonically-closest candidate never aborts
  the fill — a shorter fitting candidate, or the next-worst seam, is used instead — so the
  post-pick fit check is a true invariant, not a loop-killer. Ties resolve to the first
  candidate (deterministic).
- **Take the first seam that yields a fitting bridge, splice, re-rank, repeat.** After each
  insert the seam set changes (the new bridge created two new adjacencies), so the next pass
  re-ranks from scratch and again targets the current worst seam. The loop ends when the
  budget can't fit the shortest candidate, no seam yields a fitting bridge, or the
  `AUTOFILL_CAP = 200` safety valve trips (a guard against pathological candidate pools).

The inserted track is tagged `source: 'autofill'` (rendered **`↔ bridge`** in the UI).

### 2.5 Snapshot → `SetlistTrack` (the freeze)

Each `Placed` is frozen by `snapshot` into a `SetlistTrack`. For a song it copies
`songId`, `artist`, `name`, `bpm`, `camelot ?? null`, `lengthMs`, plus provenance
(`source`, `sequenceName`, optional `pocketId`/`note`). For a text cue it emits an empty
`songId`, `isText: true`, `bpm`/`camelot` null, the cue text as `name`. `mixSuggestions`
is intentionally left undefined — a reserved seam (§4). Because every field is copied
inline, the setlist reads standalone even if the catalog or pockets change afterward.

`buildSetlist` wraps `realize` into a persisted `Setlist { id, playlistId, seed,
generatedAt, totalMs, tracks }`. The track **selection** is fully seeded inside `realize`;
the only non-deterministic bits — `newSetlistId()` and the `generatedAt` timestamp — live
in this wrapper, never in `realize`.

### 2.6 Determinism

`realize` is pure: no DB, no React, no network, no input mutation. Every random choice
(pocket anchors) is drawn from `seededRng(seed ?? playlist.id)` =
`mulberry32(fnv1a(seed))`, consumed in walk order. The native port reproduces the same
numbers bit-for-bit: `fnv1a` accumulates in a `UInt32` with wrapping `&*`/`&+`, and
`mulberry32` mirrors the JS `Math.imul`/`>>> 0` sequence, dividing by `4294967296` to land
in `[0,1)`. Same template + same seed ⇒ the identical setlist. The `seed` is the
determinism knob: re-running with the same seed reproduces the exact setlist; pressing Play
again uses a fresh seed for a different take.

---

## 3. iTunes playlist mirroring

**Why.** A user's existing Apple Music playlists are free templates — importing them
means the catalog arrives pre-populated with sets the user already curated.

**What.** The Apple Music indexer emits `IndexJson.playlists[]` (`IndexPlaylist {id,
name, songIds[]}`). On import, each becomes a `Playlist` with
`importedFrom:{sourceId, externalId}`. Re-importing the source **refreshes mirrors by
stable id**; hand-built playlists never carry `importedFrom` and are never clobbered.
Removing the source drops its mirrors (hand-built ones survive, degrading gracefully
for any referenced items). Refs to songs not in the loaded catalog are kept as cues.

---

## 4. The AI seam — auto-building (coming)

> **Status: deferred, but the schema and engine seams already exist so lighting it
> up needs no migration.** This is the next major pillar of "Performance Playlists
> Producer." The *mixing* half is not hypothetical — a first-party two-deck DJ engine
> with beat-matching and a timed **Auto-Mix** auto-DJ is built (§7). What remains
> deferred here is **AI-curated auto-*building*** of the set itself (a smarter
> `realize()` ordering + populated `mixSuggestions`).

The architecture deliberately reserves three hooks so AI features slot in without
breaking the data contract:

```
 (a) MixSuggestion (collections.ts) — per-track ranked "mix it with" candidates
       { songId, artist,name, bpm, camelot, basis:'pocket'|'bpm-key', pocketId?, score? }
       SetlistTrack.mixSuggestions?:MixSuggestion[]   ← field exists NOW, unused
       intended producer: src/engine/mixSuggest.ts (deferred)

 (b) PocketKind 'performance' (collections.ts) — a DJ/AI-curated set that deliberately
       breaks strict harmonic bounds. Membership is type-agnostic, so the new kind
       needs NO schema change — only 'harmonic' is built today.

 (c) realize() autofill — already key-matches bridge tracks (the harmonic-interpolation
       seam). An AI sequencer would extend/replace the sampling + autofill heuristics
       with a learned ordering, still emitting the same SetlistTrack shape.
```

**Reading the seams.** **(a)** Every `SetlistTrack` already has an optional
`mixSuggestions` array and there's a defined `MixSuggestion` shape (pocket-co-member
similarity first, raw bpm+key compatibility as fallback). The producer
(`src/engine/mixSuggest.ts`) is deferred, so the UI shows a dormant "Mix suggestions"
seam today; populating the field later requires no migration. **(b)** `PocketKind`
already includes `'performance'` — a future AI-curated crate that breaks strict
harmonic rules — and because pocket membership is type-agnostic, no schema change is
needed to build it. **(c)** `realize()`'s autofill already does harmonic
interpolation; an AI sequencer would slot in as a smarter sampling/ordering strategy
behind the same `realize` → `Setlist` boundary, so every downstream consumer
(export, playback, burn) keeps working unchanged.

**Native parity.** The SwiftUI apps carry a faithful, byte-compatible port of the
engine (`apple/PocketDJ/Performance/`): `RealizeEngine.realize(_:_:_)` /
`buildSetlist` mirror `realize.ts` (album expansion, cycle-guarded pocket flatten +
dedup, per-sequence `fitPrefix` budgets, and the same worst-seam-first **autofill**),
`Harmonics.swift` / `Interpolate.swift` port the metrics + geometry, and
`SeededRNG.swift` reproduces `mulberry32(fnv1a(seed))` exactly — so a given template +
seed yields the same setlist on web and native. The `Setlist` / `SetlistTrack` /
`MixSuggestion` shapes live in `CollectionsSchema.swift` (versioned, lenient-decode,
back-compat `setlists: [Setlist]`), and `CollectionsStore.realize(playlistId:)` builds
the `RealizeCtx` from `AppModel`'s catalog (its `candidates` pool = songs with both
`bpm` and `camelot`). `mixSuggestions` is the same reserved seam there as on the web.

**Design rule for whoever builds the AI pillar:** keep the `realize` →
`Setlist{tracks: SetlistTrack[]}` contract intact. Produce richer orderings and
populate `mixSuggestions`; do **not** change the snapshot/provenance shape, or
existing setlists, exports, and the rip/burn flows (Ch. 5) break.

### 4.1 The Siri "Create Pocket" builder — the AI seam's first consumer (native)

The seam is no longer entirely dormant: the native app's **`CreatePocketIntent`**
(*"Create a pocket in PocketDJ"*, Ch. 7 §7) builds a pocket from a natural-language
brief — *"optimistic soul, funk, r&b or disco songs from 1960 to 1989"* — with a
4-step pipeline in `apple/PocketDJ/Intents/PocketBuilder.swift`:

1. **Parse (LLM)** — Apple's on-device Foundation model (iOS 26/macOS 26,
   availability-gated behind `PocketBriefModelFactory`; the app still deploys to
   iOS 18/macOS 15) extracts `{moods, genres, yearFrom, yearTo}` via guided
   generation (`@Generable`).
2. **Search (deterministic, tested)** — `PocketCandidateSearch` ranks the whole
   merged catalog: **exact** year-range filter, **fuzzy** genre (substring either
   way, or same star-map `Genre.category`), and **vector** mood similarity —
   `NLEmbedding` word vectors, cosine, best-match-per-brief-mood — with a
   token-overlap fallback; sentiment-less songs (most of Apple Music) stay eligible
   on genre+year. Top-80 become compact `id|title|artist|genre|year|len|moods` rows.
3. **Curate (LLM)** — a fresh 4,096-token session picks + orders songs from those
   rows and names the pocket.
4. **Fit + persist (deterministic, tested)** — `PocketFitter` greedily fits the
   picks to the minute budget (default 90), then
   `CollectionsStore.createPocket(_:songIds:description:)` persists a plain
   **literal-member pocket** — the schema's existing shape, zero migration, and the
   brief is kept as the pocket's `description`.

The intent returns immediately ("it'll show up in Pockets shortly") and
`PocketBuilderService` (`@Observable`, app-scoped) runs the build async — the
model calls are stubbed behind `PocketBriefModel` in unit tests. This is pillar
(b)'s spirit (an AI-curated crate) delivered through the existing pocket contract;
the smarter-`realize()` ordering + `mixSuggestions` producer remain the open seams.

---

## 5. Export — performance leaves the app

Exporting a **playlist / pocket / set list** (and a **session's tracklist**, §7.8) offers **two
formats** via a `.confirmationDialog` picker (default **PocketDJ**):

- **PocketDJ (full metadata)** — a tiny `.pocketdj.zip` (`.playlist.pocketdj.zip` /
  `.pocket.pocketdj.zip`) that references the catalog **by id** (≈4 KB), keeps everything PocketDJ
  knows, and is **re-importable** into the app; a `portable` bundle variant carries the songs for a
  foreign/empty catalog.
- **CSV (tracklist)** — a **universal** list built by
  [`TracklistCSV`](../../apple/PocketDJ/Support/TracklistCSV.swift): header
  `#, Title, Artist, Album, Year, Genre`, **1-indexed play position**, CRLF line endings + a trailing
  CRLF and doubled-quote escaping (PWA parity). It is **deliberately universal-columns-only** —
  BPM / key / segment / provenance are intentionally *left out* (that's what the PocketDJ format is
  for), so the CSV drops cleanly into any spreadsheet, DJ app, or database. The rows come from
  `AppModel.tracklistCSVRows(forSongIds:)` (song → album name/genre, year song-then-album);
  `CollectionsStore.exportPlaylistCSV / exportPocketCSV / exportSetlistCSV` and
  `MixSessionsView.exportCSV()` are the four entry points.

Separately, the `burn-setlist` **tooling skill** (Ch. 5) consumes a richer
`#,Artist,Title,BPM,Key,Length,Source,Sequence,Song ID` CSV — the **Song ID** column lets it resolve
each track's raw-rip segment in O(1). That Song-ID export is the PWA/tooling path; the native app's
own tracklist CSV above is the universal, portable one.

---

## 6. Play / Shuffle — the reusable "Now Playing" setlist (native)

**Why.** `realize()` (§2) freezes a **new** setlist every Play — the right behaviour for
*rolling a take* you keep in history, but the wrong one for the everyday "just play this
playlist *now*, in order" tap: a DJ pressing ▶ on a playlist or pocket doesn't want a new
history entry and an autofilled/sampled/deduped reorder, they want **exactly these songs,
in this order**, playing immediately. So Play/Shuffle take a separate, lighter path that
backs a **single reused setlist** while the realize-take path moves to its own button.

**Source of truth:**
[`apple/PocketDJ/State/CollectionsStore.swift`](../../apple/PocketDJ/State/CollectionsStore.swift)
(`playNow(songIds:/playlistId:/pocketId:, shuffle:)`, `nowPlayingRevision`),
[`apple/PocketDJ/Models/CollectionsSchema.swift`](../../apple/PocketDJ/Models/CollectionsSchema.swift)
(`nowPlayingSetlistId = "set_now_playing"`, `nowPlayingPlaylistId = "pls_now_playing"`),
[`apple/PocketDJ/Views/PlaylistsView.swift`](../../apple/PocketDJ/Views/PlaylistsView.swift)
+ [`apple/PocketDJ/Views/PocketsView.swift`](../../apple/PocketDJ/Views/PocketsView.swift)
(the ▶/🔀 buttons), [`apple/PocketDJ/Views/SetlistDetailView.swift`](../../apple/PocketDJ/Views/SetlistDetailView.swift)
(`SetlistLaunch` nav value + autostart).

```
 ▶ Play / 🔀 Shuffle on a playlist/pocket  →  CollectionsStore.playNow(playlistId:/pocketId:, shuffle:)
   resolve songIds (playlist: songIds(forPlaylist:) literal · pocket: DAG-resolved order)
        ▼  playNow(songIds:, name:, shuffle:)        ── NOT realize: no autofill/sample/dedup
   tracks = songIds.compactMap { songsById[$0] → SetlistTrack(snapshot, source:.explicit) }
            └─ DROPS ids with no catalog song (literal order otherwise preserved)
   if shuffle: tracks.shuffle()                      ── fresh random order each call
   nowPlayingRevision &+= 1                           ── monotonic restart token (never epoch-ms)
   UPSERT the reserved setlist  id=set_now_playing / playlistId=pls_now_playing  (replace-in-place)
        ▼
   navigate → SetlistLaunch{ setlistId: set_now_playing, autoplay: true }
        ▼  SetlistDetailView
   .onAppear  guard autoplay && !didAutostart → start Play-All (§Ch.5 §10 SetlistPlayer)
   .onChange(nowPlayingRevision) → re-snapshot the freshly-upserted set + restart (Shuffle re-tap)
```

**Reading the diagram.** Both buttons funnel through **`playNow`**, which builds the
track list **directly** from the resolved song ids — for a playlist
`songIds(forPlaylist:)` (literal node order), for a pocket the DAG-flattened order — and
turns each into a `SetlistTrack` snapshot with `source: .explicit`. It is **deliberately
not `realize()`**: there is **no** autofill bridging, no over-budget pocket sampling, and
no cross-chapter dedup — ids that don't resolve to a catalog song are simply **dropped**,
and everything else keeps its literal order (or, for 🔀 Shuffle, a freshly randomized one
each call). The result **upserts one reserved setlist** (`set_now_playing` /
`pls_now_playing`, replaced in place — last-writer-wins) rather than appending a new take,
and bumps a **monotonic `nowPlayingRevision`** (`&+=`, so rapid taps never collide the way
epoch-ms timestamps could). This reserved setlist is **cleared on launch** (it's a
per-session scratch set, never restored) and **hidden from setlist history** —
`setlists(forPlaylist:)` returns `[]` for `pls_now_playing` and filters the reserved id out
elsewhere — so it never shows up as a saved take.

Tapping ▶/🔀 then navigates to **`SetlistDetailView`** via a **`SetlistLaunch{setlistId,
autoplay}`** navigation value and **autostarts** Play-All (the `SetlistPlayer` sequencer,
[Ch. 5 §10](./05-playback-and-rip-on-demand.md#10-setlist-play--the-setlistplayer-sequencer-burnt-or-stream)):
the view's `onAppear` fires the autostart **exactly once** (a `didAutostart` one-shot guard
+ a no-duplicate-push guard so a second ▶ doesn't stack the view), and an
`onChange(nowPlayingRevision)` **re-snapshots** the freshly-upserted set and restarts when
the same screen is already open (the Shuffle-again-from-detail case). The user lands in the
normal setlist detail, so the same screen lets them **reorder / see what's next** — the
reusable set is a live, editable scratch surface, not a frozen artifact.

**The old realize-take Play moved.** Because ▶/🔀 now own "play it now," the prior Play
behaviour — `realize()` → a **frozen take** appended to history (§2, §5) — moved to its own
toolbar button (SF Symbol **`list.bullet.clipboard`**), so both flows coexist: ▶/🔀 for an
immediate literal play, `list.bullet.clipboard` for rolling a saved, autofilled take. (In
the Collections list, **your** editable playlists also now render **above** the read-only
"From your sources" index playlists, organized into the optional collapsible
folders of [Ch. 3 §3.1](./03-catalog-and-data-model.md#31-the-collectionsdocument-envelope-schema-versioning-and-folders-native).
A **`.searchable` name filter** (mirroring the Browser) sits atop the list: a non-empty query
does a case/diacritic-insensitive substring match over the names of `collections.playlists`,
`collections.pockets`, and `app.indexPlaylists`, and **flattens the folder hierarchy** into
three result sections — a pure client-side view filter over the already-loaded stores, no new
state or persistence.)

---

## 7. The Mix engine — the two-deck DJ board (native)

**Why.** Realizing a set (§2) and playing it in order (§6, Ch. 5 §10) is the *playlist*
half of the goal; the **Mix tab** is the *mix* half — where the DJ actually blends two
tracks live: beat-matched, crossfaded, EQ'd, effected. The native app ships a
**first-party, cross-platform two-deck DJ engine** — one `AVAudioEngine` graph, no
third-party/licensed audio SDK — that plays **only locally-burned files** (Ch. 5 §9),
so a mix runs **fully offline** at the venue.

**Source of truth:**
[`apple/PocketDJ/Mix/MixEngine.swift`](../../apple/PocketDJ/Mix/MixEngine.swift)
(the engine + DSP graph + transport/tempo/pitch/seek/sync/auto-mix/stems),
[`apple/PocketDJ/Mix/MixResolver.swift`](../../apple/PocketDJ/Mix/MixResolver.swift)
(resolves a `MixSource` pocket/setlist → loadable songs, **keeping only those whose
burned file exists on disk**),
[`apple/PocketDJ/Mix/MixView.swift`](../../apple/PocketDJ/Mix/MixView.swift) (the deck
UI, transport, effect chips, stem grid, loader sheet),
[`apple/PocketDJ/Mix/MixWaveform.swift`](../../apple/PocketDJ/Mix/MixWaveform.swift)
(off-main waveform peak extraction). Design rationale:
[`docs/design/mix-ondevice-tempo-pitch-beatmatch-spec.md`](../design/mix-ondevice-tempo-pitch-beatmatch-spec.md)
(written as "research"; the shipped code has moved past it — where they disagree, the
code's `connectChain()` wins).

**Deck layout is a view-only concern.** `MixView` arranges the two decks three ways in
portrait, chosen from **Settings ▸ Mix ▸ Deck layout** (`MixDeckLayout`: `sideBySide` /
`stacked` (default) / `single`). `single` shows one deck at a time behind **‹ ›** switchers
with `A · B` page dots; because the engine is **app-scoped** (below), the deck whose view is
unmounted **keeps rendering audio** — only its SwiftUI subtree is torn down, never its
`AVAudioPlayerNode`. The setting governs portrait only: iPhone landscape (compact height) and
macOS always render side-by-side, so the picker is hidden there. Nothing about the DSP graph,
transport, or `MixResolver` changes with layout.

### 7.1 The per-deck DSP graph

```
 Deck A · Deck B  — built identically by connectChain() on ONE shared AVAudioEngine:
   AVAudioPlayerNode
     → AVAudioMixerNode  (inputMixer)        ← ONLY link reconnected per load (file's real fmt)
     → AVAudioUnitTimePitch                  ← TEMPO (.rate)  +  PITCH (.pitch)
     → AVAudioUnitEffect(DynamicsProcessor)  "comp"   (compressor)
     → AVAudioUnitEQ(1 band)                 "filter"
     → AVAudioUnitReverb (.mediumHall)
     → AVAudioUnitDelay                      "flanger"
     → engine.mainMixerNode → output
   everything downstream of inputMixer is PINNED for life at canonicalFormat
   (44.1 kHz / 2ch) so a live AU channel/SR reconfig can't assert-crash AVAudioEngine
   — only player→inputMixer is re-linked per load to carry the file's real mono/stereo+SR
```

**Reading it.** Two decks share one `AVAudioEngine` (lazy `ensureEngine()`, soft-fails
silently with no audio device). Each deck is a fixed chain: an `AVAudioPlayerNode` feeds
an `inputMixer` (a format-normalizing `AVAudioMixerNode`), then a single
`AVAudioUnitTimePitch` (tempo **and** pitch), then the four effect nodes, into the engine
main mixer. The `inputMixer` exists so that only the `player → inputMixer` link is
reconnected per load (carrying the loaded file's real channel count / sample rate); the
rest is **pinned at `canonicalFormat`** forever, which is what stops a live AU
reconfiguration from crashing the graph.

### 7.2 Tempo · pitch · seek

- **Tempo** — `rateRange = 0.5…2.0×` (1.0 = original), a **pitch-preserved time-stretch**
  on `AVAudioUnitTimePitch.rate`. The ~10 Hz playhead advances source position at
  `rate × wall-time`.
- **Pitch** — `pitchRange = −12…+12` semitones (0 = original), **tempo-preserved**, written
  as `timePitch.pitch = semitones × 100` (the AU takes **cents**).
- **Seek** — sample-accurate via `player.scheduleSegment(file, startingFrame:…)`, **bounded
  to the song's `[startFrames, endFrames)` window** so an analog shared-album slice (one mp3,
  a `startMs` offset) can never scrub past its own track. The same `scheduleSegment`
  primitive underpins load, restart, and stem re-cue.
- **Reset (↺) vs Clear** — `resetDeck(_:)` (a **tap** on ↺) returns every per-deck parameter to
  default (tempo 1.0×, pitch 0, volume 100%, all effects off @ 0.5) then rewinds, **keeping** the
  loaded track. `clearDeck(_:)` (a **long-press / right-click** on ↺, via `.contextMenu` →
  "Clear deck (eject track)") is a superset: it also **ejects the track** — stops the voices,
  releases the file + stem security scopes, clears the frame window, gives up the **lead role** and
  **cue**, and resets the whole `DeckState()` to the empty zero state. Both log **one** `.resetDeck`
  session event (a clear is a reset that also ejects).

### 7.3 Crossfader + the four effects

- **Crossfader** — `0…1`, **0 = full A · 1 = full B · default 0.5** (both audible). An
  **equal-power cosine** law (`deckGain`): A's factor = `cos(π/2 · v)`, B's = `cos(π/2 ·
  (1−v))`. A separate per-deck **Vol** trim (`0…1`) multiplies on top; both land on the
  players (and, in stem mode, the stem nodes) via `applyMixGains`/`applyStemGains`.
- **Four effects** (`Effect{ compressor, reverb, flanger, filter }`) — each an enabled flag
  plus a per-deck per-effect continuous **strength** `s ∈ 0…1` (default 0.5); disabled ⇒
  `node.bypass`. **compressor** (DynamicsProcessor): threshold `−30·s` dB, makeup `+15·s`
  dB. **reverb** (`.mediumHall`): `wetDryMix = s·100`. **flanger** (Delay comb approximation —
  a true LFO flanger is noted future work): 4 ms delay, feedback `s·60%`, wet `s·50%`.
  **filter** (EQ `.resonantLowPass`): cutoff swept log-down `18 kHz → 250 Hz` as `s` rises.

### 7.4 Beat-matching — Sync to a lead deck

```
 leadDeck : Deck?   (EXCLUSIVE; setLead toggles/clears; a deck's own load clears its lead role)
 follower Sync = syncToLead(follower):
   matchBPM(loaded): PREFER measured grid BPM loaded.gridBpm (>0) ELSE catalog loaded.bpm
       gridBpm / firstDownbeatMs / steady ← burns.beatGrid(forSong:) at load (Ch.3 §4.3)
   (1) TEMPO   rate = octaveFolded( leadBPM·leadRate / followerBPM )   clamp 0.5…2.0
              octaveFolded: ÷2 while >2, ×2 while <0.5  (half/double-time aware)
   (2) PHASE   phaseAlign (best-effort, both playing): nudge follower ≤ ±½ beat via seek,
              referencing each song's firstDownbeatMs (0 if no grid)
```

**Reading it.** One deck can be the **lead** (exclusive `leadDeck`); the *follower's*
**Sync** matches it. The match is two steps: a **tempo** match sets the follower's rate so
its effective BPM equals the lead's **effective** BPM (`leadBPM × leadRate`),
**octave-folded** into the `0.5…2.0` window (so a 140 ↔ 70 half-time pairing matches at
1×, not by doubling), then a **best-effort downbeat phase-align** nudges the follower up to
±½ beat with a `seek`. Crucially the BPM source **prefers the measured beat-grid BPM**
(`gridBpm`, computed by the beat-grid indexer on the **exact burned file** — Ch. 3 §4.3,
Ch. 5 §15) over the looser catalog `bpm`, and uses the grid's `firstDownbeatMs` as the
phase reference — so Sync rides the real measured grid, not an estimate.

### 7.5 Auto-Mix — the timed auto-DJ

`startAutoMix(items, shuffled, lead ≈ 15 s, fade ≈ 3 s)` runs both decks as a hands-free
auto-DJ via a **wall-clock state machine** (stepped from the same ~10 Hz tick, independent
of the audio backend). It loads `item[0] → A`, `item[1] → B`, crossfader **full-A**, and
plays A; when the live deck's `secondsLeft ≤ lead` and a next track exists it
**`beginAutoCrossfade`** — a timed crossfade (`p = elapsed / fade` → `setCrossfader` sweep,
which moves the equal-power **volumes** together) — then **`finishAutoCrossfade`** snaps the
fader to the target, **silences** the outgoing deck, advances, and loads the next queued
track onto the freed deck. It loops across both decks until the queue ends; a manual
pause ends the loop. (`autoStatus` shows "n / total · Deck X | fading".) When a **glide**
feature is armed (§7.11) the transition grows an optional **pre-roll** and **post-roll**
around this same crossfade; with none armed neither fires, so the plain path is unchanged.

**Pause / Resume — step away, hand-mix, hand it back.** A running auto-DJ can be **paused**
without stopping it: `pauseAuto()` sets an observable `autoPaused` flag that gates **only** the
transition-trigger (the `autoFire` idle branch) — playback and any in-flight **recording** keep
running, and a per-deck manual pause during the interlude no longer ends the mix (`pause`/`pauseBoth`
now gate their `endAutoLoop()` on `!autoPaused`), so you can take the decks over by hand. `resumeAuto()`
re-arms the machine against the **current live playback** rather than a stale wall-clock, so the next
transition lands musically:

```
 resumeAuto():
   ONE deck playing   → autoDeckEndsAt[live] = now + (duration−position); the idle branch then waits
                        for the crossfade window, loads the next UNPLAYED track onto the free deck, fades.
   BOTH decks playing → survivor = the LATER-ending deck (stays live); autoResumeEndDeck = the other.
                        The idle tick WATCHES autoResumeEndDeck; the instant it ends → beginResumeHandoff:
                        load the next unplayed track onto that freed deck + glide/crossfade the survivor over.
   NEITHER playing    → (re)start the live deck (its track, or the next unplayed) before arming.
   "next unplayed" = first autoQueue item whose songId isn't in the session played-set
                     (recorder.hasPlayed — so a track hand-played during the interlude isn't repeated).
```

Both edges are logged as bare `.autoPause` / `.autoResume` timeline markers (§7.8), delimiting the manual
interlude in the corpus. `autoStatus` reads "n / total · paused — hand-mixing" while paused.

**Auto-mode source lock.** With Auto mode enabled and a collection chosen, both decks' **load source**
(the per-deck track browser, `sourceA`/`sourceB` in `MixView`) is pinned to the auto-mix collection —
`syncDeckSourcesToAuto()` fires on a collection change, on flipping Auto on, and at Play — so hand-loading
more tracks during a Pause needs no per-deck source picking. A later manual per-deck source change is left
as-is.

### 7.6 Stem decks — mix the parts, not just the track

```
 Stems toggle (only for a SERVER-stemmed track: rips.isStemmed(songId)) →
   burns.burnStems(forSong:) first if not local (Ch.5 §15) → setStemMode(on:) → wireStems:
     resolve burns.localStemURLs(forSong:)  (REQUIRES all 4: vocals/drums/bass/other)
     4 extra AVAudioPlayerNodes per deck  →  the SAME inputMixer
        (so the stems ride the deck's identical tempo/pitch/effects/crossfader chain)
     startStems: schedule + start all 4 at ONE shared host time → sample-accurate sync
   per-stem MUTE (stemMuted) + per-stem VOLUME (stemVol 0…1):
     applyStemGains → node.volume = muted ? 0 : deckGain(deck) · stemVol
```

**Reading it.** A deck can switch a stemmed track into **stem mode**: its four stem nodes
(`vocals/drums/bass/other`) sum into the **same `inputMixer`**, so they pass through the
deck's tempo, pitch, effects, **and** crossfader untouched — the deck behaves identically,
it just sources four parts instead of one file. `wireStems` requires **all four** local
stem files (else it stays off), and `startStems` launches them at a single shared
`AVAudioTime` for sample-accurate alignment. Each stem has an instant, glitch-free
**mute** and a continuous **volume** (applied as the node's gain). Stem decks are
**offline-only**: the parts must be **burned locally** (no streaming), so the **"Stems"
toggle only appears for a track the server has stemmed** (`rips.isStemmed`), and tapping it
burns the four stems to the device first. The on-disk stem store + server stemmer are
[Ch. 5 §15](./05-playback-and-rip-on-demand.md#15-stems-end-to-end--server-stemify-offline-stem-store-and-stem-audition).

### 7.7 First-party + cross-platform

The DSP graph carries **no `#if os` forks** (only `AVAudioSession` activation +
interruption recovery is iOS-gated); the engine is **app-scoped** (`@MainActor
@Observable`, injected into the environment) so deck state survives tab switches, and it
owns the `BurnStore`, resolving **only** locally-burned files. The design's premise was to
replace a vendored, licensed Switchboard SDK with a **license-free, sandbox-friendly
first-party `AVFoundation` graph** — which is what shipped.

### 7.8 Sessions, fine-adjust steppers & gain boost

```
 every Mix slider:  [−] slider [+]   (StepButton; fine step per control)
 deck volume 0…2.0: player/stems = min(v,1)·crossfade   +   filter-EQ globalGain = 20·log10(max(v,1)) dB
                    + master PeakLimiter (mainMixer → limiter → output)
 MixEngine.recorder (weak MixSessionRecorder = MixSessionStore):
   every setter → rec(kind, deck, …);  setPlaying() funnel → .play(+notePlayed)/.pause on transition
 MixSessionStore (@Observable, persisted JSON):
   hot buffer (@ObservationIgnored) → coalesce continuous to ≤1/120ms → debounced+off-main versioned write
   reset(X) finalizes + starts "Session N+1";  played-set → loader ✓ / auto-hide
 MixSessionsView:  list → replay timeline, wall-clock replay clock. WRAPPED (not an infinite right-scroll):
   verticalTimeline on iPhone; wrappedTimeline elsewhere — perRow 5 (macOS) / 3 (iPad), arrow.right along a
   row then arrow.turn.down.left to the next → the left-to-right-then-down order is explicit. A .glide event
   renders as ONE compact "from → to" node (not a tick burst); tap a .load node → SongMetadataItem sheet.
```

**Reading it.** Three additions sit on top of the engine above. **Steppers** give finer-than-drag
control on every slider. **Gain** now reaches **200%**: the 0…1 part stays on the source nodes'
documented `volume`, the >unity boost rides the deck filter EQ's `globalGain` (so it lifts the main
file *and* all four stems), and a **master peak limiter** guards the output. **Mix sessions** record
every deck action — load/play/pause/seek/tempo/pitch/volume/crossfader/effects/stems/lead/sync/reset —
into a time-stamped, persisted, replayable log that lasts until **Reset**, with played-track
checkmarks/auto-hide in the loader and a Sessions screen that replays the timeline in real time. That
timeline **wraps to the screen** rather than scrolling forever right (5 nodes/row on macOS, 3 on iPad,
with `→` / `↵` arrows making the reading order explicit), collapses an auto-mix **glide into a single
compact `from → to` node** (§7.11) instead of a burst of ticks, and lets you **tap a `.load` node to pop
its song-metadata card** — so a set is legible move-by-move. The
recorder is a weak seam on the engine; the store keeps the high-frequency event buffer **off** the
observed surface so a live mix never redraws the UI, coalesces continuous gestures, and persists
off-main. The corpus is designed to later **train an auto-mix model** (replay is visual for now;
re-driving the decks is the follow-up). Full spec:
[Mix sessions, steppers & gain](../design/mix-sessions-and-controls-spec.md).

### 7.9 Lock-screen transport & Now Playing arbitration — remote control · Auto-Mix Skip · seek & stem-mode

```
 MixEngine.nowPlayingDeck:  exactly one deck PLAYING → that deck; ambiguous (zero/both) → STICKY on the
   last unambiguous subject (lastNowPlayingDeck; batch transport + loadFile keep it honest); cold → A, else B
   updateSystemNowPlaying() → MPNowPlayingInfoCenter (title/artist/dur/elapsed/rate=tempo + ARTWORK) per edge
   refreshArtworkIfNeeded(songId): fetch gated on song-id CHANGE (card writes tick ~10 Hz); stale-token guard;
     resolver = shared artworkURLsProvider (AppModel.album(forSongId:).artCandidates — wired in PocketDJApp)
 NowPlayingArbiter (single owner, last-to-PLAY wins): PlayerEngine ⇄ MixEngine share the one card +
   one MPRemoteCommandCenter; every write / command guarded by isActive(self) → no stomping
 REMOTE transport (lock screen / AirPods / CarPlay) — its own entry points; in-app buttons unchanged:
   remotePause(): pauseAuto() first (RUNNING auto-mix → SUSPENDED, never ended) + FREEZE the machine's
     wall clock (remotePausedAt gates autoFire — a silent pre-roll/fade must never complete and audibly
     un-pause the phone) + pauseBoth() (masterPausedDecks = exactly what it silenced). Duplicate-pause safe.
   remotePlay(): unfreeze (shift armed timestamps by the frozen interval — a half-swept fade resumes where
     it stopped) + resumeMasterPaused() (ONLY the silenced decks) + resumeAuto() iff the matching remote ⏸
     suspended it (intent flag; ANY resume consumes it — a stray Siri play can't resurrect an in-app pause)
   remoteSkip(fade): suspended → resume-on-next-track (unfreeze+resume+resumeAuto), then skipToNext
   ⏭ = 5 s fast skip (in-app double-tap parity) · ⏮ = settings.skipFadeSeconds slow (single-tap parity)
   isEnabled follows autoMixing (re-asserted per card write; disable gated on ownership); PlayerEngine
     re-asserts its setlist ⏭/⏮ (onNext != nil) on every claim → the engines can't strand each other
 skipToNext(fadeSeconds): reuse beginAutoCrossfade; pendingFadeRestore puts the auto fade back after a one-off skip
   Skip button (Auto only): single = settings.skipFadeSeconds (def 15) · double = 5 s  (two .onTapGesture(count:))
 DeckSeekSlider: ALWAYS read engine.position(deck) (never `scrub ?? pos`) + explicit `editing` flag → no freeze
 setStemMode(on): schedule BEFORE muting main, bail if 0 frames (clamp to maxStemSeconds) → never silent
```

**Reading it.** The Mix feeds the **iOS/macOS lock-screen Now Playing** card — including the
now-playing deck's **album art** (the same resolver ladder the in-app `CoverImage` uses, fetched once
per track) — arbitrated against the standalone `PlayerEngine` by a tiny single-owner
`NowPlayingArbiter` so the two never fight over the one system card / command center. The card's deck
is **sticky**: pausing deck B keeps the card (title + art) on deck B instead of snapping to deck A,
through batch pause/resume and mid-blend track loads alike. The **remote transport maps to mix-native
concepts** without changing any in-app button: ⏸ *suspends* a running Auto-DJ (`pauseAuto` — session
and queue stay alive, and the machine's wall clock is frozen so an in-flight glide/fade can't complete
into silent decks), ▶ resumes exactly the deck(s) that pause silenced and un-suspends the Auto-DJ, and
⏭/⏮ are the fast (5 s) and slow (Settings skip-fade) queue skips — pressed while suspended they mean
"resume on the next track". When a **pocket / playlist / setlist** plays via the standalone player
instead, the same physical buttons keep their collection semantics (⏮ previous · ⏭ next · play/pause
the current track): the arbiter routes commands to whichever engine is audible and each engine
re-asserts its own ⏭/⏮ enablement when it reclaims the card. An Auto-Mix **Skip** button advances the
queue immediately (single tap = a configurable fade, double tap = a fast 5 s sweep) by reusing the
timed crossfade machine. A long-standing **slider freeze** (the seek scrubber stopped following
playback until you switched tabs) is fixed by never short-circuiting the observed `position` read. And
toggling **stem mode** after interrupting an auto-mix no longer goes silent — the ON path schedules
the stems before muting the main file and bails if nothing scheduled.
Full spec: [Lock-screen Now Playing, Skip, slider & stem fixes](../design/mix-tab-nowplaying-skip-slider-stems.md).

### 7.10 Cue / PFL · beat-grid BPM · beat pulse

```
 Channel-strip split (standard DJ signal flow): after the FX chain, each deck FANS OUT —
   flanger[d] ─┬─→ mainGains[d] (AVAudioMixerNode)  outputVolume = min(vol,1) × crossfadeFactor  ──→ houseSum ─→ housePan ─→ mainMixerNode
               └─→ cueGains[d]  (AVAudioMixerNode)  outputVolume = cued ? cueVol : 0  (PRE-FADER) ─────────────────────────→ mainMixerNode
   houseSum (shared AVAudioMixerNode) = the CLEAN stereo HOUSE sum (both decks' mainGains merge here,
     NO cue pan) = the RECORDING tap point (§7.12). The cue-side hard pan lives on housePan, DOWNSTREAM of
     the tap, so a capture stays clean stereo house even while a deck is cued.
   player now runs at UNITY (volume/crossfade moved downstream); >unity boost stays on the EQ globalGain;
   stems merge at inputMixer (upstream) so they ride BOTH sends for free.
   anyCued ⇒ housePan pans to the house side, cueGains to the cue side (CueChannel, default right);
   nothing cued ⇒ both centered → bit-identical normal stereo. masterLimiter still guards the sum.
 Cue button (left of Reset): tap = toggleCue · long-press/right-click = cue-VOLUME popover (independent level)
   CueChannel (which side is cue) lives in Settings → pushed via engine.setCueOnRight()
 Beat-grid BPM on the deck: gridBpm (measured, the value Sync uses) ?? catalog bpm, beside the KeyChip
 BeatPulseView (opt-in, Settings ▸ Mix, default OFF): 60fps TimelineView phase-locked to truePlayhead
   (player.playerTime + segmentStartSeconds, NOT the 10 Hz accumulator) → flash on each beat (downbeats brighter).
   Real grid `beatsMs[]` when burned (tempo-drift accurate); else synth from gridBpm + firstDownbeatMs.
 Beat grid = burnable artifact (mirrors stems): analysis-<id>.json sidecar; burnCollectionBeatgrids on burn
   (idempotent · STOP-aware · best-effort · validate-before-cache); dynamic hydrate on load GATED on the pulse setting
 Per-deck VU meter (above the Vol slider, below the FX grid): TWO install-once taps per deck (like the recording tap,
   never toggled at runtime) — PRE-fader on flanger[d] (post-FX, pre Vol/crossfade) + POST-fader on mainGains[d] (channel fader).
   peak + RMS + ballistics (peak-hold decay · RMS one-pole) computed ON the tap thread into a non-@Observable MixDeckLevels
   mirror (StudioMicLevels/MixTapPulse doctrine — fast writes must NOT invalidate SwiftUI), polled by a TimelineView.
   dB-scaled (−48…+3 dBFS) blue→gold→pink bar + peak-hold; meterSource (pre/post) is per-deck OBSERVABLE, toggled by a
   .contextMenu (long-press iOS / right-click macOS). Taps ride the media-reset rebuild (re-installed in ensureEngine onto fresh nodes).
```

**Reading it.** Cueing is a textbook **pre-fade listen (PFL)**: rather than a special case, each deck now
follows a conventional channel strip — its post-FX signal splits into a **channel-fader send** to the main
mix (`mainGains`, carrying the deck's Vol × crossfade) and a **pre-fader cue send** to the monitor bus
(`cueGains`, at an independent per-deck cue level). The cued deck therefore keeps playing to the house at
its fader level **and** is monitored at full on the cue channel — so you can pre-listen the next track
before bringing it in. With a stereo interface the two sends pan to opposite channels (house one side, cue
the other — chosen in Settings), and collapse back to centered stereo when nothing is cued. Each deck also
shows the **measured beat-grid BPM** (the value beat-matching actually uses) beside its key, and a **beat
pulse** ring that flashes on every beat — downbeats brighter — so you can feel the groove and eyeball-align
the two decks while mixing. Each deck also carries a **VU meter** above its Vol slider, fed by **two
install-once taps** — a **pre-fader** tap on `flanger[d]` (the post-FX signal, before Vol/crossfade) and a
**post-fader** tap on `mainGains[d]` (after the channel fader) — that compute peak + RMS with meter
ballistics **on the render thread** into a non-`@Observable` `MixDeckLevels` mirror (the same
`StudioMicLevels`/`MixTapPulse` discipline that keeps fast meter writes from invalidating SwiftUI), which
a `TimelineView` polls. A `.contextMenu` on the meter switches it between the two taps (pre for
gain-staging, post for the contributed-to-mix level). The taps are installed once in `ensureEngine` beside
the recording tap — never toggled at runtime (that would pause the decks on-device) — and are re-installed
onto fresh nodes after a media-services reset. Full spec:
[Cue/PFL, beat-grid BPM & beat pulse](../design/mix-tab-cue-beatgrid-pulse.md).

### 7.11 Auto-Mix glide — FX Glide + Mix Glide

```
 Two auto-mix pill toggles (default OFF): setFXGlide / setMixGlide. When either is armed a transition
 grows PRE-ROLL → CROSSFADE → POST-ROLL around the §7.5 crossfade (extra Date? phase timers layered on
 autoFadeStartedAt): autoPrerollStartedAt · autoFadeStartedAt · autoPostrollStartedAt. autoTransitionIsGlide
 is captured at the START, so toggling mid-transition can't corrupt a transition already underway; a
 snapshot GlideContext{from,to, fx…, mix…, saved effect state} drives it. Preroll length = mixGlideSeconds
 (Settings ▸ Mix, default 10 s; setMixGlideSeconds) fit into the runway. autoTransitioning gates Skip + re-timing.

 FX GLIDE — a COHERENT effect texture across a run of transitions:
   currentTexture(): reuse (effect, peak) for fxTextureRunRemaining (a run of 3…5), then re-roll via
     rollTexture(&fxGlidePrng) [splitmix64, seeded per-mix by fxSeed(from: queue) — deterministic, no wall-clock RNG]
   fxGlidePool = [.filter, .reverb, .flanger]   (compressor EXCLUDED — a dynamics tool, not a sweep)
   preroll  : effect ramps 0 → peak on the OUTGOING deck (before the volume sweep)
   crossfade: effect held at peak on BOTH decks
   postroll : effect ramps peak → 0 on the INCOMING deck, then RESTORE the deck's pre-glide effect state
     (saved in GlideContext — a load doesn't clear effects, so the outgoing deck is restored before reuse)

 MIX GLIDE — bend TOWARD each other, but ONLY on data each track actually has (NO default bend):
   glideParams(fromCamelot, toCamelot, fromBPM, toBPM):
     PITCH — only if BOTH Camelot keys known: signedCamelotSteps(a,b) [−6…+6, Camelot.parse Ch.3];
             each deck bends ≤1 key toward the other (meet in middle), 1 key = glidePitch ≈ ±1.65 st
     TEMPO — only if BOTH BPMs known: a real BEAT-MATCH. split = octaveFolded(ra/rb).squareRoot()  →
             inRate = split, outRate = 1/split  (SAME octave-fold Lead/Sync use, fed grid BPM via matchBPM),
             so the two effective tempos MEET; caller then glidePhaseAlign()s the downbeat on the grid
     neither datum for both tracks ⇒ IDENTITY (rate 1.0 / pitch 0) → just the §7.5 volume crossfade
   preroll  : OUTGOING rate/pitch ramp → target;  crossfade begin: INCOMING starts at the OPPOSITE offset
     + glidePhaseAlign (grid downbeat align, best-effort);  postroll: INCOMING eases → natural (1.0 / 0)

 RECORDED COMPACTLY, not per-tick: the ~10 Hz sweep runs through NON-recording appliers (setGlideRate/
   Pitch/Effect — mutate + push to the graph, no event) so it never floods the corpus, but each RAMP emits
   ONE .glide event via recGlide(param, from, to, span) [emitOutgoing/IncomingGlideEvents] carrying from→to
   + the AVERAGE rate of change. beginAutoCrossfade likewise logs the fader move as one .glide "crossfader".
```

**Reading it.** The two glide toggles decorate the **same crossfade machine** rather than replacing it:
a transition gains an optional **pre-roll** (ease the glide *in* on the outgoing deck, before the volume
sweep) and **post-roll** (ease it *back out* on the incoming deck, after), gated by a captured
`autoTransitionIsGlide` + a `GlideContext` snapshot so a mid-transition toggle can't corrupt work already in
flight — and when neither is armed, both durations are zero, so the plain §7.5 path is byte-for-byte
unchanged. The glide's length is `mixGlideSeconds` — a **Settings value (default 10 s)** so the bend can be
made as gradual as wanted. **FX Glide** keeps a **coherent texture**: one effect (from a sweep-only pool —
filter/reverb/flanger; the compressor is a dynamics tool, so it's out) held for a **deterministic run of 3–5
transitions** (seeded `splitmix64`, so a track set always textures the same way), ramped in on the outgoing
deck, held on both through the fade, then ramped off the incoming deck with the deck's prior effect state
**restored**. **Mix Glide** is deliberately **data-gated — it never invents a value it doesn't have**: it
bends **pitch** only when **both** tracks carry a Camelot key (each deck toward the other by ≤1 key, meeting
in the middle, then the incoming settles back), and bends **tempo** only when **both** carry a BPM — and that
tempo bend is a **true beat-match**, reusing the exact **octave-folded ratio the Lead/Sync buttons use**
(`octaveFolded`, fed the measured grid BPM), *split* between the decks so their effective tempos meet, with a
best-effort **grid downbeat align** (`glidePhaseAlign`). With neither datum present for both tracks the
result is **identity** — just the §7.5 volume crossfade, no bend. Crucially the automated sweep is **recorded
compactly**: the ~10 Hz per-tick moves go through **non-recording** appliers (so they never flood the log),
but every ramp — and the crossfade itself — emits **one `.glide` event** carrying `from → to` plus the
**average rate of change**, so the corpus captures each gesture as a single readable node instead of a burst
of ticks (see §7.8 for how that node renders + the [sessions spec](../design/mix-sessions-and-controls-spec.md) for the `.glide` event shape).

### 7.12 Session audio recording — capture the mix

```
 CAPTURE (MixEngine): startRecording(to:release:) / stopRecording(), observable isRecording.
   PERSISTENT tap: houseSum's tap is installed ONCE (in ensureEngine) and NEVER removed — start/stop only
     TOGGLE isRecording. Installing/removing a tap mid-playback reconfigures the live graph and can PAUSE
     the player nodes on-device, so the tap stays put + gating lives inside it (fixes stop→playback-stops).
   houseSum (§7.10 — the CLEAN stereo house, BEFORE the cue pan) → MixTapSink → FRAGMENTED AAC .m4a
   MixTapSink (@unchecked Sendable, AVAssetWriter): the realtime tap COPIES each PCM buffer → CMSampleBuffer
     (16-byte-aligned) then enqueues the write off the render thread → AAC encode never stalls audio.
   CRASH-SAFE: writer.movieFragmentInterval = 2 s → the file is flushed to disk ~every 2 s, so a kill /
     disk-full / power-loss mid-set leaves a PLAYABLE partial take (not a zero-byte header).
   release = the session-folder security scope, OWNED by startRecording (dropped on stop OR on any failure).

 COORDINATION (MixRecorder, @Observable, APP-SCOPED — survives leaving the Mix tab, like MixEngine):
   start(): resolve the CURRENT session's folder → mix-sessions/<sessionId>/recording-N.m4a → engine.startRecording
   stop():  engine.stopRecording() → sessions.addRecording(toSession: recSessionId, …)  [take captured at START,
            so a Reset mid-capture still files it]. If that session was DELETED mid-capture → recoverRecording
            revives the id (matches the on-disk folder) so the take isn't orphaned.
   recoverOrphans() [called on launch]: scan every session folder for .m4a files NOT in recordings[] (a
     crash files no metadata but the fragmented .m4a survives) → recoverRecording re-homes each to its
     session (reviving a deleted one). Idempotent — skips already-recorded files, so relaunch never dupes.

 SESSION FOLDER (SessionFolders — mirrors BurnStore.resolveBurnFolder):
   settings.sessionFolderBookmark (security-scoped, Settings ▸ Mix sessions) ELSE Application Support/mix-sessions/
   one subfolder per session; MixRecording.wasUserFolder records which, so playback resolves from the right root.

 MODEL: MixSession.recordings: [MixRecording]?  (OPTIONAL — schema v2, a v1 doc decodes unchanged)
        MixRecording{ id, fileName, startedAt, durationMs, wasUserFolder }
 UI: MixView RecordButton (toolbar, pulsing purple→red) + in-content "● Recording m:ss" (amber
     "Recording — no audio" while captureStalled); MixSessionsView recordingsPanel = per-take ▶/⏹ +
     RecordingScrubBar (seek). RecordingAudioPlayer (AVAudioPlayerDelegate: auto-reset on finish, no
     poll loop) resolves via SessionFolders + holds the scope; playback failure surfaces via lastError.
     ShazamButton is DISABLED while isRecording (its mic session would fight the capture's).

 FAILURE HANDLING (the bulletproofing layer — every way the take or the engine can die, closed):
   ENGINE DEATH (route change / config change / interruption): the system stops AVAudioEngine out from
     under the app; driving AVAudioPlayerNode.play() into it is an UNCATCHABLE ObjC exception. Every
     play-after-start site goes through startEngineIfNeeded() -> Bool; observers for
     .AVAudioEngineConfigurationChange (re-registered PER engine instance) + routeChangeNotification (iOS)
     call recoverFromEngineStop(), and the ~10 Hz tick doubles as a WATCHDOG (retries ~1/s).
   CLOCK PARKING: engineStallAt freezes the auto-machine clocks while the engine is down (mirrors
     remotePausedAt); unparkEngineStall() shifts them by the stall on recovery; checkpointEngineStall()
     re-bases before a mid-stall re-stamp (seek, resumeAuto); remotePause() FOLDS an in-progress stall
     into the freeze — an overlap is never counted twice.
   PARK POLICY: a deliberate park (lock-screen ⏸ / interruption .began -> remotePause) stays SILENT —
     restarting the engine there would append dead air into the open take — EXCEPT a deck the user
     hand-started during the park (autoPaused hand-mixing), which keeps full recovery. Interruption
     .ended resumes ONLY what .began parked (interruptionParked latch; any resume clears it) and honors
     shouldResume=false by staying parked. mediaServicesWereReset -> rebuildAfterMediaReset(): file the
     in-flight take FIRST, then recreate the engine + graph (decks come back loaded-but-paused).
   WRITER DEATH (disk full / folder vanished): MixTapSink latches `failed` (startWriting is NEVER retried —
     the second call raises ~93 ms later) and fires one-shot onWriterFailure -> MixRecorder auto-stops,
     FILES the partial take (fragments are durable), and MixView explains via writerFailureMessage.
     stopRecording defers the security-scope release until finishWriting COMPLETES.
   LIVENESS: appendedSeconds = the take's CONTENT clock (NSLock mirror of the sink's nextPTS, zeroed ON
     the sink queue); MixRecorder's 2 s watchdog flips captureStalled when media freezes >=5 s while the
     mix is audible; stop() files durationMs from the content clock (wall clock only as fallback).
   ORPHANS: recoverOrphans() runs at LAUNCH (RootView.task — any tab), per-ROOT scan latches retry an
     unresolvable user root, unreadable stubs are skipped (no phantom 0:00 rows), and the ACTIVE take is
     never adopted (root-aware identity — the same name can exist in both roots). The Storage sweep runs
     recovery FIRST so an unseen crash take becomes visible before anything destructive.
   EXIT + BOOKMARKS: RecordingExitBridge (macOS applicationShouldTerminate / iOS willTerminate) ->
     mixRecorder.stop() + mixSessions.flush() (the store's async actor save loses the race with exit).
     SessionFolders.onStaleBookmark re-mints a stale-but-resolving bookmark INSIDE the live scope and
     persists it immediately (settings.persist()).
   ZOMBIE NODES (the macOS AirPods case, root-caused from a field debug session): an engine stop
     across an output-format change (44.1↔48 kHz) brings AVAudioPlayerNodes back `isPlaying`=true,
     schedule intact, position advancing — RENDERING SILENCE; a bare play() no-ops on them.
     resumePlayingDecks() therefore RE-PRIMES (pause() then play(); stems pause + synced re-start),
     and an `engineDownWhileLive` latch re-primes on the next rendering tick after ANY engine-down
     window (the config-change observer sets it too — an auto-restart between ticks still reconfigured).
   DIAGNOSTICS (Settings ▸ Debug): MixEngine emits a `mixdiag` os_log stream — a 1 Hz heartbeat
     (engine running vs render-callback age vs SIGNAL age via the MixTapPulse tap mirrors, per-deck
     intent/node/position, output rate, rec/stall/park flags) + every recovery/transport event.
     MixDiag (@Observable, memory-only ring buffer) captures it as an explicit SESSION: toggle on →
     reproduce → toggle off → export (plain-text fileExporter) → ship back via iCloud. The zombie-node
     signature that cracked the AirPods bug: render=1 run=1 tapAge≈0, sigAge growing, A=(1,1,pos↑).
```

**Reading it.** Recording taps the **clean-house sum** (`houseSum`, §7.10) — *not* the final output — so
the take is the **audience's stereo mix even while you monitor a cue in the headphones**. Two hard-won
details shape the capture. First, the tap is **persistent**: it's installed **once** on `houseSum` and
start/stop merely flip an `isRecording` flag inside it — because *installing or removing* a tap on a node in
the live render path mid-playback reconfigures the graph and **paused the decks on-device**, so the tap
stays put rather than being added/removed per take. Second, the writer is **crash-safe**: `MixTapSink` is an
`AVAssetWriter` encoding **fragmented AAC** with a **2 s `movieFragmentInterval`**, so the `.m4a` is flushed
to disk continuously — a kill, a full disk, or a dead battery mid-set leaves a **playable partial file**, not
a corrupt header. The realtime tap can't block on encoding, so it **copies each buffer into a
`CMSampleBuffer` and writes off-thread**. The engine only captures to a URL; an **app-scoped `MixRecorder`**
bridges that to the app graph — resolving the current session's **folder** (`SessionFolders`, the same
app-storage-or-user-picked pattern as the burnt-music folder), driving start/stop, and filing the finished
take into `MixSession.recordings` (an **optional** field, so older documents decode untouched). Because the
recorder is app-scoped, a capture keeps running when you leave the Mix tab; because the take is bound to the
session it *began* in, a Reset — or even a delete — mid-capture still files it. And on the **next launch**,
`recoverOrphans()` sweeps the session folders and **re-homes any `.m4a` a crash left behind** (metadata is
written only on a clean stop, but the fragmented file is already valid), reviving a deleted session if
needed — idempotently, so relaunching never duplicates a take. Back on the **Sessions** screen, each take
gets a **▶/⏹ control and a scrub bar** (`RecordingScrubBar`; `RecordingAudioPlayer` uses
`AVAudioPlayerDelegate` to auto-reset at end-of-file, replacing an earlier poll loop that could stop
playback on a transient state flip), so a session now replays both its **actions** (§7.8) and its **audio**.

**Bulletproofing it.** The fragmented writer only guarantees the *file*; the FAILURE-HANDLING block above
is what guarantees the *take*. The founding bug: unplugging headphones mid-recorded-Auto-Mix **stopped the
engine out from under the app**, nothing observed it, and the wall-clock auto-DJ machine drove
`AVAudioPlayerNode.play()` into the dead engine — an **uncatchable** ObjC exception, while the capture had
already frozen silently. The fix is layered. Every transport path now goes through a **guarded
`startEngineIfNeeded()`**; **route/config-change observers** plus a **tick watchdog** restart a
system-stopped engine (~1 try/s), while **`engineStallAt` parks the auto-machine clocks** so a stall never
burns a track's runway — with careful bookkeeping (`remotePause` *folds* an in-progress stall into its
freeze; `checkpointEngineStall` re-bases mid-stall re-stamps) so overlapping parks never double-shift a
transition. A **deliberate** park (lock-screen ⏸, phone call) deliberately stays silent — restarting the
engine there would append **dead air into the open take** — except for a deck the user **hand-started**
during the park, which keeps full recovery; the interruption pairing (`interruptionParked`) makes `.ended`
resume **only what `.began` parked**. Independently of the engine, the **writer** can die (disk full,
folder vanished): the sink **latches the failure** (a retried `startWriting` traps ~93 ms later), fires a
one-shot callback, and the recorder **auto-stops and files the partial take** with an alert — while a
**content clock** (`appendedSeconds`) + a 2 s **liveness watchdog** turn any silent capture freeze into a
visible amber **"Recording — no audio"** instead of a dead take behind a pulsing record button. Orderly
exits file the take **and synchronously flush** the session store (`RecordingExitBridge`), and the orphan
scan is hardened to run at launch from **any** tab, retry a user root that failed to resolve, skip
unreadable stubs, and never adopt the **in-flight** take (root-aware, so a same-named crash orphan in the
*other* root is still recovered).

### 7.13 Durable mix-deck sessions — the decks survive a force-quit (`MixDeckSessionStore`)

**Why.** Everything above — the loaded decks, the mixer, the Auto-DJ queue with its jukebox
inserts — was purely in-memory: a force-quit or a phone restart lost the whole board. Phase 2
of durable playback sessions (phase 1 is the sequencer's, Ch. 5 §10.2) applies the same
doctrine to the Mix engine: persist **in real time as state changes** (never at exit),
rehydrate at launch **held** — audio never auto-plays.

**Source of truth:**
[`apple/PocketDJ/State/MixDeckSessionStore.swift`](../../apple/PocketDJ/State/MixDeckSessionStore.swift)
(the store) + the "Durable mix-deck session" section of
[`apple/PocketDJ/Mix/MixEngine.swift`](../../apple/PocketDJ/Mix/MixEngine.swift).

- **The snapshot** — ONE overwrite-in-place file, Application Support
  `pocketdj-mix-decks.json` (~KBs): `{ schemaVersion, deckA?, deckB?, crossfader, leadDeck?,
  auto?, wasRunning, updatedAt }`. Each deck: `{ track { songId, title, artist, bpm, camelot,
  key, albumId, lengthMs }, positionMs, volume, rate, pitch, 4× effect on/off + strength,
  stemMode, stemMuted, stemVol }` — the track ref is exactly `MixEngine.load(songId:…)`'s
  inputs (≙ `MixLoadable`), so a restore re-loads through the SAME path a user tap does
  (BurnStore cut/analog resolution, the studio-item seam, grid hydration). `auto` is the
  Auto-DJ machine: the queue in FINAL order (shuffle already applied; jukebox
  `autoQueueInsert`s included), `livePos` / `nextToLoad` / `liveDeck`, `sourceLabel`,
  lead/fade seconds, and the two glide flags. Writes ride the same off-main
  versioned-watermark actor pattern as phase 1 (`MixDeckSessionWriter`) — a stale async write
  can never clobber a newer one, including `clear()`'s delete.
- **Deliberately NOT persisted:** recording state (`MixRecorder` §7.12 has its own
  fragmented-file crash-orphan recovery); cue/PFL routing + cue volumes (transient monitoring
  state — rehydrating a hard-panned house/cue split after a reboot would be a surprise); VU
  meters / `truePlayhead` / render taps (runtime derivations); beat grids + cue points
  (derivable — the burned `analysis-<id>.json` sidecars and the studio store re-hydrate them
  through the normal load path); and **in-flight transition state** (pre-roll/fade/post-roll
  wall clocks, `GlideContext`) — a kill mid-crossfade restores in the suspended idle state and
  the existing Resume re-arms against live playback.
- **Write triggers** (`persistMixDeckSession` in MixEngine): IMMEDIATE on structural changes —
  `loadFile` (every deck load: manual, auto-DJ, studio item), `clearDeck`, `resetDeck`,
  `setStemMode`, `toggleStemMute`, `setEffect`, `setLead`, `startAutoMix`, `endAutoLoop`,
  `finishAutoCrossfade` (auto or Skip — the cursor moved), `autoQueueInsert` (a guest request
  survives), `pauseAuto`/`resumeAuto`. DEBOUNCED (~1 s trailing edge — a drag's final value
  always lands, 60 Hz never hits disk) on the slider surfaces — `setVolume`, `setCrossfader`,
  `setRate`, `setPitch`, `setEffectStrength`, `setStemVolume`, `seek`. Playheads:
  `persistMixPositions` from the ~10 Hz tick + every `setPlaying` transition →
  `updatePosition(aMs:bMs:isRunning:)`, throttled ~5 s while running, immediate on a
  run/pause transition. Scene `.background` → `flush()` (synchronous, next to the other three
  flushes in `PocketDJApp`). CLEAR when the mix is genuinely over: both decks ejected with no
  auto queue (the snapshot builder returns nil → `clear()`), which `ejectAll()` — the Settings
  nuclear reset's hook — drives explicitly.
- **Restore — two phases (the lazy-materialize rule).** (1) RootView's launch task calls
  `restorePersistedMixIfIdle()`: lenient `load()` (decode failure / schema mismatch / empty →
  nil), then the snapshot is **parked** on the engine (`pendingMixRestore`) — NO audio, no
  graph build, no disk-in-init. Skipped when the engine is already in use (an intent-started
  mix won the race) and under `PDJ_DISABLE_SESSION_RESTORE`. (2) The Mix tab's `.task` calls
  `materializePendingRestoreIfNeeded()`: decks re-load through the normal `load` path and
  `seek` to their saved playheads (CUED, `play()` never called), plain-value controls
  re-apply, crossfader/lead restore, and the Auto-DJ machine rebuilds **SUSPENDED**
  (`autoMixing = true, autoPaused = true`, end-clocks unarmed — the silent-fades invariant: it
  must NOT self-resume; the banner's Resume / `resumeAuto` re-stamps the clocks from live
  positions). Because macOS lands on Mix, MixView's `.task` can run BEFORE the launch task —
  `materializeWanted` remembers the request and the launch task finishes the handoff.
  Materialization detaches the session-log `recorder` (a restore is not a user gesture — no
  phantom events in the replay corpus) and suppresses `updateSystemNowPlaying`
  (`isRestoringMixSession`): **no Now Playing card is claimed** — at cold launch the arbiter
  is unowned, so the loads/seeks would otherwise write a paused card for audio nobody
  started. Both the phase-1 setlist session AND a mix snapshot may restore held side by side;
  whichever the user plays first claims the card via the normal `NowPlayingArbiter` paths. A
  track whose file vanished (purged burn, deleted studio item) simply leaves THAT deck empty —
  restore what's loadable, drop what isn't (the post-materialize re-sync drops it from the
  file too), never crash or block. A real `loadFile`/intent action while a restore is still
  parked drops the pending snapshot (the new mix supersedes it).
- **Testing seams**: `PDJ_USE_FIXTURE` isolates the file (`launchURL()`),
  `PDJ_SEED_MIX_DECK_SESSION` writes a canned mid-mix snapshot built on the `PDJ_SEED_STUDIO`
  fixture items (whose audio actually exists, so the UI test exercises real materialization —
  `MixDeckRestoreUITests`), and `PDJ_DISABLE_SESSION_RESTORE` is shared with phase 1. Unit
  coverage: `MixDeckSessionStoreTests` + `MixEngineSessionTests`.

---

## 8. The Performance TAB (Studio) — distinct from the realize engine above

> **Disambiguation first — two different "Performance"s.** This chapter's title,
> **"Performance Engine,"** means the **realize pipeline** (§1–§6): pockets → playlists
> → setlists, the pure `realize(seed)` that freezes a template into a set. The **Studio**
> documented here is a *different* thing that happens to share the word: it is the
> user-facing **Producer tab** — a top-level tab, renamed from "Performance" in 2026-07:
> the visible `title` reads **Producer**, while the persisted token stays
> `RootView.Section.performance = "Performance"` forever
> ([`apple/PocketDJ/Views/RootView.swift`](../../apple/PocketDJ/Views/RootView.swift),
> SF Symbol `pianokeys`) — for **making your own material** across **six sub-tabs**
> (`StudioSubTab`, `PerformanceView.swift`): samples, loops, a 16-step sequencer,
> virtual instruments, per-track cue points, and the **Demuxer** (noted just below,
> before §8.1). The names collide everywhere
> (`PocketDJ/Performance/` is already the realize engine's directory; a type named
> `Performance` is taken by `RealizeEngine.swift`; `sequencer` already means the
> `SetlistPlayer`), so the feature ships under a deliberate **`Studio` prefix**:
> [`apple/PocketDJ/Studio/`](../../apple/PocketDJ/Studio/) for code, `Studio*` on every new
> type, `StudioPattern` for the 16-step sequence, `StudioTake` for an instrument recording.
> A maintainer who greps `Performance` will hit **both**; the split is `Performance/` =
> realize (this chapter §1–§6), `Studio/` = the tab (this §8). The full design record is
> [`docs/design/performance-studio-spec.md`](../design/performance-studio-spec.md) (rev 2);
> the product story is the storybook's [The Studio](../storybook/studio.md) chapter. This §8 is the systems view.
>
> **Native-only, like Mix.** The Studio reads the same catalog/rips/collections as the rest
> of the app but adds new device-local artifact classes (samples, loops, patterns, takes,
> instrument packs). The PWA has no Studio UI; where a studio id reaches a shared consumer
> the behaviour degrades gracefully (§8.6).

**The sixth sub-tab — Demuxer (brief).** Producer ▸ **Demuxer**
([`StudioDemuxView.swift`](../../apple/PocketDJ/Studio/Views/StudioDemuxView.swift) + the
`Demux*` panel views and the engines in
[`apple/PocketDJ/Studio/Demux/`](../../apple/PocketDJ/Studio/Demux/)) loads any audio — a
catalog track, a studio sample/loop/instrumental, or an imported file — and demuxes it into
time-synced metadata: an on-device dominant-**chord** timeline (`ChordDetector`, chromagram →
staff notation / guitar shapes), a **lyrics**/speech transcript of the burned **vocals stem**
(Apple Speech via `DemuxTranscriber`, fully on-device, with a user-triggered
**Generate / Retry / Resume lyrics** button for tracks with no words yet; cloud
faster-whisper words are used when the catalog already carries them), the four separated
**stems** with live mute/solo, a **drum-pattern** detector whose bars can be sent to the
16-step sequencer as a remix loop (`DrumPatternDetector`), **Cut Sample** (carve the loaded
audio straight into an `smp_` sample), and chord-comping / true-melody **instrumental
extraction** into the Instruments tab (`DemuxInstrumental`, `MelodyTracker`). Stem
*separation* itself stays server-only (Demucs — Ch. 5 §15); the demux analyses run on-device.

### 8.1 The data layer — `StudioStore`, `StudioFolders`, `StudioModels`

**Why.** Everything the Studio makes is a persisted, user-owned artifact that must survive
relaunch, ride the collections graph (§8.6), and — like burns and mix recordings (Ch. 5
§9, §9.2) — **never be dropped just because a drive is unplugged**. The Studio needs its
own versioned document, its own folder resolver, and one hard doctrine for reconciling
records against files.

**Source of truth:**
[`apple/PocketDJ/Studio/StudioModels.swift`](../../apple/PocketDJ/Studio/StudioModels.swift)
(`StudioSample`, `StudioLoop`, `StudioPattern`, `StudioTake`, `StudioCue`, `InstrumentKey`,
`StudioFactory`),
[`apple/PocketDJ/Studio/StudioStore.swift`](../../apple/PocketDJ/Studio/StudioStore.swift)
(the `@MainActor @Observable` document store + `reconcileOnLaunch`),
[`apple/PocketDJ/Studio/StudioFolders.swift`](../../apple/PocketDJ/Studio/StudioFolders.swift)
(`StudioFamily` + root resolution).

```
 pocketdj-studio.json  (Application Support, ONE versioned lenient document)
   { schemaVersion, samples[], loops[], patterns[], takes[], cues[], slices[], folders[], keys{} }
     (slices → §8.7 pads · folders → sample folders below · keys → the §8.8 Camelot map)
   off-main versioned writer · flush() · launchURL() PDJ_USE_FIXTURE seam   (MixSessionStore shape)
   ids minted by StudioFactory:  smp_ · lp_ · ptn_ · tk_  (+ uuid) = studioPrefixes (collection-riding);
     cue_ · slc_ · sfld_ are NON-riding (never inside a collection's id arrays)

 StudioFamily (StudioFolders.swift):  samples · loops · sequences · takes · instruments
   userRelocatable   samples/loops/sequences/takes → TRUE   instruments → FALSE (packs always app-managed)
   filePrefix        sample- · loop- · pattern- · take- · instrument-
   fileExtension     m4a (samples/patterns/takes) · caf (loops) · sf2 (instruments)
   idPrefix          smp_ · lp_ · ptn_ · tk_ · nil (packs embed a bank SLUG, not an id)

 reconcileOnLaunch()  (BurnStore.reconcileOnLaunch doctrine, BurnStore.swift:765):
   resolve every artifact against the ROOT IT WAS WRITTEN TO (wasUserFolder)
   file provably gone from a REACHABLE root → drop the record
   user root UNREACHABLE (unplugged / offline) → SKIP, never prune
   dangling cross-reference (loop→missing sample, pattern row→missing target) → FLAG, never delete
```

**Reading it.** The whole graph is one `pocketdj-studio.json` in Application Support,
persisted with the exact **`MixSessionStore` persistence shape** (Ch. 4 §7.8): a
`schemaVersion`, an off-main versioned writer, a synchronous `flush()` for orderly exit,
and a `launchURL()` fixture seam. Every artifact carries **`wasUserFolder`** and resolves
against the root it was *actually written to* — the same rule burns follow. The
load-bearing method is **`reconcileOnLaunch`**, ported verbatim from
**`BurnStore.reconcileOnLaunch` (`BurnStore.swift:765`)**: a record is dropped **only** when
its file is *provably* gone from a **reachable** root; when a user root is unreachable (an
unplugged samples drive, an offline provider) the reconcile **skips it — it never prunes**,
because dropping the record without deleting the file would orphan the file forever. Cross
-references between artifacts (a loop pointing at a deleted sample, a pattern row pointing at
a deleted target) are **flagged, never auto-deleted** — the UI shows a "source removed" note
and the artifact keeps playing from its own rendered file.

The core model types are **`StudioSample`** (`source: .track(songId,startMs,endMs) | .mic |
.take(takeId)`, a non-destructive `edit`, an optional beat `grid`), **`StudioLoop`** (a
beat-window slice with an **authoritative `frames: Int64`** count — see §8.2),
**`StudioPattern`** (rows of sample/loop targets, on-demand bounce + `bounceDirty`; **length is
per-pattern** — an additive-optional `stepCount` up to 365 (absent ⇒ 16, NO version bump), every
row `resized` to it on init/decode so a long pattern never truncates to 16 on load, with
`StudioEngine` + its step clock carrying a matching `patternStepCount` for the pass-index math and
highlight wrap — SEQ4; **live edits** mirror step/loop-mode changes into the running pattern via
`updateLiveStep`/`updateLiveStepLoop`, heard at the next bar, when the session's `pdj.sequencerLive`
toggle is on — SEQ2),
**`StudioTake`** (an instrument recording: quantize `bpm` + timestamped `events[]`), and
**`StudioCue`** (`{songId, slot 0–7, positionMs}`, **max 8 per songId, store-enforced** —
§8.5). Deleting a sample surfaces a confirmation listing the loops that "keep playing but
can't be re-sliced" and the pattern rows that "will be muted." The **"Use as sample" from a
take COPIES the audio file** — a sample never depends on the take file continuing to exist.
`StudioStoreTests` cover delete-with-referrers, cue-max-8, lenient decode, and
reconcile-with-an-unreachable-root; `StudioFoldersTests` cover family root resolution and the
strict-shape filename discipline. (Two later additions ride the same document: `StudioSlice`
performance pads — §8.7 — and the `keys` detected-Camelot map — §8.8.)

**Sample folders (F9).** Samples can be organized into flat, device-local **folders**:
**`StudioSampleFolder`** (`sfld_…` id + name + `createdAt`/`updatedAt`; membership is by
`StudioSample.folderId`, **one folder per sample**, nil ⇒ Unfiled, so a folder carries no
member list) lives as the document's top-level `folders` list with the same per-element lossy
decode. The Samples tab groups by folder — collapsible sections whose collapsed ids persist
across launches — with create / rename / delete dialogs (the `PlaylistsView` folder-dialog
precedent) and a per-sample **Move** submenu whose "New folder…" creates and files in one
step. A folder is **pure organizational metadata**: deleting one drops its members back to
Unfiled and never touches a sample record or audio file (the audio never moves on disk), and a
dangling `folderId` simply reads as Unfiled. The CRUD lives on `StudioStore`
(`createSampleFolder` / `renameSampleFolder` / `deleteSampleFolder` / `setSampleFolder`,
mirroring `CollectionsStore`'s playlist-folder shape). Not to be confused with
`StudioFolders.swift` — the *storage-family* root resolver below.

**Storage families.** `StudioFolders` generalizes `SessionFolders` (Ch. 4 §7.12): the
app-managed roots are `Application Support/studio/{samples,loops,sequences,takes,
instruments}/`. **Samples / loops / sequences / takes (instrumentals) are user-relocatable**
(via optional security-scoped bookmarks in `SettingsStore` — §8.1 storage lives with the storage manager
in [Ch. 5 §9.2](./05-playback-and-rip-on-demand.md#92-the-storage-manager--settings--storage-delete-tools--the-soft-cap-lrp-prune)).
**Only the instrument packs are always app-managed** — no bookmark, no ambiguity about which
root a 32 MB bank resolves against. Deterministic names (`sample-<id>.m4a`,
`loop-<id>.caf`, `pattern-<id>.m4a`, `take-<id>.m4a`, `instrument-<slug>.sf2`) plus the
`BurnStore.ownsAuxFile` discipline (filter by exact filename shape **and** a document-known
id) mean a co-located user file is never counted or swept.

### 8.2 The audio engines — `StudioEngine` (audition) + `StudioRender` (offline bounce)

**Why.** The Studio auditions samples/loops/patterns live *and* bakes them to standalone
files (for offline play, for loop-seam accuracy, for collection playback). Live audition and
offline rendering are **different disciplines** — a live graph normalizes formats and rides
AUs in real time; an offline bounce must write every frame with no dropped buffers — so they
are two engines, both inheriting the **`MixEngine` hardening contract** (Ch. 4 §7.1, §7.12):
`@MainActor @Observable`, app-scoped `@State` in `PocketDJApp.init`, `ensureEngine()` /
`startEngineIfNeeded()` before every `play()`, interruption/route-change/config-change
observers, the tick watchdog + zombie-node `pause()+play()` re-prime, and
`NowPlayingArbiter` claim/resign when audible.

**Source of truth:**
[`apple/PocketDJ/Studio/StudioEngine.swift`](../../apple/PocketDJ/Studio/StudioEngine.swift)
(sample/loop/pattern audition),
[`apple/PocketDJ/Studio/StudioRender.swift`](../../apple/PocketDJ/Studio/StudioRender.swift)
(the offline bounce), and the shared beat helpers in
[`apple/PocketDJ/Support/BeatMath.swift`](../../apple/PocketDJ/Support/BeatMath.swift).

```
 StudioEngine — ONE graph, three audition duties (canonical 44.1k/2ch pinned downstream):
   SAMPLE   player → inputMixer(normalizer) → timePitch → comp(dynamics) → EQ(globalGain+filter) → reverb → delay → mainMixer
            only player→inputMixer is reconnected per load at the file's processingFormat (player STOPPED)
            — studio files are heterogeneous (mic captures are hw-format, ~48 kHz mono) — MixEngine loadFile contract
            B6 MIXER DECK: StudioSampleEdit adds compWet (dynamics) + filterAmt (EQ band = resonant LPF) to gain/rate/pitch/wets
            — StudioAudio.applyEditToChain(...,comp:) is the ONE voicing both audition + StudioRender.makeOfflineChain apply
            LOOPER (ephemeral, SAMP-only): sampleLoopAudition → scheduleSampleWindow reads the trim window → scheduleBuffer(.loops);
              samplePlayheadSeconds wraps, checkSampleEndBoundary never stops; reset in unloadSample — never persisted, never baked
   LOOP     decode loop-<id>.caf fully → trim/pad decoded buffer to the AUTHORITATIVE `frames` → scheduleBuffer(.loops)
   PATTERN  each row's buffer is PRE-RENDERED with edits baked (StudioRender) → rowPlayer → rowGain → mainMixer
            scheduleBuffer(at:options:.interrupts)  = mono-choke step sequencer (a retrigger cuts the ringing hit)
            step = 60/bpm/4 s (16ths in 4/4) against a pattern-start AVAudioTime; 1-bar horizon re-armed each pass
            missing-target row → skipped (never a throw); zero sounding steps → refuse (a 0-frame schedule crashes)

 StudioRender — greenfield offline bounce: AVAudioEngine.enableManualRenderingMode(.offline)
   OUTPUT written with AVAudioFile(forWriting:settings:)  (BLOCKING writes — no backpressure, no dropped buffers)
     (the MixTapSink AVAssetWriter recipe is realtime-only — drops buffers when the encoder is busy — MUST NOT be used here)
   samples/bounces → AAC .m4a, length = ceil(sourceFrames/rate) + FX-TAIL drain (render until < −60 dBFS or a 3 s cap)
   loops          → LPCM CAF, EXACTLY the beat-window frame count (tails truncated → seams stay clean)
   timePitch/AU priming-latency HEAD trimmed so written frame 0 = musical frame 0 (else every baked loop starts silent)
```

**Reading it.** **`StudioEngine`** is one graph with a sample chain modelled on the Mix
deck (Ch. 4 §7.1): everything downstream of the format-normalizing **`inputMixer`** is wired
**once** at canonical 44.1 kHz stereo for life, and **only** the `player → inputMixer` link
is reconnected per load — with the player stopped — to carry the loaded file's real format.
That matters more here than in Mix because studio files are *guaranteed* heterogeneous: a mic
capture is at the hardware format, typically 48 kHz mono. Loop audition decodes the whole
`loop-<id>.caf`, trims/pads the decoded buffer to exactly the loop's **authoritative
`frames`**, and schedules it with `.loops`. Pattern playback is the classic **mono-choke step
sequencer**: each row's sounding buffer is **pre-rendered by `StudioRender` with its edits
already baked**, so the live path is a plain `rowPlayer → rowGain → mainMixer` with **no live
AU latency**, and a retrigger uses `.interrupts` so a new hit cuts the ringing one. Steps are
scheduled sample-accurately against a pattern-start `AVAudioTime` anchor, one bar of 16ths at
`60/bpm/4` s, re-armed a bar ahead each loop pass. A row whose target was deleted is **skipped**
(never a throw); a pattern with zero sounding steps **refuses** to play/bounce with an inline
notice, because a zero-frame schedule crashes `AVAudioPlayerNode`. (`StudioEngineMathTests`
cover the step-time math, the choke policy, and the missing-target skip.)

**The B6 mixer deck** (`StudioMixerDeck.swift`) is a reusable, engine-agnostic control surface over a
`StudioSampleEdit`, shared by the sampler editor (SAMP) and each sequencer **sample row** (SEQ3). It
forks the F4 `NowPlayingDSP` control model — same effect voicings — but drives the sampler's own
non-destructive edit + `StudioEngine` chain, never `MixEngine`, so it can't collide with a live
Mix-tab session. Two fields are added to `StudioSampleEdit` **additive-optionally** (absent ⇒ 0 ⇒ off,
no `studioSchemaVersion` bump): **`compWet`** drives a new `comp` dynamics node inserted at
`timePitch → comp → EQ`, and **`filterAmt`** repurposes the EQ's single band as a resonant low-pass
sweep (the gain carrier `globalGain` is untouched — F4's filter trick). Because both audition and the
offline bake route through the **one** `StudioAudio.applyEditToChain(…, comp:)`, they can't drift, and
because the sequencer already re-renders a row whose target sample's `renderRevision` moved, the SEQ3
per-row deck bakes into the row buffer **on the next Play for free** — the row's *live* loudness stays
the header's `RowGainChip`, so the per-row deck hides gain. The **looper** is the deliberate exception:
it's live-audition-only (SAMP), `scheduleBuffer(.loops)` over the trim window, and resets in
`unloadSample` — it never persists or bakes. (`StudioStoreTests` cover the additive decode, the clamp,
and the `renderRevision` bump on an FX change.)

**`StudioRender`** is greenfield: an `AVAudioEngine.enableManualRenderingMode(.offline)` graph
whose output is written with **`AVAudioFile(forWriting:settings:)`** — blocking writes with no
backpressure, so nothing is ever dropped. This is a *deliberate* departure from Mix's
`MixTapSink`/`AVAssetWriter` recipe (Ch. 4 §7.12): that path is realtime-only and drops buffers
when the encoder is busy — the common case offline — so **only its failure-latch discipline
carries over**, never the sink itself. Three render rules are load-bearing: samples/bounces
render `ceil(sourceFrames / rate)` **plus an FX-tail drain** (keep rendering until output falls
below −60 dBFS or a 3 s cap) so a reverb/delay tail isn't clipped; **loops render to *exactly*
the beat-window frame count** with tails truncated so the seam stays clean; and the timePitch
AU's **priming-latency head is trimmed** so written frame 0 is musical frame 0 — otherwise every
baked loop would start with a sliver of silence and beat-sync would die. AAC `.m4a` for
samples/takes/bounces, **LPCM CAF for loops** (AAC priming/padding makes an m4a loop tick at the
seam — CAF + the authoritative frame count is the seamless-loop guarantee).
(`StudioRenderTests` cover the length math, the loop frame-exactness, and the head trim.)

**Beat math.** `MixView`'s private `lastBeat` binary search and `isDownbeat` (±30 ms) were
extracted into shared `nonisolated` statics in **`BeatMath.swift`** (Ch. 4 §7.10 was their only
prior consumer), plus a new `sliceBoundaries(anchorMs:beats:grid:)` that steps through the real
`beatsMs[]` grid (with a constant-grid synthesis fallback from `bpm + firstDownbeatMs` when the
array is empty). Loop length is the **sum of the actual inter-beat intervals** when a real grid
exists (so it tracks tempo drift), else `beats × 60000/bpm`. Pure functions, unit-tested by
`BeatMathTests`.

### 8.3 Mic capture — `StudioMicRecorder` + the `AudioSessionPolicy` coexistence rule

**Why.** Sampling from the microphone (and, later, instrument-take capture) records live
input **while other engines may be playing back**. Two hazards make this delicate: an
input tap installed before the session is active reads a **0 Hz** format and raises an
*uncatchable* exception, and any playback engine that calls `setCategory(.playback)`
mid-capture would **yank the category out from under the live tap**.

**Source of truth:**
[`apple/PocketDJ/Studio/StudioMicRecorder.swift`](../../apple/PocketDJ/Studio/StudioMicRecorder.swift)
(the capture engine + orphan recovery) and
[`apple/PocketDJ/Studio/AudioSessionPolicy.swift`](../../apple/PocketDJ/Studio/AudioSessionPolicy.swift)
(the process-wide `micCaptureActive` guard).

```
 StudioMicRecorder — own small engine:
   session configured AND activated BEFORE inputNode format is read/tapped   (0 Hz fmt ⇒ installTap raises uncatchably)
   tap runs at the HARDWARE input format → deep-copy → private queue → AVAssetWriter .m4a  (realtime recipe is CORRECT here)
   iOS session .playAndRecord [.defaultToSpeaker, .allowBluetoothA2DP] WHILE recording; restore .playback after
   permission: AVAudioApplication.requestRecordPermission (Shazam pattern, explicit .denied)
   lifecycle: activeTake · orphan recovery · RecordingExitBridge finalize · stall watchdog  (MixRecorder shape)

 AudioSessionPolicy.micCaptureActive  (nonisolated atomic Bool, OSAllocatedUnfairLock):
   set for the take's DURATION; every existing setCategory(.playback) call site
   (MixEngine · PlayerEngine · StemPlayer · MixSessionsView RecordingAudioPlayer) GUARDS on it and no-ops
   → a playback load / setlist auto-advance can't reconfigure the session under the live input tap
```

**Reading it.** **`StudioMicRecorder`** owns a small engine that mirrors the `MixRecorder`
lifecycle (Ch. 4 §7.12) — `activeTake`, orphan recovery, the `RecordingExitBridge` finalize,
the stall watchdog. The order is load-bearing: the audio session is **configured and
activated before** `inputNode`'s format is read or tapped, because reading a `0 Hz` input
format and installing a tap on it raises an exception that can't be caught. The tap runs at
the **hardware input format** (here the realtime deep-copy → private-queue → `AVAssetWriter`
recipe *is* the right one — the input side is not a canonical-format playback graph), and iOS
uses `.playAndRecord` with `[.defaultToSpeaker, .allowBluetoothA2DP]` only while recording,
restoring `.playback` after. Permission goes through `AVAudioApplication.requestRecordPermission`
(the ShazamKit pattern, Ch. 7 §5.2), with an explicit `.denied` state.

The **session-coexistence rule** is the new invariant: a process-wide
**`AudioSessionPolicy.micCaptureActive`** flag (a `nonisolated` atomic Bool backed by
`OSAllocatedUnfairLock`) is set for the take's duration, and **every** existing
`setCategory(.playback)` call site — `MixEngine`, `PlayerEngine`, `StemPlayer`, and
`MixSessionsView`'s `RecordingAudioPlayer` — now **guards on it and no-ops** while a capture
is live. Without it, a playback load or a setlist auto-advance (Ch. 5 §10) firing during a
recording would reconfigure the shared session and break the input tap. The `project.yml`
mic usage string (Ch. 7 §5.3) was reworded to cover sampling as well as Shazam.
`StudioMicRecorderTests` cover the permission/`.denied` branches and the orphan-recovery paths.

**External audio inputs — sample from AUDIO IN.** `StudioMicRecorder` isn't limited to the
built-in mic: `refreshInputs()` maps `AVAudioSession.sharedInstance().availableInputs` into
selectable `InputOption`s — `InputOption(id: port.uid, name: port.portName, isLineIn:
port.portType != .builtInMic)` — so a **USB-C interface, a line-in, or a TX-6 mixer** shows up
as a pickable source. It refreshes once the session is live (`availableInputs` is only
trustworthy then) and again on every route change. `selectInput(uid:)` routes capture via
`AVAudioSession.setPreferredInput` and re-taps at the new hardware format, and the recorded
`StudioSample` stamps its **provenance** onto `captureSource` — `.mic` for the built-in mic,
`.lineIn(inputName:)` for an external input (surfaced in the editor as *"Recorded from …"*).
`StudioMicRecordView` always presents an input affordance on iOS (a menu when more than one
input exists, else a static chip + a "connect a USB-C interface / TX-6" hint); macOS uses the
system default input and shows no selector. It rides the same crash-safe writer and
route-change/stall hardening as mic capture.

### 8.4 Instruments — sampler, MIDI, click/count-in, score & export, packs on S3

**Why.** Seven virtual instruments play from a MIDI keyboard (or the on-screen keys) into a
recorded **take** that renders to a musical **score** you can replay or export as PDF/MIDI.
Three things make this non-trivial: a 32 MB SoundFont must load **without freezing the UI**,
CoreMIDI events arrive on a **real-time thread** that must not be marshalled per-note, and the
sound banks must be **downloaded from S3** for offline use.

**Source of truth:**
[`apple/PocketDJ/Studio/InstrumentEngine.swift`](../../apple/PocketDJ/Studio/InstrumentEngine.swift)
(sampler + MIDI + click + take capture),
[`apple/PocketDJ/Studio/InstrumentPacks.swift`](../../apple/PocketDJ/Studio/InstrumentPacks.swift)
(the S3 pack manifest + downloads),
[`apple/PocketDJ/Studio/ScoreModel.swift`](../../apple/PocketDJ/Studio/ScoreModel.swift)
(`ScoreQuantizer`),
[`apple/PocketDJ/Studio/SMFWriter.swift`](../../apple/PocketDJ/Studio/SMFWriter.swift) (type-0
SMF), [`apple/PocketDJ/Studio/ScorePDF.swift`](../../apple/PocketDJ/Studio/ScorePDF.swift)
(vector PDF), and the S3 layout in
[Ch. 7 §8](./07-distribution-and-clients.md#8-virtual-instrument-packs-on-s3--a-new-public-read-artifact-class).

```
 InstrumentEngine — AVAudioUnitSampler → instrumentMix (take-capture TAP here, flag-gated) → mainMixer
   click player joins DOWNSTREAM of the tap (at mainMixer) → the metronome is NEVER recorded into a take
   loadSoundBankInstrument(at: bankURL, program:p, bankMSB:0x79, bankLSB:0x00) runs OFF the main actor
     (background task touching only the sampler node) + a visible loading state — a 32 MB parse would freeze the UI
   InstrumentKey → GM programs:  piano 0 · acousticGuitar 25 · bassGuitar 33 · violin 40 · trumpet 56 · clarinet 71 · harp 46

 MIDI THREADING (load-bearing): CoreMIDI receive block fires on a CoreMIDI-OWNED thread →
   calls sampler.startNote/stopNote DIRECTLY on that thread (a nonisolated Sendable ref; the AU enqueues safely)
   + appends packet-timestamped events into an NSLock-protected buffer, gated on a PRE-LATCHED atomic "recording" flag
   @MainActor state (key highlights) updates via COALESCED hops — NEVER Task{ @MainActor } per note (jitter + reordering corrupts the log)
   MIDI scope: WIRED/USB MIDI + on-screen keys + BLE MIDI (BLEMIDIManager, below).  Network MIDI = OUT (Bonjour) — documented

 BLE MIDI (I3, cross-platform): BLEMIDIManager = a CoreBluetooth CENTRAL (not CoreMIDI) → universal (iPhone/iPad/Mac/Vision)
   scans service 03B80E5A-… → subscribes char 7772E5DB-… → parses BLE-MIDI packets (header+timestamp+status, running-status)
   → feeds engine.noteOn/noteOff — the SAME play+record path as the on-screen keys, so NO CoreMIDI source ⇒ NO double-trigger
   delegate callbacks on CBCentralManager(queue:.main) = MainActor executor → nonisolated methods MainActor.assumeIsolated back on
   perms: NSBluetoothAlwaysUsageDescription (all) + com.apple.security.device.bluetooth (macOS sandbox); lazy central = prompt on picker-open

 TAKE = click + 1-bar COUNT-IN (both default on):  event onMs measured from beat 1 = END of count-in (= ScoreQuantizer's anchor)
 SCORE:  ScoreQuantizer (anchor beat 1; onsets → 16ths @ take.bpm; durations snapped; chords/rests/measures) — PURE, tested
         ScoreView (Canvas: grand staff piano/harp · treble others · bass for bass guitar) REPLAYS the take's events → sound & score agree
         SMFWriter (type-0, PPQ 480, tempo+program meta, RAW UNQUANTIZED note on/off) — pure bytes, tested vs a hand-decoded fixture
         ScorePDF (CGContext vector pagination); both exports via .fileExporter
```

**Reading it.** **`InstrumentEngine`** is `AVAudioUnitSampler → instrumentMix → mainMixer`,
and the **take-capture tap sits on `instrumentMix`** while a separate **click player joins at
`mainMixer`, downstream of the tap** — so the metronome is audible but **never recorded** into
a take. SoundFont loading uses `loadSoundBankInstrument(at:program:bankMSB:0x79/bankLSB:0x00)`
and runs **off the main actor** (a background task touching only the sampler node) behind a
visible loading state, because the 32 MB bank parse would otherwise freeze the UI — including
on the media-reset rebuild path. Each `InstrumentKey` maps to its General-MIDI program (piano
0, violin 40, bass guitar 33, acoustic guitar 25, trumpet 56, clarinet 71, harp 46).

The **MIDI threading is the load-bearing part**: CoreMIDI receive blocks fire on a
**CoreMIDI-owned thread**, and the receive block calls `sampler.startNote`/`stopNote`
**directly on that thread** via a `nonisolated Sendable` reference (the AU enqueues events
safely) and appends packet-timestamped events into an **`NSLock`-protected buffer** gated on a
**pre-latched atomic "recording" flag**. `@MainActor` state (key highlights, UI) updates only
via **coalesced hops** — *never* a `Task { @MainActor }` per note, whose jitter and reordering
would corrupt the very event log the score is quantized from. MIDI scope is **wired/USB
devices + the on-screen keys + Bluetooth-LE keyboards**; only **network MIDI** (needs
`NSLocalNetworkUsageDescription` + `NSBonjourServices`) remains out of scope.

**Bluetooth MIDI (I3) is a CoreBluetooth central, not a CoreMIDI source** — deliberately, so it
works **identically on iPhone, iPad, Mac, and Vision Pro** (the alternative,
`CABTMIDICentralViewController`, is iOS-only). [`BLEMIDI.swift`](../../apple/PocketDJ/Studio/BLEMIDI.swift)'s
`BLEMIDIManager` scans the standard BLE-MIDI GATT service (`03B80E5A-…`), subscribes to its data
characteristic (`7772E5DB-…`), and parses the BLE-MIDI packet stream (header + running-status MIDI)
into `engine.noteOn`/`noteOff` — the **same play-and-record entry points the on-screen keys use**, so
a paired keyboard sounds the current instrument and records into a take exactly like the keys. Because
we own the BLE connection rather than registering a CoreMIDI source, there is **no double-triggering**
with the wired path. It's an `@Observable @MainActor` class whose `nonisolated` CoreBluetooth delegate
methods `MainActor.assumeIsolated` back onto the main actor — safe because `CBCentralManager(queue: .main)`
delivers callbacks on the main queue, the main actor's executor. Permissions: `NSBluetoothAlwaysUsageDescription`
(all platforms) plus the `com.apple.security.device.bluetooth` entitlement (macOS sandbox); the central is
created lazily when the user opens the picker, so the Bluetooth prompt only fires on demand.

A **take** records with a **click + 1-bar count-in** (both default-on, toggleable); each
event's `onMs` is measured from **beat 1 = the end of the count-in**, which is also
`ScoreQuantizer`'s anchor. The score pipeline is deliberately split by fidelity:
**`ScoreQuantizer`** (pure, `ScoreQuantizerTests`) snaps onsets to 16ths at `take.bpm` and
durations to note values, grouping same-onset notes as chords and filling gaps with rests for
**display**; **`ScoreView`** (a SwiftUI `Canvas`) draws the staff and **replays the take's raw
`events`** through `InstrumentEngine`, so what you see and what you hear always agree; but
**`SMFWriter`** (`ScoreLayoutTests` cover staff layout; `SMFWriterTests` verify the bytes
against a hand-decoded fixture) exports the **raw, unquantized** notes as a type-0 SMF (PPQ
480, tempo + program-change meta), and **`ScorePDF`** paginates a **vector** PDF via
`CGContext`. Both exports go through `.fileExporter`. "Use as sample" copies the take's audio
into a new `StudioSample(source: .take(id))` with a constant grid from `take.bpm` — the
promised take → sample → loop path (§8.1).

The seven **instrument packs** download from S3 — the manifest, bank, licensing, and upload
path are a new public-read artifact class documented in
[Ch. 7 §8](./07-distribution-and-clients.md#8-virtual-instrument-packs-on-s3--a-new-public-read-artifact-class);
the client half (`InstrumentPacks.swift`: offline-first index cache, file-based
`URLSession.downloadTask`, `bankKey` dedupe, atomic move into `studio/instruments/`) mirrors
the `BurnStore` stems-trio download shape (Ch. 5 §15). `InstrumentPacksTests` cover manifest
decode, the GM mapping, and the bank dedupe.

### 8.5 Cue points — up to 8 per track, and the `startMs` playback plumbing

**Why.** A cue point starts playback of an *indexed* track from where you tapped — a
different animal from the studio artifacts above (it references a catalog song, not a
device-local file). The hard part is **threading a start offset** through the existing
stream-first/rip-last playback chain (Ch. 5 §8), which had no concept of "begin at ms X."

**Source of truth:** the `StudioCue` model in
[`StudioModels.swift`](../../apple/PocketDJ/Studio/StudioModels.swift), the cue UI in
[`apple/PocketDJ/Studio/Views/StudioCuesView.swift`](../../apple/PocketDJ/Studio/Views/StudioCuesView.swift),
and the offset plumbing through
[`PlaybackCoordinator.swift`](../../apple/PocketDJ/Playback/PlaybackCoordinator.swift) /
[`RipServerPlaybackProvider.swift`](../../apple/PocketDJ/Playback/RipServerPlaybackProvider.swift) /
[`AppleMusicPlaybackProvider.swift`](../../apple/PocketDJ/Playback/AppleMusicPlaybackProvider.swift)
into [`RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift)
(`cueSeekMs`) and `PlayerEngine.load(startMs:)` (Ch. 5 §7).

```
 StudioCue { id, songId, slot 0–7, positionMs, name? }   max 8/song, store-enforced; slot-indexed stable colors
 CuesView:  track picker (burned first) · timeline waveform · TRANSPORT (play/pause + scrub) · 8 slot buttons (tap = play-from-cue · long-press = set/rename/nudge/delete)
   waveform:  digital → entry.waveform PNG as-is;  ANALOG PNG = whole album SIDE → crop/scale to [startMs, startMs+durationMs]
              (prefer local MixWaveform peak extraction when burned); none → plain timeline
   TRANSPORT: play/pause + scrub bar → audition + seek to a spot to place cues WITHOUT listening start-to-finish.
              play(cue:) refactored into shared startPlayback(song:atMs:); dual backend (PlayerEngine burned/rip · coordinator AM);
              scrub gated on `seekable` (live HLS can't seek); play-from-TOP always allowed (auditioning an in-flight rip);
              position/isPlaying SAMPLED on a TimelineView off the non-@Observable PlayerClock (never invalidates the slots)

 MIX SURFACE (Ch.4 §7):  a loaded deck reads studio.cues(forSong: loaded.songId) → jump-to-cue chips under the deck scrubber
              (≤8, 4-col = two rows, StudioCuesView.slotColor) → engine.seek(deck, toSeconds: positionMs/1000)  (song-relative; Mix loads burned only)

 startMs (cue offset) threads through PlaybackCoordinator.play → TrackPlaybackProvider.tryPlay into BOTH providers:
   RipServer → RipsStore.cueSeekMs(sharedFileStartMs: song.startMs, atMs: cue) → PlayerEngine.load(startMs:)  (EXACT on burned/analog)
   AppleMusic → play-then-seek via ApplicationMusicPlayer.playbackTime once playback starts   (documented ~<1 s imprecision)
   rip IN FLIGHT (live HLS) → unseekable → cue button shows a "still ripping" disabled state
```

**Reading it.** A `StudioCue` is `{songId, slot 0–7, positionMs}`, **max 8 per songId,
store-enforced** (`StudioStoreTests` cover the cap), with slot-indexed stable colours.
`StudioCuesView` picks a track (burned tracks first), shows a timeline, and gives eight slot
buttons: tap plays **from** the cue, long-press sets-at-playhead / renames / nudges / deletes.
The waveform reuses the existing art: a **digital** song uses `entry.waveform` as-is, but an
**analog** song's PNG is the *whole album side*, so it is cropped/scaled horizontally to the
song's `[startMs, startMs + durationMs]` window (both on `ManifestEntry`, Ch. 5 §5), preferring
local `MixWaveform` peak extraction when the song is burned.

The new plumbing is the **`startMs` offset threading `PlaybackCoordinator.play →
TrackPlaybackProvider.tryPlay`** into **both** providers (Ch. 5 §8). The rip-server provider
folds the cue into **`RipsStore.cueSeekMs`** — which combines the shared-analog-album
`song.startMs` with the cue `atMs` — and hands it to `PlayerEngine.load(startMs:)` (Ch. 5 §7),
so a **burned local file (the common case) plays exactly** from cue ms + the album seek. The
Apple Music provider **plays-then-seeks** via `ApplicationMusicPlayer.playbackTime` once
playback starts (a documented ~sub-second imprecision). A song whose rip is **in flight (live
HLS)** can't seek, so its cue buttons show a disabled "still ripping" state. `CuePlumbingTests`
cover the `cueSeekMs` math (plain play vs. cue play vs. shared-analog offset).

**Placing cues without listening through the whole song.** The Cues view has a **transport under the
timeline — play/pause + a scrub bar** — so you can audition and seek to a spot, then drop a cue there
(rather than the old flow of setting one cue at 0:00, playing from it, and listening the whole way to
place the next). `play(cue:)` is refactored into a shared **`startPlayback(song:atMs:)`** that both the
cue-slot taps and the transport's play button use — same burned-vs-streaming routing — so there is one
start path. `CueTransport` drives `PlayerEngine` directly for a burned/rip track (`toggle`/`seek`/`clock`)
and the coordinator for Apple Music; its scrub is gated on the same `seekable` check as cue playback
(a live/in-flight HLS rip can't seek), while **play-from-the-top stays available** so you can still
audition an in-flight rip. Position and play-state are **sampled on a `TimelineView`** off the
non-`@Observable` `PlayerClock`, so the ~10 Hz tick never invalidates the sibling cue slots (the
dropped-clicks doctrine, Ch. 5). The **same cues surface in the Mix tab** (§7): a loaded deck reads
`studio.cues(forSong:)` and renders jump-to-cue chips under its scrubber that `engine.seek` the deck to
`positionMs` — `positionMs` is song-relative, exactly what `MixEngine.seek(toSeconds:)` expects.

### 8.6 Collections integration — namespaced ids, schema v5 lossy decode, and the consumer fence

**Why.** Samples, loops, and sequences become **collection items** — you drop a loop into a
pocket or playlist — but they are device-local files with **no catalog id, no streamable
source, and durations measured in seconds**. They must ride the collections graph for
*playback and stats* while being **fenced out of every consumer that talks to money or shared
infrastructure** (rip, stemify, burn, CSV, the realize autofill pool). Getting that fence
wrong leaks a `lp_…` id into the public rips bucket or realizes a 4-second loop as a 3½-minute
track.

**Source of truth:**
[`apple/PocketDJ/Models/CollectionsSchema.swift`](../../apple/PocketDJ/Models/CollectionsSchema.swift)
(`collectionsSchemaVersion` — the studio integration was the v4→v5 bump; later, unrelated
features have since taken it to **7** (v6 source-sync provenance, v7 `lastPlayedAt`) — and the
per-element lossy `[PlaylistNode]`/`[Playlist]` decoders — Ch. 3 §3.1),
[`apple/PocketDJ/State/CollectionsStore.swift`](../../apple/PocketDJ/State/CollectionsStore.swift)
(`playableIds(...)`, `songIds(forSetlist:)` studio exclusion, `studioLookup`, the realize
synthetic-entry helper),
[`apple/PocketDJ/Models/CollectionCatalog.swift`](../../apple/PocketDJ/Models/CollectionCatalog.swift)
(the `studio:` lookup injection + `IndexSong.studioSynthetic`),
[`apple/PocketDJ/State/RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift)
(`StudioFactory.isStudioId` skip guards) and
[`scripts/rip-server.mjs`](../../scripts/rip-server.mjs) (the `STUDIO_ID` server-side reject).

```
 MECHANISM: namespaced ids ride the EXISTING string arrays — smp_/lp_/ptn_ inside Pocket.songIds
   and PlaylistNode(kind:.song, songId:).  NO new node kind (a new Kind wipes playlists on older builds — Codable trap).

 INSURANCE (shipped now): per-element LOSSY decode at EVERY [PlaylistNode] site (chapter children AND nested
   `children` recursion) AND the [Playlist] list itself — one unknown-kind node drops THAT node only, never a
   chapter/list/document (FailableBox → compactMap, CollectionsSchema.swift).  This was the v4→v5 bump, no-op migration
   (the version has since moved on to 7 for unrelated features — Ch. 3 §3.1).

 PER-CONSUMER RESOLUTION (studio ids behave like TEXT nodes for anything talking to money/infra):
   SetlistPlayer playback / playNow      RESOLVED via StudioStore (local file, scope release)  ← playableIds()
   Counts / runtime subtitles            INCLUDED (title + real lengthMs)                       ← studioLookup
   Realize node placement (playlist ▶)   PLACED via synthetic pseudo-song (real lengthMs, bpm/camelot if known)
   Realize AUTOFILL candidate pool       NEVER included — a user loop must not become a harmonic bridge
   Rip / Stemify / Burn                  EXCLUDED (text-node precedent) — filtered at the consumer boundary
   Tracklist CSV export                  EXCLUDED
   Browse membership filters / StorageCollectionsView   EXCLUDED (catalog-only, unchanged)
   Zip export/import                     ids travel as-is (media stays device-local); import-remint leaves unknown prefixes untouched

 DEFENSE IN DEPTH (old builds + shared server):  RipsStore.ripCollection/requestRip/stemify SKIP studio ids,
   AND scripts/rip-server.mjs REJECTS smp_|lp_|ptn_|tk_ at /rip, /rip-collection, /stemify (STUDIO_ID regex, 400).
```

**Reading it.** The **mechanism is deliberately boring**: studio ids ride the *existing*
`Pocket.songIds` / `PlaylistNode(kind:.song, songId:)` string arrays. There is **no new node
kind**, because adding a `PlaylistNode.Kind` case changes the synthesized `Codable` and would
**wipe playlists on any older build** that hits the unknown case. The **insurance that makes
future kinds safe is shipped now** (Ch. 3 §3.1): a **per-element lossy array decoder** at
*every* `[PlaylistNode]` site — chapter children **and** the nested `children` recursion — and
at the `[Playlist]` list itself, via a `FailableBox` that swallows a failed element into `nil`
and `compactMap`s it away, so one unknown-kind node drops **that node only**, never a chapter,
a list, or the document. `collectionsSchemaVersion` bumped to **5** with a no-op migration (later, unrelated
features have since taken it to **7**: v6 source-sync provenance, v7 `lastPlayedAt` —
Ch. 3 §3.1).
`CollectionsLossyDecodeTests` prove an unknown kind at the top level, as a chapter child, and
as a nested grandchild all survive a decode+save round trip with siblings and other playlists
intact.

The **per-consumer table** is the fence, and it is enforced at the store boundary, not in the
engine. `CollectionsStore.songIds(...)` keeps its **catalog-only** semantics (studio ids
filtered via `StudioFactory.isStudioId`); a new **`playableIds(...)`** companion — plus a
`CollectionCatalog` **`studio:` lookup injection** for the `songs(forNode:)`-driven paths —
feeds **playback and stats** the resolved studio items (real title + `lengthMs`). `SetlistPlayer`
resolves a studio row to its local file through a **`studioResolve`** closure and plays it as
on-device audio (Ch. 5 §10). Realize **places** a studio node via a **synthetic pseudo-song**
injected into `ctx.songsById` — built by a studio-aware helper (`IndexSong.studioSynthetic`,
carrying **mandatory `lengthMs`** plus bpm/camelot when known) so a 4-second loop realizes as
4 seconds, not the 210 s default — while the **autofill candidate pool never includes studio
ids**, so a user's loop can never surface as a harmonic bridge in an arbitrary setlist. Crucially
`songIds(forSetlist:)` (a raw passthrough before) gained a **studio-prefix exclusion** so a
realized set can't leak a `lp_…` into **Rip / Stemify / Burn** or the **tracklist CSV**.
`CollectionsStudioTests` cover the v5 decode, the per-consumer policy (playable vs. songIds vs.
setlist exclusion), the synthetic-entry lengths, and the autofill fencing.

**Defense in depth** closes the rip-on-demand leak against **old builds and the shared server**:
`RipsStore.ripCollection` / `requestRip` / `stemify` skip studio-prefixed ids client-side, **and**
`scripts/rip-server.mjs` rejects `smp_|lp_|ptn_|tk_` ids at `/rip`, `/rip-collection`, and
`/stemify` (the `STUDIO_ID` regex → HTTP 400). The rip server is **shared infrastructure across
app versions**, so an *older* build's play-through-coordinator landing on a studio row must not
be able to fire a live-search rip into the public bucket. A **known, documented divergence**: the
PWA's realize drops studio ids (they aren't in its catalog), so a seed reproduces different sets
on web for a playlist containing studio items — acceptable for a native-only feature, and noted
here and in the spec. Add-to paths reuse the string-id plumbing (`AddToCollectionView.Item` gains
a `.studio(id, title)` case) and `SetlistDetailView` rows show a Sample/Loop/Sequence badge from
the id prefix.

### 8.7 Advanced sampling & scoring — file/stem sources, on-device beat detection, slice-to-pads & the live score

**Why.** The Studio round 4 removes four ceilings: a sample could only come from an indexed track or
the mic; a grid-less sample needed manual tap-tempo; a sample couldn't be chopped into performance
pads; and the instrument score was read-only, post-take notation. Each is additive to the **schema-v5
lossy-decode** doctrine (§8.6) — new fields/lists degrade to defaults or drop the single element on an
old build, never bricking the document.

**On-device beat detection — `Support/BeatDetect.swift`.** The app previously only *consumed* beat
grids (server-side librosa, `analog-indexer/audio/analyze-beatgrid.py`). `BeatDetect.detectGrid(_:
AVAudioPCMBuffer) -> StudioGrid?` ports that pass to **Accelerate/vDSP** so an imported/mic sample —
which has no `analysis-<id>.json` sidecar — can still get a tempo: half-wave-rectified **spectral-flux
onset envelope** (vDSP real FFT) → **autocorrelation** over a wide 55–210 BPM search weighted by a
log-normal prior centred on 120 → **octave-fold** into the DJ window [70,180] → onset-energy **4/4
downbeat phase**. All `nonisolated` statics run off the main actor; the buffer comes from
`StudioRender.decodeFileSync` (pure file I/O — no `AVAudioSession`, so it's session-policy-safe by
construction). Output is a constant `StudioGrid(bpm:firstDownbeatMs:)` — exactly what
`BeatMath.sliceBoundaries`/`sliceStarts` consume. Wired as **Auto-detect tempo** in the sample
editor's grid-less branch; write-back via `StudioStore.setSampleGrid` (which deliberately does NOT
bump `renderRevision` — the grid drives slicing math, not the baked audio).

**Sampling from files + downloaded + stems.** `StudioSource` gains an additive **`.file(originalName:)`**
case (unknown `type` still degrades to `.mic` on old builds). `StudioRender.importAudioFile(sourceURL:
to:)` decodes any container AVFoundation reads → canonical 44.1k AAC `sample-<id>.m4a`, rejecting
DRM-protected assets (`AVURLAsset.hasProtectedContent` → `StudioRenderError.protectedSource`) so a
FairPlay `.m4p` can't become a sample. The Samples view drives a `.fileImporter([.audio])` (transient
security-scoped copy INTO the samples folder, never persisting the external URL). **Downloaded-only
sampling** is a `restrictToDownloaded` mode on `StudioNewSampleFromTrackView` that filters the picker
to `BurnStore.readyBurnedIds`, so every pick instant-carves and never streams/burns. **Stem-source**
sampling: when `RipsStore.isStemmed(songId)` (or `BurnStore.stemsBurned`) is true, the carve screen
offers per-stem chips (the 4 `StemPlayer.stems`); `StudioRender.carveStemMix(stemURLs:startMs:endMs:
to:)` reads each selected stem's window — stems are **song-relative** (0:00 = song start, unlike the
album-offset single-file carve), resolved via `BurnStore.localStemURLs`/`burnStems` — and SUMS them
(`vDSP_vadd`) into one canonical AAC. Demucs stems sum back to ≈the original, so no attenuation is
applied (a subset is simply quieter, like muting deck stems in §7.6).

**Slicing → performance pads.** A new persisted list `StudioDocument.slices: [StudioSlice]` (threaded
through `StudioStore.init` load + `snapshotDocument` — a top-level list must touch BOTH or it never
persists). `StudioSlice` (id `slc_`, **NON-riding** like `cue_` — never in `StudioFactory.studioPrefixes`)
is a **start-marker cue point**: `sampleId, slot(0–7), startMs, name?`; the play-out boundary is
derived (`StudioStore.sliceWindow` = this pad's start → the next pad's start, or the sample's raw end),
so pads may be dragged out of time order. The 8-slot CRUD mirrors cues (`setSlice`/`setSlices` chop/
`removeSlice`/`nudgeSlice`); `deleteSample` sweeps a sample's orphan slices. `BeatMath.sliceStarts(
count:grid:durationMs:)` computes the auto-chop — even time division grid-less, snapped to the beat
lattice with a grid (coincident snaps merge → fewer pads). Audition is `StudioEngine.playSlice(startMs:
endMs:)` — a **self-contained one-shot** on the already-loaded RAW sample (its own `sliceEndSec`
out-point checked by the render-clock tick; never touches the trim window, guarded against the
zero-frame crash). A **performance pad** is baked by carving the slice region into a normal `smp_`
sample (`StudioSliceEditorView` → `StudioRender.carveTrackRegion`), which then flows into Loops / the
16-step sequencer (`StudioPatternRow.targetId`) / "use as sample" under the existing `smp_` fence for
free; "Send pads to sequencer" bakes every pad → a new `StudioPattern`, one row each.

**Proper accidentals + editable score.** `StudioNoteEvent` gains an additive **`accidental: Accidental?`**
(`{natural,sharp,flat}`, display-only — the MIDI number is the sound, so `SMFWriter` is untouched).
`ScoreItem` carries a `spellings: [Int: Accidental]` map threaded through `ScoreQuantizer`;
`ScoreLayout.spelledPosition(midi:clef:accidental:)` places the head on the natural line ABOVE/BELOW
and draws the accidental (E♭ = the E line + ♭, not the D♯ line), backed by a new `ScoreGlyph.flat`.
Editing mutates the RAW event stream, not the derived score: `StudioTake.editedEvents: [StudioNoteEvent]?`
(nil ⇒ keep deriving so quantizer improvements still apply; non-nil ⇒ the score/replay/MIDI read it via
`take.scoreEvents`), persisted by `StudioStore.setTakeEvents` (extends `durationMs`; `revertTakeEdits`
drops it). On-staff hit-testing is pure/inverse: `ScorePage` now carries structured
`LaidSystem`/`LaidMeasure`/`LaidStrip` geometry, and `ScoreLayout.locate(point:page:)` +
`naturalMidi`/`onsetFromX`/`notePoint` invert the layout math (round-trip unit-tested). The editable
surface is extracted into **`ScoreEditorView`** (place/select/toolbar/selection-ring via
`SpatialTapGesture` → page space), shared by the take Score screen (→ `setTakeEvents`) and the live
staff (→ `setLiveEvents`).

**One live editable staff.** `InstrumentEventLog` gains an **always-on** capture path
(`liveOn`/`liveOff`, anchored at the first note, completed-notes-only, coalesced `snapshotLiveIfDirty`)
that is deliberately SEPARATE from the take `armed` gate AND called BEFORE the audible guard in the
engine's `noteOn`/`noteOff` + the CoreMIDI path — so it fills even with no instrument loaded and never
desyncs a take's audio (the take log stays audible-only). It publishes on the existing 30 Hz highlight
pump into `InstrumentEngine.liveEvents` (the pump was **moved above `engine.start()`** so the
audio-independent drains run even when audio can't start). `StudioInstrumentsView` renders it through
the shared `ScoreEditorView`; **Save-as-take** files the events with a silent placeholder audio (launch
reconcile prunes takes whose file is missing — replay plays events, so the take is audible; only "use
as sample" is silent, a documented follow-up). New tests: `BeatDetectTests`, `BeatMathTests`
(sliceStarts), `StudioRenderTests` (stem-mix sum), `ScoreLayoutTests` (spelling + locate round-trips),
`StudioStoreTests` (slices + editedEvents), `InstrumentLiveLogTests` (capture + engine noteOn→liveEvents).

**visionOS App Icon.** Distribution-adjacent (Ch. 7): `Assets.xcassets` gained an
`AppIcon.solidimagestack` (layered visionOS icon: pocket/back · controller/middle · DJ/front, split
from the flat icon so the straight-on composite is pixel-identical) beside the existing
`AppIcon.appiconset` — actool resolves the right type per platform, injecting the
`CFBundleIcons.CFBundlePrimaryIcon` key the visionOS TestFlight upload requires.

### 8.8 On-device analysis & performance items as collection tracks

**Source of truth:**
[`KeyDetector.swift`](../../apple/PocketDJ/Studio/KeyDetector.swift) (KK key detection),
[`StudioAnalyzer.swift`](../../apple/PocketDJ/Studio/StudioAnalyzer.swift) (burn-on-add + `ensureKey`),
[`MixResolver.swift`](../../apple/PocketDJ/Mix/MixResolver.swift) (`studioLoadable`), and
[`StudioRender.swift`](../../apple/PocketDJ/Studio/StudioRender.swift) (`renderTake`), with the
schema in [`CollectionsSchema.swift`](../../apple/PocketDJ/Models/CollectionsSchema.swift) and the
store in [`StudioStore.swift`](../../apple/PocketDJ/Studio/StudioStore.swift).

A studio artifact — a sample (`smp_`), loop (`lp_`), sequence bounce (`ptn_`), or instrument take
(`tk_`) — carries no server sidecar: no BPM from the audio indexer, no Camelot, no burned file in
`BurnStore`. This section is how such an id becomes a *first-class, harmonically-mixable collection
track* anyway: detect its key on-device, render/bounce it to a real file, freeze it into a setlist,
and hand it to the Mix decks alongside catalog songs. (STORYBOOK:
[The Studio](../storybook/studio.md).)

```
 "Add to…" a studio id ─► StudioAnalyzer.prepare(forStudioId:studio:packs:)   (fire-and-forget)
        │
        ├─ tk_  → StudioTakeRenderer.ensureRendered  (renderTake → real .m4a; needs the pack)
        ├─ ptn_ → StudioPatternBouncer.ensureBounced (auto-bounce a dirty sequence)
        │        (smp_ / lp_ already carry a rendered/raw file)
        └─ ensureKey → KeyDetector ──► StudioStore.setCamelot(_:forStudioId:)   (keys[id])
                          │
      ┌───────────────────┴────────────────────┐
   detect(noteEvents:)                     detect(audio:)
   tk_: duration-weighted PC histogram     smp_/lp_/ptn_: chromagram of rendered PCM
   (exact MIDI, no decode)                 (vDSP FFT 4096 · Hann · first 30 s → 12 PCs)
      └────────────► detect(chroma:) ── KK correlate 24 keys ─► Camelot + 0…1 strength

 Consumed by:  StudioCollectionRow (row) · SetlistPlayer (repeat playback) ·
               MixResolver.studioLoadable (deck: file + bpm grid + Camelot)
```

**Reading the diagram.** `KeyDetector` is one Krumhansl-Kessler correlation engine behind two front
doors. The shared back end is `detect(chroma:)`: given any 12-bin nonnegative pitch-class profile
(index 0 = C), it rotates the profile to each of 12 candidate tonics and takes the Pearson
`correlation` against the `majorProfile` and `minorProfile` KK weight vectors — 24 comparisons — then
maps the best-correlating tonic/mode to its `majorCamelot`/`minorCamelot` code and returns a `0…1`
`strength` (the winning correlation remapped from `[-1, 1]` via `(bestScore + 1) / 2`). The two
front doors differ only in how they *build* that histogram. `detect(noteEvents:)` is the
**instrumental** path: it walks the take's `StudioNoteEvent`s and accumulates each note's *sounding
duration* (`offMs − onMs`) into `chroma[note % 12]` — an exact tonal profile straight from the played
MIDI, no audio decode, so a long held tonic anchors the key more than a passing sixteenth.
`detect(audio:)` is the **sampled** path: `chromagram(_:)` runs a `vDSP` real FFT (4096-point,
`vDSP_HANN_NORM` window, 2048 hop) over the first `maxSeconds = 30` of decoded PCM, maps each bin in
the 55–5000 Hz musical band to a pitch class via `69 + 12·log2(f/440)`, and folds `|X|` into the 12
bins. Every symbol is a `nonisolated` static over value types, so the FFT runs off the main actor.
This deliberately **mirrors the server's `analyze-one.py` `detect_key`** (Ch. 2 §5), ported from
NumPy to Accelerate/vDSP so a performance item gets the *same* Camelot vocabulary the catalog carries.

**`StudioAnalyzer.prepare` — the burn-on-add path.** When an item enters a collection (each Studio
sub-tab's "Add to…" fires `StudioAnalyzer.prepare`), two things must be true before it can play and
mix: it must have real audio on disk, and it must have a key. `prepare` does both, in order. First it
*burns*: a `tk_` instrumental routes to `StudioTakeRenderer.ensureRendered` (its stored file is only
a silent placeholder until the events are synthesized — see below), and a `ptn_` sequence routes to
`StudioPatternBouncer.ensureBounced`, which auto-bounces a *dirty* pattern the same way the
sequencer's "Bounce for offline" button does. This closes the "couldn't play until I bounced it by
hand" gap: a dirty/never-bounced pattern resolves to `nil` in `localURLForPlayback`, so without the
auto-bounce an added sequence would silently skip. Samples and loops already carry a rendered/raw
file and skip straight to keying. Then `ensureKey` runs — guarded by `studio.camelot(forStudioId:)
== nil`, so it is **lazy and idempotent** (a no-op once a key is stored). For a take it detects
straight from `take.scoreEvents`; for an audio item it holds the file's security scope, decodes on a
detached utility `Task` (`StudioRender.decodeFileSync` → `KeyDetector.detect(audio:)`), releases the
scope, and stores the Camelot via `StudioStore.setCamelot`, which persists into `keys[id]` in
`pocketdj-studio.json`.

**`repeatCount` — one convention, three resting places.** A performance item usually *is* a loop, so
membership carries a play count. `CollectionMembership` is the single home for the convention:
`normalizedRepeat(_:)` clamps a stored optional to `[1, 99]` (nil/≤1 ⇒ once) and `storedRepeat(_:)`
keeps the serialized form sparse (nil for a normal single play). It lives in three schema slots:
a **pocket** keys it in the `Pocket.songRepeats: [String: Int]` sidecar map (pockets store members
as a flat `[String]`, so the count rides parallel, like `notes`); a **playlist** stores
`PlaylistNode.repeatCount`; and at ▶ Play both freeze into `SetlistTrack.repeatCount`. `SetlistPlayer`
consumes it as `currentPlaysRemaining`: `playCurrent`/`adoptNowPlayingIfJumped` arm it to
`normalizedRepeat(queue[pos].repeatCount)`, and `handleEnded` — *only* on a natural end, never an
explicit skip or dead source — decrements and replays in place via `playCurrent(fresh: false)` while
plays remain, advancing to the next track only when the count is spent (the `[1, 99]` clamp is why
this can never spin forever). Totals agree through `SetlistTrack.shownMs` = `perPlayMs ×
normalizedRepeat(repeatCount)`, so a 4-second loop set to `8×` contributes 32 seconds to a
collection's runtime, not four.

**`StudioCollectionRow` — a real track row for an `smp_`/`lp_`/`ptn_`/`tk_` id.** A studio id rides
the collection's `songIds` but has no catalog `IndexSong`, so this row synthesizes a full track cell:
`PocketDJArtwork` (the in-app `PocketDJIcon` imageset, since a performance item has no album cover),
a kind badge derived from the id prefix (`Sample`/`Loop`/`Sequence`/`Instrumental`), the BPM, the
item's own async waveform (loaded via `StudioWaveform.peaks(forStudioId:)` into a compact
`MixWaveformView`), and its length — all resolved live from `StudioStore` through the
`collections.studioLookup` seam. It also carries the **in-row repeat editor**: `repeatMenu`, an
always-visible tappable capsule showing `N×` (a `Menu`, not a nested context submenu, so it works
reliably inside a `List` row), plus the same presets (`[1, 2, 3, 4, 6, 8, 16]`) in the long-press
context menu alongside Remove.

**`performerName` / `studioArtist` — who "made" a performance item.** The user's identity for their
own work is `SettingsStore.pocketDJName` (Settings ▸ "Your PocketDJ name"). `PocketDJApp` init pushes
it into `CollectionsStore.performerName` (`collections.performerName = settings.pocketDJName`) and the
Settings field re-pushes on change. Every consumer reads the resolved `CollectionsStore.studioArtist`,
which is `performerName.isEmpty ? "Studio" : performerName` — so a blank name degrades to `"Studio"`
rather than an empty artist line, and a named DJ sees their own name on their samples and takes.

**`MixResolver.studioLoadable` — a studio id becomes a deck.** A `MixLoadable` is the picker/deck
snapshot (title, artist, `bpm`, `camelot`, length). `MixResolver` special-cases studio ids: when
`StudioFactory.isStudioId(id)` it calls `studioLoadable`, which confirms the item's local audio
resolves (`studio.localURLForPlayback`, existence-only — it releases the scope immediately; the deck
re-acquires a held handle when it actually loads), then builds the loadable from
`studio.displayInfo` (title, length, **constant-BPM beat grid** derived from the item's *known* BPM,
not re-detected) and `studio.camelot(forStudioId:)` (the detected Camelot), with the artist set to
`collections.studioArtist`. That gives Auto-Mix and harmonic glide (`MixEngine.glideParams`) a beat
grid and a key for a track that has no server analysis sidecar. For a **frozen setlist** studio
track, `setlistLoadables` prefers this live resolution (`studioLoadable(t.songId)`); a studio track
whose source item was deleted resolves to `nil` — unlike a catalog track it has no `BurnStore` file
to fall back to (the snapshot's `camelot`/`bpm` survive on the `SetlistTrack`, but a deck still needs
the live local file to open).

**Instrumentals as real audio — `StudioRender.renderTake`.** A live-saved instrument take stores only
a *silent placeholder* file; `renderTake(events:bankURL:program:to:)` is what turns its notes into an
audible `.m4a`. It builds an offline `AVAudioEngine` in `.offline` manual-rendering mode, attaches an
`AVAudioUnitSampler`, and — before starting the engine — loads the take's SoundFont at GM `program`
via `loadSoundBankInstrument` (`bankURL` comes from `InstrumentPackStore.localBankURL`; a nil there is
the "download the pack first" gate, never a silent fallback). `pumpSampler` then renders in
`chunkFrames` blocks, firing each `startNote`/`stopNote` at its exact frame (`InstrumentEngine.
replayActions` in time order), trimming the **AU priming-latency head** (`sampler` latency +
`outputNode` latency, in canonical frames) so written frame 0 is *musical* frame 0, and finally
draining the sampler's **release tail** until a 512-frame RMS window falls below −60 dBFS or a 3 s cap
trips — so a note-off's decay is never truncated. Three consumers share this one render: the Score
screen's "Export audio", "Sample from instrumental" (which files a self-contained
`StudioSample(source: .take(...))` whose audio is the render, not a copy of the placeholder), and the
playback render cache `StudioTakeRenderer.ensureRendered` (filed via `StudioStore.setTakeRendered`,
which `localURLForPlayback` prefers over the raw placeholder). Takes are **user-relocatable**:
`StudioStore.addTakeRelocating` moves a finished take into `settings.takesFolderBookmark` when one is
configured, stamping `wasUserFolder` to match where the file actually lands.

Finally, a studio id is a *partial* member by design (Ch. 4 §8.6): the per-consumer fence still
**excludes** studio ids from rip, burn, stemify, CSV export, and autofill (there is no catalog row,
rip source, or streamable track behind them), while **playback, counts/runtime, and realize
node-placement include them** — which is exactly what makes them first-class enough to loop, total,
harmonically mix, and freeze into a setlist, without leaking into pipelines that assume a catalog
song.

---

### 8.9 Multitrack arranger — the `Tracks` sub-tab

The seventh Studio sub-tab (`StudioSubTab.tracks`, ⌘7) is a lightweight **multitrack arranger** that
composes the four studio families into a timeline. It is deliberately **additive** — no
`studioSchemaVersion` bump — and self-contained.

**Data model** (`StudioModels.swift`). Three new value types ride the studio document
(`StudioDocument.arrangements`, per-element-lossy like every other list):

- **`StudioArrangement`** (`arr_…`) — a named workspace: `tracks: [StudioTrack]`, timestamps.
- **`StudioTrack`** (`trk_…`) — one lane: `clips: [StudioClip]`, a mix strip (`gainDb` / `muted` /
  `soloed`), and a palette `colorIndex`.
- **`StudioClip`** (`clip_…`) — a positioned, **immutable baked snapshot**: `fileName`
  (`clip-<id>.m4a`), `startMs`, `durationMs`, a `StudioClipSource` provenance tag (sample / loop /
  pattern / take / recording / master), and the `sourceId` it was baked from (label only).

The `arr_/trk_/clip_` prefixes are minted by `StudioFactory` and, like `cue_/slc_/sfld_`, are
**deliberately excluded from `studioPrefixes`** — an arranger id never rides a collection's string
array, so the rip/realize/burn fences must not treat it as a routable studio item. Clip audio lives
in an **app-managed `Application Support/studio/arrangements/`** dir (not a `StudioFamily`: arranger
clips are derived snapshots, never user-relocatable, so they skip the bookmark / knownIds / reconcile
machinery). CRUD is a **same-file `StudioStore` extension** (so the `private(set) arrangements` setter
stays file-private); `mutateArrangement` is the single data-mutation door (stamps `updatedAt`, saves),
while file-touching ops (delete / duplicate / bake) manage `clip-<id>.m4a` directly — duplicate
**copies** each clip's audio to a fresh file so two records never share one.

**Bake a clip** (`ArrangerClipBaker`). Adding a source runs `StudioAnalyzer.prepare` (bounces a dirty
pattern / renders an un-rendered take — a no-op for samples & loops), resolves it via
`localURLForPlayback`, then `StudioRender.importAudioFile` writes a canonical-AAC snapshot into the
arrangements dir. A live mic recording takes the same import path from the recorder's samples file
(`bakeFromFile`), after which the orphan library file is deleted.

**Synced playback** (`MultitrackPlayer`, `@MainActor @Observable`, view-scoped). Play rebuilds a fresh
`AVAudioEngine` graph — one `AVAudioPlayerNode → gain(mixer) → mainMixer` per track — decodes each
clip to a canonical buffer, schedules it at its ms→frame offset on the node's timeline
(`scheduleBuffer(at: AVAudioTime(sampleTime:atRate:))`), then starts **every** node at one shared
`AVAudioTime` (now + a 0.12 s pre-roll) so the sample timelines coincide — the same one-host-time sync
`StudioEngine.restartPatternFromTop` and the MixEngine stem decks use. Per-track mute / solo / gain map
to each track's mixer `outputVolume` and update **live** mid-play (solo wins); a non-Observable
`MultitrackClock` (sampled by a `TimelineView`) drives the playhead without re-running the view; an
auto-stop task ends playback a tail past the last clip.

**Bounce** (`ArrangerBouncer`). Because clips are already-baked snapshots with **no per-clip DSP**, a
mixdown is a straight **sample-sum** (the `carveStemMix`/`addBuffer` approach, not an offline engine):
allocate a canonical accumulator sized to the longest track, add each clip (decoded via the
nonisolated `StudioRender.decodeFileSync`) at its start frame scaled by its track gain, **peak-limit**
to avoid summing overflow, write AAC — all off the main actor (only `Sendable` `(gain, startFrame,
url)` tuples cross the boundary, never a buffer). Per-track **gain applies; mute/solo do not** (an
explicit bounce mixes exactly the tracks you chose). Individual (one track), selected (a toggle
sheet), or all → each appends a new **`Master`** track holding the mixdown.

**Verify status.** Model round-trip + CRUD + the offline-mix path are unit- and UI-tested on iOS
(`StudioStoreTests`, `PerformanceUITests` — add/delete/duplicate tracks, add-clip-from-source,
playback start/stop, bounce-all). **Live mic capture and true audio sync/quality are device-only**
(permission-gated, no real sim audio); the sim tests verify the Record entry point is wired.

---

## Next

→ [Chapter 5 — Playback & Rip-on-Demand](./05-playback-and-rip-on-demand.md)
