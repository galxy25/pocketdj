// realize() — THE CORE of Playlists/Pockets/Setlists.
//
// Turns a Playlist TEMPLATE (an ordered tree of sequences/songs/albums/pocket
// refs) into a concrete, ordered, FROZEN performance (a Setlist's tracks):
//   - albums expand to their tracks (in order),
//   - pocket refs resolve LIVE (so edits to a pocket auto-update the next play)
//     and, when a sequence has a time budget, SAMPLE a coherent harmonic subset
//     to fit,
//   - temporal gaps under a budget are AUTOFILLED with harmonic bridge tracks
//     from the catalog (smoothing the roughest transitions first).
//
// PURE: no DB, no React, no network, no input mutation. DETERMINISTIC: all
// randomness comes from seededRng(opts.seed ?? playlist.id) so the same seed
// reproduces the exact same setlist (the seed is what `Setlist.seed` stores).
//
// Only the top-level op logs: realize() emits ONE txn('playlist.realize', …).
// The primitives it leans on (harmonics, interpolate) never log.

import type { SongItem, AlbumItem } from '../types/model';
import type {
  Playlist,
  Pocket,
  SequenceNode,
  PlaylistNode,
  SetlistTrack,
  Setlist,
  TrackSource,
} from '../types/collections';
import { isSongNode, isAlbumNode, isPocketNode, isSequenceNode, isTextNode, newSetlistId } from '../types/collections';
import { seededRng } from '../lib/prng';
import { txn } from '../lib/log';
import { harmonicDistance, DEFAULT_WEIGHTS } from './harmonics';
import type { HarmonicWeights } from './harmonics';
import { interpolatePath, nearestCandidate } from './interpolate';

// ---------------------------------------------------------------------------
// Public shapes
// ---------------------------------------------------------------------------

/** Read-only catalog + collections the realize engine resolves ids against. */
export interface RealizeCtx {
  songsById: Map<string, SongItem>;
  albumsById: Map<string, AlbumItem>;
  pocketsById: Map<string, Pocket>;
  /** Autofill pool: the full catalog of songs that have BOTH bpm AND camelot. */
  candidates: SongItem[];
}

export interface RealizeOptions {
  seed?: string;
  weights?: HarmonicWeights;
}

export interface Performance {
  tracks: SetlistTrack[];
  totalMs: number;
  stats: {
    sequences: number;
    explicit: number;
    pocketSampled: number;
    autofilled: number;
  };
}

/** Fallback per-track duration (ms) when a song carries no lengthMs. */
export const DEFAULT_TRACK_MS = 210_000;

/** Hard ceiling on autofill inserts per sequence — a safety valve against pathological pools. */
const AUTOFILL_CAP = 200;

// ---------------------------------------------------------------------------
// Internal placement record (pre-snapshot)
// ---------------------------------------------------------------------------

interface Placed {
  /** The catalog song — absent for a free-text cue (TextNode). */
  song?: SongItem;
  /** Free-text cue label (TextNode), with no backing song/audio. */
  text?: string;
  source: TrackSource;
  pocketId?: string;
  /** Name of the (sub-)sequence this track was realized in — drives the snapshot. */
  sequenceName: string;
  /** Performer note carried from the template node. */
  note?: string;
}

/** Duration a placed/candidate song contributes to the budget + totals. */
function songMs(song: SongItem): number {
  return typeof song.lengthMs === 'number' && song.lengthMs > 0 ? song.lengthMs : DEFAULT_TRACK_MS;
}

/** Duration a placement contributes — 0 for a text cue (no audio). */
function placedItemMs(p: Placed): number {
  return p.song ? songMs(p.song) : 0;
}

// ---------------------------------------------------------------------------
// Pocket resolution — flatten the pocket DAG to its effective songs
// ---------------------------------------------------------------------------

/**
 * Flatten a pocket (and its nested pockets) into its effective ordered song
 * list: own songIds, then songs of own albumIds (album.trackIds → songsById),
 * then recursively each child pocket — in that order. CYCLE-GUARDED via `seen`
 * (a set of visited pocketIds; already-seen pockets are skipped). DEDUPED by
 * songId, first-seen order preserved. Ids missing from ctx are skipped.
 */
export function resolvePocketSongs(pocketId: string, ctx: RealizeCtx, seen: Set<string> = new Set()): SongItem[] {
  const out: SongItem[] = [];
  const added = new Set<string>();
  collectPocket(pocketId, ctx, seen, out, added);
  return out;
}

