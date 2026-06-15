import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  realize,
  buildSetlist,
  resolvePocketSongs,
  DEFAULT_TRACK_MS,
  type RealizeCtx,
} from './realize';
import type { SongItem, AlbumItem } from '../types/model';
import type { Playlist, Pocket, SequenceNode, PlaylistNode } from '../types/collections';

// ---- fixtures -------------------------------------------------------------
let seq = 0;
function song(over: Partial<SongItem> = {}): SongItem {
  seq++;
  return {
    id: over.id ?? `sng_${seq}`,
    sourceId: 's1',
    type: 'song',
    createdAt: 0,
    updatedAt: 0,
    artist: 'Artist',
    name: 'Name',
    sentimentKeywords: [],
    explicit: false,
    bpm: null,
    key: null,
    ...over,
  };
}
function album(over: Partial<AlbumItem> = {}): AlbumItem {
  seq++;
  return {
    id: over.id ?? `alb_${seq}`,
    sourceId: 's1',
    type: 'album',
    createdAt: 0,
    updatedAt: 0,
    artist: 'Artist',
    name: 'Name',
    trackIds: [],
    ...over,
  };
}
function pocket(over: Partial<Pocket> = {}): Pocket {
  seq++;
  return {
    id: over.id ?? `pkt_${seq}`,
    name: 'P',
    kind: 'harmonic',
    songIds: [],
    albumIds: [],
    childPocketIds: [],
    createdAt: 0,
    updatedAt: 0,
    ...over,
  };
}

// Node builders.
let nodeSeq = 0;
const nid = () => `nd_${++nodeSeq}`;
const songNode = (songId: string): PlaylistNode => ({ nodeId: nid(), kind: 'song', songId });
const albumNode = (albumId: string): PlaylistNode => ({ nodeId: nid(), kind: 'album', albumId });
const pocketNode = (pocketId: string): PlaylistNode => ({ nodeId: nid(), kind: 'pocket', pocketId });
function sequenceNode(name: string, children: PlaylistNode[], targetMs?: number): SequenceNode {
  return { nodeId: nid(), kind: 'sequence', name, targetMs, children };
}
function playlist(sequences: SequenceNode[], over: Partial<Playlist> = {}): Playlist {
  seq++;
  return {
    id: over.id ?? `pls_${seq}`,
    name: 'PL',
    sequences,
    createdAt: 0,
    updatedAt: 0,
    ...over,
  };
}

/** Build a RealizeCtx from arrays; candidates default to songs with bpm AND camelot. */
function ctxOf(opts: {
  songs?: SongItem[];
  albums?: AlbumItem[];
  pockets?: Pocket[];
  candidates?: SongItem[];
}): RealizeCtx {
  const songs = opts.songs ?? [];
  return {
    songsById: new Map(songs.map((s) => [s.id, s])),
    albumsById: new Map((opts.albums ?? []).map((a) => [a.id, a])),
    pocketsById: new Map((opts.pockets ?? []).map((p) => [p.id, p])),
    candidates: opts.candidates ?? songs.filter((s) => s.bpm != null && s.camelot != null),
  };
}

const trackIds = (p: { tracks: { songId: string }[] }) => p.tracks.map((t) => t.songId);

// Silence the PDJ_API transcript line emitted by realize.
beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
});
afterEach(() => {
  vi.restoreAllMocks();
});

