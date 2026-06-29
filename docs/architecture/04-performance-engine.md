# Chapter 4 — Performance Engine: pockets → playlists → setlists (+ the Mix engine)

> Part of the [PocketDJ Architecture Book](../ARCHITECTURE.md). Prereqs:
> [Ch. 1 Foundations](./01-foundations.md), [Ch. 3 Catalog & Data Model](./03-catalog-and-data-model.md).
> This is the **heart of the goal — "Performance Playlists Producer"** — the engine
> that turns reusable templates into ordered sets, **the two-deck Mix board that
> beat-matches and mixes them live** (§7), and the chapter where **AI-assisted
> auto-building will land** (§4).

The product story for these screens is Part II of
[`STORYBOOK.md`](../STORYBOOK.md) (§18–§26). This chapter is the systems view of the
same nouns and the engine that connects them.

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
> Producer." Note the *mixing* half is no longer hypothetical — a first-party
> two-deck DJ engine with beat-matching and a timed **Auto-Mix** auto-DJ now ships
> (§7); what's still "coming" here is **AI-curated auto-*building*** of the set
> itself (a smarter `realize()` ordering + populated `mixSuggestions`).

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

---

## 5. Export — performance leaves the app

A realized setlist exports to CSV via the native OS file picker. Columns:
`#, Artist, Title, BPM, Key, Length, Source, Sequence, Note, Song ID`. The **Song ID**
lets any downstream process (notably the `burn-setlist` skill, Ch. 5) resolve each
track's audio segment in O(1). Playlists also export to a tiny
`.playlist.pocketdj.zip` that references the catalog by id (≈4 KB) or a `portable`
bundle for a foreign/empty catalog.

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
the Playlists list, **your** editable playlists also now render **above** the read-only
"From your sources" index playlists, organized into the optional collapsible
folders of [Ch. 3 §3.1](./03-catalog-and-data-model.md#31-the-collectionsdocument-envelope-schema-versioning-and-folders-native).)

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
pause ends the loop. (`autoStatus` shows "n / total · Deck X | fading".)

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
 MixSessionsView:  list → replay timeline (vertical iPhone · horizontal iPad/macOS), wall-clock replay clock
```

**Reading it.** Three additions sit on top of the engine above. **Steppers** give finer-than-drag
control on every slider. **Gain** now reaches **200%**: the 0…1 part stays on the source nodes'
documented `volume`, the >unity boost rides the deck filter EQ's `globalGain` (so it lifts the main
file *and* all four stems), and a **master peak limiter** guards the output. **Mix sessions** record
every deck action — load/play/pause/seek/tempo/pitch/volume/crossfader/effects/stems/lead/sync/reset —
into a time-stamped, persisted, replayable log that lasts until **Reset**, with played-track
checkmarks/auto-hide in the loader and a Sessions screen that replays the timeline in real time. The
recorder is a weak seam on the engine; the store keeps the high-frequency event buffer **off** the
observed surface so a live mix never redraws the UI, coalesces continuous gestures, and persists
off-main. The corpus is designed to later **train an auto-mix model** (replay is visual for now;
re-driving the decks is the follow-up). Full spec:
[Mix sessions, steppers & gain](../design/mix-sessions-and-controls-spec.md).

### 7.9 Lock-screen Now Playing · Auto-Mix Skip · slider-freeze & stem-silence fixes

```
 MixEngine.nowPlayingDeck:  exactly one deck PLAYING → that deck; else Deck A (even paused); else B; else nil
   updateSystemNowPlaying() → MPNowPlayingInfoCenter (title/artist/dur/elapsed/rate=tempo) on each transport change
 NowPlayingArbiter (single owner, last-to-PLAY wins): PlayerEngine ⇄ MixEngine share the one card +
   one MPRemoteCommandCenter; every write / command guarded by isActive(self) → no stomping
 skipToNext(fadeSeconds): reuse beginAutoCrossfade; pendingFadeRestore puts the auto fade back after a one-off skip
   Skip button (Auto only): single = settings.skipFadeSeconds (def 15) · double = 5 s  (two .onTapGesture(count:))
 DeckSeekSlider: ALWAYS read engine.position(deck) (never `scrub ?? pos`) + explicit `editing` flag → no freeze
 setStemMode(on): schedule BEFORE muting main, bail if 0 frames (clamp to maxStemSeconds) → never silent
```

**Reading it.** The Mix now feeds the **iOS/macOS lock-screen Now Playing** card — the actively-playing
deck (else Deck A) — arbitrated against the standalone `PlayerEngine` by a tiny single-owner
`NowPlayingArbiter` so the two never fight over the one system card / command center. An Auto-Mix
**Skip** button advances the queue immediately (single tap = a configurable fade, double tap = a fast
5 s sweep) by reusing the timed crossfade machine. A long-standing **slider freeze** (the seek
scrubber stopped following playback until you switched tabs) is fixed by never short-circuiting the
observed `position` read. And toggling **stem mode** after interrupting an auto-mix no longer goes
silent — the ON path schedules the stems before muting the main file and bails if nothing scheduled.
Full spec: [Lock-screen Now Playing, Skip, slider & stem fixes](../design/mix-tab-nowplaying-skip-slider-stems.md).

## Next

→ [Chapter 5 — Playback & Rip-on-Demand](./05-playback-and-rip-on-demand.md)