function collectPocket(
  pocketId: string,
  ctx: RealizeCtx,
  seen: Set<string>,
  out: SongItem[],
  added: Set<string>,
): void {
  if (seen.has(pocketId)) return; // cycle / revisit guard
  seen.add(pocketId);
  const pocket = ctx.pocketsById.get(pocketId);
  if (!pocket) return;

  // 1. direct songs
  for (const songId of pocket.songIds) pushSong(ctx.songsById.get(songId), out, added);

  // 2. album tracks (in tracklist order)
  for (const albumId of pocket.albumIds) {
    const album = ctx.albumsById.get(albumId);
    if (!album) continue;
    for (const trackId of album.trackIds) pushSong(ctx.songsById.get(trackId), out, added);
  }

  // 3. nested pockets (recursive, sharing the same seen/out/added)
  for (const childId of pocket.childPocketIds) collectPocket(childId, ctx, seen, out, added);
}

function pushSong(song: SongItem | undefined, out: SongItem[], added: Set<string>): void {
  if (!song || added.has(song.id)) return;
  added.add(song.id);
  out.push(song);
}

// ---------------------------------------------------------------------------
// Pocket sampling + harmonic chaining
// ---------------------------------------------------------------------------

/**
 * Order a set of songs as a coherent harmonic chain anchored at `anchorIdx`,
 * then greedily nearest-neighbour by harmonicDistance. Pure; reads only the
 * provided songs. Returns a fresh array (input untouched).
 */
function harmonicChain(songs: SongItem[], anchorIdx: number, weights: HarmonicWeights): SongItem[] {
  const n = songs.length;
  if (n <= 1) return songs.slice();

  const used = new Array<boolean>(n).fill(false);
  const idx = ((anchorIdx % n) + n) % n;
  const chain: SongItem[] = [songs[idx]];
  used[idx] = true;
  let current = songs[idx];

  for (let placed = 1; placed < n; placed++) {
    let bestJ = -1;
    let bestDist = Infinity;
    for (let j = 0; j < n; j++) {
      if (used[j]) continue;
      const d = harmonicDistance(current, songs[j], weights);
      if (d < bestDist) {
        bestDist = d;
        bestJ = j;
      }
    }
    if (bestJ < 0) break; // unreachable for n>1, but keeps the loop total
    used[bestJ] = true;
    current = songs[bestJ];
    chain.push(current);
  }
  return chain;
}

/**
 * Take the prefix of a chain whose cumulative duration fits `budgetMs`. Always
 * returns ≥1 song when the chain is non-empty and budget > 0 (so a pocket never
 * contributes nothing just because its first track overshoots a tiny budget).
 */