// ---------------------------------------------------------------------------
describe('resolvePocketSongs', () => {
  it('flattens own songs + album tracks in order, deduping', () => {
    const s1 = song({ id: 's1' });
    const s2 = song({ id: 's2' });
    const s3 = song({ id: 's3' });
    const alb = album({ id: 'a1', trackIds: ['s2', 's3'] }); // s2 also a direct song -> dedupe
    const pkt = pocket({ id: 'p1', songIds: ['s1', 's2'], albumIds: ['a1'] });
    const ctx = ctxOf({ songs: [s1, s2, s3], albums: [alb], pockets: [pkt] });

    expect(resolvePocketSongs('p1', ctx).map((s) => s.id)).toEqual(['s1', 's2', 's3']);
  });

  it('flattens NESTED pockets (child songs after parent, deduped across levels)', () => {
    const s1 = song({ id: 's1' });
    const s2 = song({ id: 's2' });
    const s3 = song({ id: 's3' });
    const child = pocket({ id: 'child', songIds: ['s2', 's3'] });
    const parent = pocket({ id: 'parent', songIds: ['s1', 's2'], childPocketIds: ['child'] });
    const ctx = ctxOf({ songs: [s1, s2, s3], pockets: [parent, child] });

    // s1, s2 (parent), then child contributes s3 (s2 already added).
    expect(resolvePocketSongs('parent', ctx).map((s) => s.id)).toEqual(['s1', 's2', 's3']);
  });

  it('CYCLE (A->B->A) terminates and returns each song once', () => {
    const s1 = song({ id: 's1' });
    const s2 = song({ id: 's2' });
    const a = pocket({ id: 'A', songIds: ['s1'], childPocketIds: ['B'] });
    const b = pocket({ id: 'B', songIds: ['s2'], childPocketIds: ['A'] }); // back-edge
    const ctx = ctxOf({ songs: [s1, s2], pockets: [a, b] });

    const out = resolvePocketSongs('A', ctx);
    expect(out.map((s) => s.id)).toEqual(['s1', 's2']); // A then B; A revisit skipped
  });

  it('skips ids missing from ctx (songs and albums)', () => {
    const s1 = song({ id: 's1' });
    const pkt = pocket({ id: 'p1', songIds: ['s1', 'gone'], albumIds: ['noalbum'] });
    const ctx = ctxOf({ songs: [s1], pockets: [pkt] });
    expect(resolvePocketSongs('p1', ctx).map((s) => s.id)).toEqual(['s1']);
  });

  it('unknown pocketId resolves to empty', () => {
    expect(resolvePocketSongs('nope', ctxOf({})).length).toBe(0);
  });
});

// ---------------------------------------------------------------------------
describe('realize — explicit nodes', () => {
  it('a song node places that song with source "explicit" and snapshots fields', () => {
    const s = song({
      id: 's1',
      artist: 'Daft Punk',
      name: 'One More Time',
      bpm: 123,
      camelot: '8B',
      lengthMs: 200_000,
    });
    const ctx = ctxOf({ songs: [s] });
    const pl = playlist([sequenceNode('Default', [songNode('s1')])]);

    const perf = realize(pl, ctx);
    expect(perf.tracks).toHaveLength(1);
    const t = perf.tracks[0];
    expect(t).toMatchObject({
      songId: 's1',
      artist: 'Daft Punk',
      name: 'One More Time',
      bpm: 123,
      camelot: '8B',
      lengthMs: 200_000,
      source: 'explicit',
      sequenceName: 'Default',
    });
    expect(t.pocketId).toBeUndefined();
    expect(t.mixSuggestions).toBeUndefined();
    expect(perf.stats.explicit).toBe(1);
  });

  it('camelot snapshots to null when the song has none', () => {
    const s = song({ id: 's1', bpm: 120 }); // no camelot
    const ctx = ctxOf({ songs: [s] });
    const perf = realize(playlist([sequenceNode('Default', [songNode('s1')])]), ctx);
    expect(perf.tracks[0].camelot).toBeNull();
  });

  it('album node expands to its trackIds IN ORDER, missing ids skipped', () => {
    const t1 = song({ id: 't1' });
    const t3 = song({ id: 't3' });
    const alb = album({ id: 'a1', trackIds: ['t1', 't2_missing', 't3'] });
    const ctx = ctxOf({ songs: [t1, t3], albums: [alb] });
    const perf = realize(playlist([sequenceNode('Default', [albumNode('a1')])]), ctx);

    expect(trackIds(perf)).toEqual(['t1', 't3']);
    expect(perf.tracks.every((t) => t.source === 'explicit')).toBe(true);
  });

  it('missing song node is skipped (no track)', () => {
    const ctx = ctxOf({ songs: [] });
    const perf = realize(playlist([sequenceNode('Default', [songNode('gone')])]), ctx);
    expect(perf.tracks).toHaveLength(0);
  });

  it('dedupes a song repeated across nodes (first placement wins)', () => {
    const s = song({ id: 's1' });
    const ctx = ctxOf({ songs: [s] });
    const perf = realize(playlist([sequenceNode('Default', [songNode('s1'), songNode('s1')])]), ctx);
    expect(trackIds(perf)).toEqual(['s1']);
  });
});

