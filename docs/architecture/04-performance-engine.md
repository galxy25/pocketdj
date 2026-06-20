# Chapter 4 — Performance Engine: pockets → playlists → setlists (+ the AI seam)

> Part of the [PocketDJ Architecture Book](../ARCHITECTURE.md). Prereqs:
> [Ch. 1 Foundations](./01-foundations.md), [Ch. 3 Catalog & Data Model](./03-catalog-and-data-model.md).
> This is the **heart of the goal — "Performance Playlists Producer"** — and the
> chapter where **AI-assisted auto-mixing and auto-building will land**.

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

**Source of truth:** `src/engine/` (realize) + `src/types/collections.ts` (shapes).

**What realize does, step by step:**

```
 realize(playlist, seed):
   for each SequenceNode (chapter), in order:
     1. resolve children → flat candidate tracks
          SongNode  → the song
          AlbumNode → its trackIds, in order            (snapshot artist/bpm/camelot/len)
          PocketNode→ pocket members (recursively, DAG) tagged source:'pocket'
          TextNode  → a no-audio CUE row (isText:true)  carried verbatim
     2. if sequence has targetMs:
          • if candidates OVER budget → SAMPLE a coherent subset (seeded RNG)
          • if candidates UNDER budget → AUTOFILL with harmonic bridge tracks
                                          tagged source:'autofill'  (↔ bridge in UI)
     3. tag every track with sequenceName + provenance (explicit|pocket|autofill)
   → Setlist { seed, totalMs, tracks:[ SetlistTrack… ] }
```

**Reading the steps.** For each chapter the engine resolves its nodes into candidate
tracks — songs pass through, albums expand to their `trackIds`, pocket references
expand recursively (the DAG is walked, cycles already guarded at add-time), and
free-text cues become no-audio rows. If the chapter has a **time budget**, the engine
either **samples** an over-budget candidate set down (using the setlist's `seed` so
the take is reproducible yet fresh each Play) or **autofills** an under-budget gap
with key-matched **bridge** tracks. Every emitted `SetlistTrack` is tagged with its
`sequenceName` and `source` provenance (`explicit` / `pocket` / `autofill`), and is
**snapshotted** (artist/bpm/camelot/length stored inline) so the setlist reads
standalone even if the catalog or pockets change afterward.

The `seed` is the determinism knob: re-running `realize` with the same seed
reproduces the exact setlist; pressing Play again uses a fresh seed for a different
take.

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

## 4. The AI seam — auto-mixing & auto-building (coming)

> **Status: deferred, but the schema and engine seams already exist so lighting it
> up needs no migration.** This is the next major pillar of "Performance Playlists
> Producer."

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

## Next

→ [Chapter 5 — Playback & Rip-on-Demand](./05-playback-and-rip-on-demand.md)