function fitPrefix(chain: SongItem[], budgetMs: number): SongItem[] {
  if (chain.length === 0) return [];
  if (budgetMs <= 0) return [];
  const out: SongItem[] = [];
  let used = 0;
  for (const song of chain) {
    const ms = songMs(song);
    if (out.length > 0 && used + ms > budgetMs) break;
    out.push(song);
    used += ms;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Sequence realization
// ---------------------------------------------------------------------------

interface SeqResult {
  placed: Placed[];
  /** Sum of placed song durations (ms). */
  ms: number;
}

function placedMs(placed: Placed[]): number {
  let total = 0;
  for (const p of placed) total += placedItemMs(p);
  return total;
}

/**
 * Realize one sequence (chapter) into an ordered Placed list. Recurses into
 * sub-sequences. `rng` is the shared seeded stream (consumed in walk order so
 * the result is deterministic per seed). `used` tracks every songId already
 * placed anywhere in the performance (so autofill never duplicates).
 *
 * `inheritedRemainingMs` is the budget left in the PARENT sequence at the point
 * this (sub-)sequence runs (Infinity at the top level). The effective budget is
 * the smaller of this sequence's own targetMs and what the parent has left, so a
 * budgetless sub-sequence under a budgeted parent samples/prefixes to fit the
 * parent's leftover time instead of overflowing it.
 */
function realizeSequence(
  seq: SequenceNode,
  ctx: RealizeCtx,
  rng: () => number,
  weights: HarmonicWeights,
  used: Set<string>,
  inheritedRemainingMs: number = Infinity,
): SeqResult {
  const placed: Placed[] = [];
  const ownTarget = typeof seq.targetMs === 'number' && seq.targetMs > 0 ? (seq.targetMs as number) : Infinity;
  const targetMs = Math.min(ownTarget, inheritedRemainingMs);
  const hasBudget = Number.isFinite(targetMs) && targetMs > 0;

  // 1. Walk children in order; earlier blocks consume budget before later pockets sample.
  for (const node of seq.children) {
    const remaining = hasBudget ? targetMs - placedMs(placed) : Infinity;
    placeNode(node, seq.name, ctx, rng, weights, used, placed, remaining);
  }

  // 2. Autofill temporal gaps (only under a real budget that isn't yet full).
  if (hasBudget) autofill(placed, seq.name, ctx, weights, used, targetMs);

  return { placed, ms: placedMs(placed) };
}

function placeNode(
  node: PlaylistNode,
  sequenceName: string,
  ctx: RealizeCtx,
  rng: () => number,
  weights: HarmonicWeights,
  used: Set<string>,
  placed: Placed[],
  remainingMs: number,
): void {
  if (isSongNode(node)) {
    const song = ctx.songsById.get(node.songId);
    if (song) addPlaced(placed, used, { song, source: 'explicit', sequenceName, note: node.note });
    return;
  }

  if (isTextNode(node)) {
    // A free-text cue with no audio — always placed (never deduped), contributes 0ms.
    placed.push({ text: node.text, source: 'explicit', sequenceName, note: node.note });
    return;
  }

  if (isAlbumNode(node)) {
    const album = ctx.albumsById.get(node.albumId);
    if (!album) return;
    for (const trackId of album.trackIds) {
      const song = ctx.songsById.get(trackId);
      if (song) addPlaced(placed, used, { song, source: 'explicit', sequenceName });
    }
    return;
  }

  if (isPocketNode(node)) {
    const effective = resolvePocketSongs(node.pocketId, ctx);
    if (effective.length === 0) return;

    // Seeded anchor → coherent nearest-neighbour chain → (maybe) budget prefix.
    const anchorIdx = Math.floor(rng() * effective.length);
    const chain = harmonicChain(effective, anchorIdx, weights);
    const chosen = Number.isFinite(remainingMs) ? fitPrefix(chain, remainingMs) : chain;
    for (const song of chosen) {
      addPlaced(placed, used, { song, source: 'pocket', pocketId: node.pocketId, sequenceName });
    }
    return;
  }

  if (isSequenceNode(node)) {
    // Sub-sequence: realize recursively, INHERITING the parent's remaining budget
    // (the effective cap inside is min(own targetMs, remainingMs)), then concat.
    // Its placements already respect `used`.
    const sub = realizeSequence(node, ctx, rng, weights, used, remainingMs);
    for (const p of sub.placed) placed.push(p); // already deduped + used-tracked inside
    return;
  }
}

/** Append a placement unless its song is already present anywhere (dedupe by songId). */
function addPlaced(placed: Placed[], used: Set<string>, p: Placed): void {
  if (!p.song) {
    placed.push(p); // song-less (text) placements are never deduped
    return;
  }
  if (used.has(p.song.id)) return;
  used.add(p.song.id);
  placed.push(p);
}

/**
 * Fill the remaining time budget by repeatedly bridging the WORST adjacent
 * transition: rank the placed pairs (i, i+1) by harmonicDistance (worst first),
 * interpolate a midpoint target for each, and snap the nearest unused mixable
 * candidate that FITS the remaining budget onto it. The first seam that yields a
 * fitting bridge gets it inserted as an 'autofill' track; then we re-rank and go
 * again. Smooths the roughest seams first. Stops when the budget can't fit the
 * shortest remaining candidate, NO seam yields a fitting bridge, or the safety
 * cap is hit. Mutates `placed`/`used` in place (engine-internal).
 *
 * Passing `remaining` as nearestCandidate's maxMs means a single too-long
 * harmonically-closest candidate never aborts the whole fill (a shorter fitting
 * candidate, or a different seam, is used instead) — the post-pick fit check is
 * then a true invariant, not a loop-killer.
 */
function autofill(
  placed: Placed[],
  sequenceName: string,
  ctx: RealizeCtx,
  weights: HarmonicWeights,
  used: Set<string>,
  targetMs: number,
): void {
  if (placed.length < 2) return;

  for (let inserts = 0; inserts < AUTOFILL_CAP; inserts++) {
    const remaining = targetMs - placedMs(placed);
    // Shortest length among still-usable candidates — if even that won't fit, stop.
    const shortest = shortestUsableMs(ctx.candidates, used);
    if (shortest == null || remaining < shortest) break;

    // Rank seams worst-first; take the roughest one that yields a FITTING bridge.
    // Skip seams adjacent to a text cue (no song to harmonically bridge across).
    const seams: number[] = [];
    for (let i = 0; i < placed.length - 1; i++) {
      if (placed[i].song && placed[i + 1].song) seams.push(i);
    }
    seams.sort(
      (i, j) =>
        harmonicDistance(placed[j].song!, placed[j + 1].song!, weights) -
        harmonicDistance(placed[i].song!, placed[i + 1].song!, weights),
    );

    let insertedAt = -1;
    let bridgeSong: SongItem | null = null;
    for (const i of seams) {
      const target = interpolatePath(placed[i].song!, placed[i + 1].song!, 1)[0];
      if (!target) continue;
      // maxMs = remaining → only candidates that actually fit are considered.
      const bridge = nearestCandidate(target, ctx.candidates, used, weights, remaining);
      if (!bridge || used.has(bridge.id)) continue; // try the next-worst seam
      insertedAt = i;
      bridgeSong = bridge;
      break;
    }

    if (insertedAt < 0 || !bridgeSong) break; // no seam yields a fitting bridge

    placed.splice(insertedAt + 1, 0, { song: bridgeSong, source: 'autofill', sequenceName });
    used.add(bridgeSong.id);
  }
}

/** Smallest contributing duration among candidates not yet used (null if none usable). */
function shortestUsableMs(candidates: SongItem[], used: Set<string>): number | null {
  let min: number | null = null;
  for (const c of candidates) {
    if (used.has(c.id)) continue;
    if (c.bpm == null || c.camelot == null) continue; // must be mixable to ever be inserted
    const ms = songMs(c);
    if (min == null || ms < min) min = ms;
  }
  return min;
}

// ---------------------------------------------------------------------------
// Snapshot → SetlistTrack
// ---------------------------------------------------------------------------

function snapshot(p: Placed): SetlistTrack {
  if (!p.song) {
    // Free-text cue → a no-audio setlist track.
    const track: SetlistTrack = {
      songId: '',
      artist: '',
      name: p.text ?? '',
      bpm: null,
      camelot: null,
      source: p.source,
      sequenceName: p.sequenceName,
      isText: true,
    };
    if (p.note !== undefined) track.note = p.note;
    return track;
  }
  const s = p.song;
  const track: SetlistTrack = {
    songId: s.id,
    artist: s.artist,
    name: s.name,
    bpm: s.bpm,
    camelot: s.camelot ?? null,
    lengthMs: s.lengthMs,
    source: p.source,
    sequenceName: p.sequenceName,
  };
  if (p.pocketId !== undefined) track.pocketId = p.pocketId;
  if (p.note !== undefined) track.note = p.note;
  // mixSuggestions intentionally left undefined (deferred — see mixSuggest.ts).
  return track;
}

// ---------------------------------------------------------------------------
// realize()
// ---------------------------------------------------------------------------

/**
 * Realize a Playlist template into a concrete ordered Performance. Deterministic
 * per `opts.seed ?? playlist.id`. Emits exactly one txn('playlist.realize', …).
 */
export function realize(playlist: Playlist, ctx: RealizeCtx, opts: RealizeOptions = {}): Performance {
  const seed = opts.seed ?? playlist.id;
  const weights = opts.weights ?? DEFAULT_WEIGHTS;
  const rng = seededRng(seed);

  // songId used anywhere in this performance — dedupes across sequences + guards autofill.
  const used = new Set<string>();

  const tracks: SetlistTrack[] = [];
  let explicit = 0;
  let pocketSampled = 0;
  let autofilled = 0;

  for (const seq of playlist.sequences) {
    const result = realizeSequence(seq, ctx, rng, weights, used);
    for (const p of result.placed) {
      tracks.push(snapshot(p));
      if (p.source === 'explicit') explicit++;
      else if (p.source === 'pocket') pocketSampled++;
      else autofilled++;
    }
  }

  let totalMs = 0;
  for (const t of tracks) {
    if (t.isText) continue; // text cues carry no audio duration
    totalMs += typeof t.lengthMs === 'number' && t.lengthMs > 0 ? t.lengthMs : DEFAULT_TRACK_MS;
  }

  const stats = {
    sequences: playlist.sequences.length,
    explicit,
    pocketSampled,
    autofilled,
  };

  txn('playlist.realize', {
    playlistId: playlist.id,
    seed,
    sequences: stats.sequences,
    explicit: stats.explicit,
    pocketSampled: stats.pocketSampled,
    autofilled: stats.autofilled,
    totalMs,
    tracks: tracks.length,
  });

  return { tracks, totalMs, stats };
}

// ---------------------------------------------------------------------------
// buildSetlist() — realize() wrapped into a persisted Setlist instance
// ---------------------------------------------------------------------------

/**
 * Wrap realize() into a fresh Setlist (a persisted performance instance). The
 * track SELECTION inside realize is fully seeded (opts.seed ?? playlist.id); the
 * non-deterministic bits live ONLY here in the wrapper: newSetlistId() and the
 * generatedAt timestamp.
 */
export function buildSetlist(
  playlist: Playlist,
  ctx: RealizeCtx,
  opts: { seed?: string; name?: string; weights?: HarmonicWeights } = {},
): Setlist {
  const seed = opts.seed ?? playlist.id;
  const perf = realize(playlist, ctx, { seed, weights: opts.weights });
  const setlist: Setlist = {
    id: newSetlistId(),
    playlistId: playlist.id,
    seed,
    generatedAt: Date.now(),
    totalMs: perf.totalMs,
    tracks: perf.tracks,
  };
  if (opts.name !== undefined) setlist.name = opts.name;
  return setlist;
}