// ---------------------------------------------------------------------------
describe('realize — totals + budgeting', () => {
  it('totalMs uses lengthMs, falling back to DEFAULT_TRACK_MS', () => {
    const withLen = song({ id: 's1', lengthMs: 100_000 });
    const noLen = song({ id: 's2' }); // -> DEFAULT_TRACK_MS
    const ctx = ctxOf({ songs: [withLen, noLen] });
    const perf = realize(playlist([sequenceNode('Default', [songNode('s1'), songNode('s2')])]), ctx);
    expect(perf.totalMs).toBe(100_000 + DEFAULT_TRACK_MS);
  });
});

// ---------------------------------------------------------------------------
describe('realize — pocket sampling to budget', () => {
  // 5 mixable songs of 100s each; a budget that fits ~2 -> prefix of 2.
  const pocketSongs = () =>
    ['p1', 'p2', 'p3', 'p4', 'p5'].map((id, i) =>
      song({ id, bpm: 120 + i, camelot: '8A', genre: 'house', lengthMs: 100_000 }),
    );

  it('over-budget pocket returns the prefix that fits (<= budget, >= 1)', () => {
    const songs = pocketSongs();
    const pkt = pocket({ id: 'p', songIds: songs.map((s) => s.id) });
    const ctx = ctxOf({ songs, pockets: [pkt], candidates: [] }); // no autofill pool
    // 250s budget; songs 100s each -> 2 fit (200s), a 3rd would exceed.
    const pl = playlist([sequenceNode('Vibes', [pocketNode('p')], 250_000)]);
    const perf = realize(pl, ctx);

    const pocketTracks = perf.tracks.filter((t) => t.source === 'pocket');
    expect(pocketTracks).toHaveLength(2);
    expect(perf.totalMs).toBeLessThanOrEqual(250_000);
    expect(pocketTracks.every((t) => t.pocketId === 'p')).toBe(true);
  });

  it('always returns >= 1 pocket song when budget > 0 even if the first overshoots', () => {
    const big = song({ id: 'big', bpm: 120, camelot: '8A', lengthMs: 999_000 });
    const pkt = pocket({ id: 'p', songIds: ['big'] });
    const ctx = ctxOf({ songs: [big], pockets: [pkt], candidates: [] });
    const perf = realize(playlist([sequenceNode('S', [pocketNode('p')], 10_000)]), ctx);
    expect(perf.tracks.filter((t) => t.source === 'pocket')).toHaveLength(1);
  });

  it('no budget -> takes ALL pocket songs (full chain)', () => {
    const songs = pocketSongs();
    const pkt = pocket({ id: 'p', songIds: songs.map((s) => s.id) });
    const ctx = ctxOf({ songs, pockets: [pkt], candidates: [] });
    const perf = realize(playlist([sequenceNode('S', [pocketNode('p')])]), ctx); // no targetMs
    expect(perf.tracks.filter((t) => t.source === 'pocket')).toHaveLength(5);
    expect(perf.stats.pocketSampled).toBe(5);
  });
});

// ---------------------------------------------------------------------------
describe('realize — determinism', () => {
  // A pocket large enough that the seeded anchor/sampling actually varies.
  function bigPocketCtx() {
    const songs = Array.from({ length: 12 }, (_, i) =>
      song({
        id: `q${i}`,
        bpm: 100 + i * 4,
        camelot: i % 2 === 0 ? '8A' : '5B',
        genre: i % 3 === 0 ? 'house' : 'techno',
        lengthMs: 100_000,
      }),
    );
    const pkt = pocket({ id: 'p', songIds: songs.map((s) => s.id) });
    return ctxOf({ songs, pockets: [pkt], candidates: [] });
  }
  const overBudget = playlist([sequenceNode('S', [pocketNode('p')], 350_000)], { id: 'pls_fixed' });

  it('same seed -> identical track order', () => {
    const ctx = bigPocketCtx();
    const a = realize(overBudget, ctx, { seed: 'seedX' });
    const b = realize(overBudget, ctx, { seed: 'seedX' });
    expect(trackIds(a)).toEqual(trackIds(b));
  });

  it('different seed -> generally different pocket sample/anchor', () => {
    const ctx = bigPocketCtx();
    const seeds = ['s0', 's1', 's2', 's3', 's4', 's5', 's6', 's7'];
    const orders = seeds.map((s) => trackIds(realize(overBudget, ctx, { seed: s })).join(','));
    // Not all 8 seeds collapse to the same order.
    expect(new Set(orders).size).toBeGreaterThan(1);
  });

  it('seed defaults to playlist.id when opts.seed is omitted (reproducible)', () => {
    const ctx = bigPocketCtx();
    const a = realize(overBudget, ctx);
    const b = realize(overBudget, ctx, { seed: 'pls_fixed' });
    expect(trackIds(a)).toEqual(trackIds(b));
  });
});

// ---------------------------------------------------------------------------
describe('realize — autofill', () => {
  it('inserts autofill bridge song(s) between two far-apart anchors under a budget', () => {
    // Anchor A: slow rock in one key; Anchor B: fast jazz in a far key -> huge seam.
    const a = song({ id: 'A', bpm: 90, camelot: '1A', genre: 'rock', lengthMs: 100_000 });
    const b = song({ id: 'B', bpm: 160, camelot: '7B', genre: 'jazz', lengthMs: 100_000 });
    // A mid candidate that bridges (between in bpm/key/genre).
    const bridge = song({ id: 'bridge', bpm: 125, camelot: '4A', genre: 'rock', lengthMs: 100_000 });
    const ctx = ctxOf({ songs: [a, b, bridge], candidates: [bridge] });

    // 350s budget: 2 anchors = 200s, room for one ~100s bridge.
    const pl = playlist([sequenceNode('S', [songNode('A'), songNode('B')], 350_000)]);
    const perf = realize(pl, ctx);

    const sources = perf.tracks.map((t) => t.source);
    expect(sources).toContain('autofill');
    // Bridge inserted BETWEEN the two anchors.
    expect(trackIds(perf)).toEqual(['A', 'bridge', 'B']);
    expect(perf.stats.autofilled).toBe(1);
  });

  it('does not duplicate an already-placed song and stays within budget + one track', () => {
    const a = song({ id: 'A', bpm: 90, camelot: '1A', genre: 'rock', lengthMs: 100_000 });
    const b = song({ id: 'B', bpm: 160, camelot: '7B', genre: 'jazz', lengthMs: 100_000 });
    const c1 = song({ id: 'c1', bpm: 120, camelot: '4A', genre: 'rock', lengthMs: 100_000 });
    const c2 = song({ id: 'c2', bpm: 130, camelot: '5A', genre: 'pop', lengthMs: 100_000 });
    // A and B are themselves valid candidates — must never be re-inserted.
    const ctx = ctxOf({ songs: [a, b, c1, c2], candidates: [a, b, c1, c2] });
    const pl = playlist([sequenceNode('S', [songNode('A'), songNode('B')], 1_000_000)]);
    const perf = realize(pl, ctx);

    const all = trackIds(perf);
    expect(new Set(all).size).toBe(all.length); // no duplicates
    expect(all.filter((id) => id === 'A')).toHaveLength(1);
    expect(all.filter((id) => id === 'B')).toHaveLength(1);
    // Budget is large; total must still respect it (we never exceed targetMs by inserting).
    expect(perf.totalMs).toBeLessThanOrEqual(1_000_000);
  });

  it('no autofill without a budget even with far-apart anchors', () => {
    const a = song({ id: 'A', bpm: 90, camelot: '1A', genre: 'rock', lengthMs: 100_000 });
    const b = song({ id: 'B', bpm: 160, camelot: '7B', genre: 'jazz', lengthMs: 100_000 });
    const bridge = song({ id: 'bridge', bpm: 125, camelot: '4A', genre: 'rock', lengthMs: 100_000 });
    const ctx = ctxOf({ songs: [a, b, bridge], candidates: [bridge] });
    const perf = realize(playlist([sequenceNode('S', [songNode('A'), songNode('B')])]), ctx);
    expect(trackIds(perf)).toEqual(['A', 'B']); // budget-less = no fill
  });

  it('does not autofill when the budget cannot fit any candidate', () => {
    const a = song({ id: 'A', bpm: 90, camelot: '1A', genre: 'rock', lengthMs: 100_000 });
    const b = song({ id: 'B', bpm: 160, camelot: '7B', genre: 'jazz', lengthMs: 100_000 });
    const bridge = song({ id: 'bridge', bpm: 125, camelot: '4A', genre: 'rock', lengthMs: 100_000 });
    const ctx = ctxOf({ songs: [a, b, bridge], candidates: [bridge] });
    // Budget == exactly the two anchors; no room for the 100s bridge.
    const perf = realize(playlist([sequenceNode('S', [songNode('A'), songNode('B')], 200_000)]), ctx);
    expect(trackIds(perf)).toEqual(['A', 'B']);
  });

  it('does not abort the fill when the closest bridge is too long — uses a shorter fitting one', () => {
    // Far-apart anchors. The harmonically-closest candidate to the seam target is
    // LONG and won't fit the remaining budget; a slightly-less-close candidate is
    // SHORT and fits. The old code picked the long one and broke the whole loop,
    // leaving the seam unbridged. The fix should insert the short fitting bridge.
    const a = song({ id: 'A', bpm: 90, camelot: '1A', genre: 'rock', lengthMs: 100_000 });
    const b = song({ id: 'B', bpm: 160, camelot: '7B', genre: 'jazz', lengthMs: 100_000 });
    // closestLong: best harmonic match to the midpoint (bpm 125, ~4A, rock) but 300s.
    const closestLong = song({ id: 'closestLong', bpm: 125, camelot: '4A', genre: 'rock', lengthMs: 300_000 });
    // shortFit: a worse-but-decent match, and it fits the budget.
    const shortFit = song({ id: 'shortFit', bpm: 120, camelot: '5A', genre: 'rock', lengthMs: 90_000 });
    const ctx = ctxOf({ songs: [a, b, closestLong, shortFit], candidates: [closestLong, shortFit] });
    // Budget 300s: anchors = 200s, 100s left. closestLong (300s) can't fit; shortFit (90s) can.
    const perf = realize(playlist([sequenceNode('S', [songNode('A'), songNode('B')], 300_000)]), ctx);

    expect(trackIds(perf)).toEqual(['A', 'shortFit', 'B']);
    expect(perf.stats.autofilled).toBe(1);
    expect(perf.totalMs).toBeLessThanOrEqual(300_000);
  });

  it('fills multiple seams with varied-length candidates, never exceeding the budget', () => {
    // Two far seams; pool has mixed lengths. Autofill should keep inserting fitting
    // bridges (worst seam first) until the budget is too tight, all within target.
    const a = song({ id: 'A', bpm: 90, camelot: '1A', genre: 'rock', lengthMs: 100_000 });
    const b = song({ id: 'B', bpm: 160, camelot: '7B', genre: 'jazz', lengthMs: 100_000 });
    const c = song({ id: 'C', bpm: 95, camelot: '2A', genre: 'rock', lengthMs: 100_000 });
    const cands = [
      song({ id: 'k1', bpm: 125, camelot: '4A', genre: 'rock', lengthMs: 250_000 }), // too long early on
      song({ id: 'k2', bpm: 120, camelot: '5A', genre: 'rock', lengthMs: 80_000 }),
      song({ id: 'k3', bpm: 100, camelot: '3A', genre: 'rock', lengthMs: 90_000 }),
      song({ id: 'k4', bpm: 110, camelot: '4B', genre: 'pop', lengthMs: 95_000 }),
    ];
    const ctx = ctxOf({ songs: [a, b, c, ...cands], candidates: cands });
    const target = 700_000;
    const perf = realize(
      playlist([sequenceNode('S', [songNode('A'), songNode('B'), songNode('C')], target)]),
      ctx,
    );

    // At least one bridge was inserted (the loop did not abort early on a too-long pick).
    expect(perf.stats.autofilled).toBeGreaterThanOrEqual(1);
    expect(perf.totalMs).toBeLessThanOrEqual(target);
    // No duplicates.
    const ids = trackIds(perf);
    expect(new Set(ids).size).toBe(ids.length);
  });
});

// ---------------------------------------------------------------------------
describe('realize — sub-sequences', () => {
  it('a sub-sequence concatenates its tracks, tagged with its OWN sequence name', () => {
    const s1 = song({ id: 's1' });
    const s2 = song({ id: 's2' });
    const ctx = ctxOf({ songs: [s1, s2] });
    const inner = sequenceNode('Inner', [songNode('s2')]);
    const pl = playlist([sequenceNode('Outer', [songNode('s1'), inner])]);
    const perf = realize(pl, ctx);

    expect(trackIds(perf)).toEqual(['s1', 's2']);
    expect(perf.tracks[0].sequenceName).toBe('Outer');
    expect(perf.tracks[1].sequenceName).toBe('Inner');
  });

  it('a BUDGETLESS sub-sequence inherits the parent budget (pocket prefixes to fit, no overflow)', () => {
    // Parent budget 600s. Sub-sequence has NO targetMs; its only child is a pocket
    // of 20 mixable 100s songs. Without inheritance the sub realizes ALL 20 (2000s,
    // 3.3x the parent). With inheritance it prefixes the pocket to the parent's
    // leftover time (<= 600s).
    const songs = Array.from({ length: 20 }, (_, i) =>
      song({ id: `g${i}`, bpm: 120 + i, camelot: '8A', genre: 'house', lengthMs: 100_000 }),
    );
    const pkt = pocket({ id: 'p', songIds: songs.map((s) => s.id) });
    const ctx = ctxOf({ songs, pockets: [pkt], candidates: [] });

    const sub = sequenceNode('Sub', [pocketNode('p')]); // no targetMs
    const pl = playlist([sequenceNode('Parent', [sub], 600_000)]);
    const perf = realize(pl, ctx);

    // 600s / 100s = 6 pocket tracks max; must not blow past the parent budget.
    const pocketTracks = perf.tracks.filter((t) => t.source === 'pocket');
    expect(pocketTracks.length).toBeLessThanOrEqual(6);
    expect(pocketTracks.length).toBeGreaterThanOrEqual(1);
    expect(perf.totalMs).toBeLessThanOrEqual(600_000);
  });

  it("a sub-sequence's own (smaller) budget still caps it below the inherited budget", () => {
    // Parent 600s leftover, sub targetMs 250s -> effective cap is min = 250s -> 2 tracks.
    const songs = Array.from({ length: 20 }, (_, i) =>
      song({ id: `h${i}`, bpm: 120 + i, camelot: '8A', genre: 'house', lengthMs: 100_000 }),
    );
    const pkt = pocket({ id: 'p', songIds: songs.map((s) => s.id) });
    const ctx = ctxOf({ songs, pockets: [pkt], candidates: [] });

    const sub = sequenceNode('Sub', [pocketNode('p')], 250_000);
    const pl = playlist([sequenceNode('Parent', [sub], 600_000)]);
    const perf = realize(pl, ctx);

    expect(perf.tracks.filter((t) => t.source === 'pocket')).toHaveLength(2);
    expect(perf.totalMs).toBeLessThanOrEqual(250_000);
  });

  it('earlier siblings consume the parent budget the sub-sequence then inherits', () => {
    // Parent 400s. A song (100s) runs first, leaving 300s for the budgetless sub.
    const lead = song({ id: 'lead', lengthMs: 100_000 });
    const songs = Array.from({ length: 20 }, (_, i) =>
      song({ id: `j${i}`, bpm: 120 + i, camelot: '8A', genre: 'house', lengthMs: 100_000 }),
    );
    const pkt = pocket({ id: 'p', songIds: songs.map((s) => s.id) });
    const ctx = ctxOf({ songs: [lead, ...songs], pockets: [pkt], candidates: [] });

    const sub = sequenceNode('Sub', [pocketNode('p')]); // no targetMs
    const pl = playlist([sequenceNode('Parent', [songNode('lead'), sub], 400_000)]);
    const perf = realize(pl, ctx);

    // 100s lead + at most 300s of pocket (3 tracks) <= 400s.
    expect(perf.tracks.filter((t) => t.source === 'pocket').length).toBeLessThanOrEqual(3);
    expect(perf.totalMs).toBeLessThanOrEqual(400_000);
  });
});

// ---------------------------------------------------------------------------
describe('realize — auto-update semantics (pockets resolved LIVE)', () => {
  it('adding a songId to the ctx pocket and re-realizing yields more pocket tracks', () => {
    const s1 = song({ id: 's1', bpm: 120, camelot: '8A', lengthMs: 100_000 });
    const s2 = song({ id: 's2', bpm: 121, camelot: '8A', lengthMs: 100_000 });
    const pkt = pocket({ id: 'p', songIds: ['s1'] });
    const ctx = ctxOf({ songs: [s1, s2], pockets: [pkt], candidates: [] });
    const pl = playlist([sequenceNode('S', [pocketNode('p')])]); // no budget -> all

    const before = realize(pl, ctx);
    expect(before.tracks.filter((t) => t.source === 'pocket')).toHaveLength(1);

    // Mutate the catalog pocket (lazy ref -> picked up on next realize).
    pkt.songIds = ['s1', 's2'];
    const after = realize(pl, ctx);
    expect(after.tracks.filter((t) => t.source === 'pocket')).toHaveLength(2);
    expect(trackIds(after)).toContain('s2');
  });
});

// ---------------------------------------------------------------------------
describe('realize — purity + transcript', () => {
  it('does not mutate the input playlist or ctx maps', () => {
    const s = song({ id: 's1' });
    const ctx = ctxOf({ songs: [s] });
    const pl = playlist([sequenceNode('Default', [songNode('s1')])]);
    const snapshotPl = JSON.parse(JSON.stringify(pl));
    realize(pl, ctx);
    expect(JSON.parse(JSON.stringify(pl))).toEqual(snapshotPl);
    expect(ctx.songsById.size).toBe(1); // unchanged
  });

  it('emits exactly one playlist.realize transcript line with stats', () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    const s = song({ id: 's1', lengthMs: 100_000 });
    const ctx = ctxOf({ songs: [s] });
    realize(playlist([sequenceNode('Default', [songNode('s1')])], { id: 'pls_log' }), ctx, { seed: 'k' });

    expect(log).toHaveBeenCalledTimes(1);
    const line = log.mock.calls[0][0] as string;
    expect(line.startsWith('PDJ_API ')).toBe(true);
    const payload = JSON.parse(line.slice('PDJ_API '.length));
    expect(payload.op).toBe('playlist.realize');
    expect(payload.playlistId).toBe('pls_log');
    expect(payload.seed).toBe('k');
    expect(payload.sequences).toBe(1);
    expect(payload.explicit).toBe(1);
    expect(payload.tracks).toBe(1);
    expect(payload.totalMs).toBe(100_000);
  });
});

// ---------------------------------------------------------------------------
describe('buildSetlist', () => {
  it('wraps realize() into a Setlist with id, playlistId, seed, totals + tracks', () => {
    const s = song({ id: 's1', lengthMs: 100_000 });
    const ctx = ctxOf({ songs: [s] });
    const pl = playlist([sequenceNode('Default', [songNode('s1')])], { id: 'pls_X' });

    const set = buildSetlist(pl, ctx, { seed: 'k', name: 'BBQ — take 1' });
    expect(set.id.startsWith('set_')).toBe(true);
    expect(set.playlistId).toBe('pls_X');
    expect(set.seed).toBe('k');
    expect(set.name).toBe('BBQ — take 1');
    expect(set.totalMs).toBe(100_000);
    expect(set.tracks.map((t) => t.songId)).toEqual(['s1']);
    expect(typeof set.generatedAt).toBe('number');
  });

  it('seed defaults to playlist.id; same seed reproduces identical tracks', () => {
    const songs = Array.from({ length: 10 }, (_, i) =>
      song({ id: `z${i}`, bpm: 100 + i * 3, camelot: '8A', genre: 'house', lengthMs: 100_000 }),
    );
    const pkt = pocket({ id: 'p', songIds: songs.map((s) => s.id) });
    const ctx = ctxOf({ songs, pockets: [pkt], candidates: [] });
    const pl = playlist([sequenceNode('S', [pocketNode('p')], 350_000)], { id: 'pls_seeddef' });

    const set = buildSetlist(pl, ctx); // seed defaults to playlist.id
    expect(set.seed).toBe('pls_seeddef');
    const again = realize(pl, ctx, { seed: 'pls_seeddef' });
    expect(set.tracks.map((t) => t.songId)).toEqual(again.tracks.map((t) => t.songId));
  });

  it('omits name when not provided', () => {
    const s = song({ id: 's1' });
    const ctx = ctxOf({ songs: [s] });
    const set = buildSetlist(playlist([sequenceNode('Default', [songNode('s1')])]), ctx);
    expect(set.name).toBeUndefined();
  });
});
