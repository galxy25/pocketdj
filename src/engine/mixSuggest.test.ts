import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { suggestMixes, suggestMixesForSetlist } from './mixSuggest';
import type { MixCtx } from './mixSuggest';
import type { SongItem } from '../types/model';
import type { Pocket, SetlistTrack } from '../types/collections';

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

let pseq = 0;
function pocket(songIds: string[], over: Partial<Pocket> = {}): Pocket {
  pseq++;
  return {
    id: over.id ?? `pkt_${pseq}`,
    name: over.name ?? `Pocket ${pseq}`,
    kind: 'harmonic',
    songIds,
    albumIds: [],
    childPocketIds: [],
    createdAt: 0,
    updatedAt: 0,
    ...over,
  };
}

function setlistTrack(songId: string, over: Partial<SetlistTrack> = {}): SetlistTrack {
  return { songId, artist: 'A', name: 'N', bpm: null, camelot: null, source: 'explicit', ...over };
}

/** Build a MixCtx; songsById is auto-derived from the union of all passed songs. */
function ctxOf(songs: SongItem[], pockets: Pocket[], candidates: SongItem[]): MixCtx {
  const byId = new Map<string, SongItem>();
  for (const s of [...songs, ...candidates]) byId.set(s.id, s);
  return { songsById: byId, pockets, candidates };
}

const idsOf = (ms: { songId: string }[]) => ms.map((m) => m.songId);

// mixSuggest emits NO transcript lines, but silence console defensively (matches
// the sibling-engine test convention).
beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
});
afterEach(() => {
  vi.restoreAllMocks();
});

// ---------------------------------------------------------------------------
describe('suggestMixes — pocket co-members (PRIMARY)', () => {
  it('gathers co-members from every pocket containing the seed, basis "pocket"', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 122, camelot: '8A' });
    const b = song({ id: 'b', bpm: 124, camelot: '9A' });
    const pk = pocket(['seed', 'a', 'b']);
    const out = suggestMixes(seed, ctxOf([seed, a, b], [pk], []));
    expect(out.every((m) => m.basis === 'pocket')).toBe(true);
    expect(out.every((m) => m.pocketId === pk.id)).toBe(true);
    expect(new Set(idsOf(out))).toEqual(new Set(['a', 'b']));
  });

  it('ranks co-members by harmonicDistance ascending (tightest first)', () => {
    // identical key+bpm+genre+artist+sentiment => distance 0; further on each axis grows it.
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A', genre: 'soul', artist: 'X', sentimentKeywords: ['warm'] });
    const tight = song({ id: 'tight', bpm: 120, camelot: '8A', genre: 'soul', artist: 'X', sentimentKeywords: ['warm'] });
    const loose = song({ id: 'loose', bpm: 200, camelot: '3B', genre: 'metal', artist: 'Z', sentimentKeywords: ['rage'] });
    const pk = pocket(['seed', 'loose', 'tight']); // loose listed before tight on purpose
    const out = suggestMixes(seed, ctxOf([seed, tight, loose], [pk], []));
    expect(idsOf(out)).toEqual(['tight', 'loose']);
    expect((out[0].score ?? 1)).toBeLessThan(out[1].score ?? 0);
  });

  it('de-dupes a co-member that appears in multiple shared pockets (first pocket wins)', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 121, camelot: '8A' });
    const pk1 = pocket(['seed', 'a'], { id: 'pkt_first' });
    const pk2 = pocket(['seed', 'a'], { id: 'pkt_second' });
    const out = suggestMixes(seed, ctxOf([seed, a], [pk1, pk2], []));
    expect(out).toHaveLength(1);
    expect(out[0].songId).toBe('a');
    expect(out[0].pocketId).toBe('pkt_first'); // first pocket in array order
  });

  it('ignores pockets that do not contain the seed', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 121, camelot: '8A' });
    const other = song({ id: 'other', bpm: 121, camelot: '8A' });
    const mine = pocket(['seed', 'a']);
    const theirs = pocket(['other']); // seed not a member
    const out = suggestMixes(seed, ctxOf([seed, a, other], [mine, theirs], []));
    expect(idsOf(out)).toEqual(['a']);
  });

  it('skips co-member ids that do not resolve in songsById (no throw)', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 121, camelot: '8A' });
    const pk = pocket(['seed', 'a', 'ghost']); // 'ghost' not in catalog
    const out = suggestMixes(seed, ctxOf([seed, a], [pk], []));
    expect(idsOf(out)).toEqual(['a']);
  });
});

describe('suggestMixes — self exclusion + dedupe', () => {
  it('never suggests the seed itself even if listed in its pocket', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 121, camelot: '8A' });
    const pk = pocket(['seed', 'a']);
    const out = suggestMixes(seed, ctxOf([seed, a], [pk], [seed, a]));
    expect(idsOf(out)).not.toContain('seed');
  });

  it('a pocket co-member is not duplicated by the bpm-key fallback', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 121, camelot: '8A' });
    const pk = pocket(['seed', 'a']);
    // 'a' is both a co-member AND in the candidate pool.
    const out = suggestMixes(seed, ctxOf([seed, a], [pk], [a]), 5);
    expect(idsOf(out)).toEqual(['a']);
  });
});

describe('suggestMixes — bpm-key fallback (FALLBACK)', () => {
  it('fills entirely from candidates when the seed is in no pocket, basis "bpm-key"', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const c1 = song({ id: 'c1', bpm: 121, camelot: '8A' }); // very close
    const c2 = song({ id: 'c2', bpm: 150, camelot: '2B' }); // far
    const out = suggestMixes(seed, ctxOf([seed], [], [c1, c2]));
    expect(out.every((m) => m.basis === 'bpm-key')).toBe(true);
    expect(out.every((m) => m.pocketId === undefined)).toBe(true);
    // ranked by camelotDistance + bpmDistance ascending -> c1 before c2
    expect(idsOf(out)).toEqual(['c1', 'c2']);
  });

  it('tops up with candidates when pocket co-members are fewer than limit', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const co = song({ id: 'co', bpm: 121, camelot: '8A' });
    const pk = pocket(['seed', 'co']); // only ONE co-member
    const fill = song({ id: 'fill', bpm: 122, camelot: '8A' });
    const out = suggestMixes(seed, ctxOf([seed, co], [pk], [fill]), 3);
    expect(idsOf(out)).toEqual(['co', 'fill']);
    expect(out[0].basis).toBe('pocket'); // pocket match first
    expect(out[1].basis).toBe('bpm-key'); // then the fill
  });

  it('pocket matches always rank ahead of bpm-key fills even when a fill is tighter', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    // co-member is musically FAR (high harmonicDistance)...
    const co = song({ id: 'co', bpm: 200, camelot: '3B', genre: 'metal' });
    const pk = pocket(['seed', 'co']);
    // ...while the candidate is a perfect bpm/key fill.
    const fill = song({ id: 'fill', bpm: 120, camelot: '8A' });
    const out = suggestMixes(seed, ctxOf([seed, co], [pk], [fill]), 5);
    expect(idsOf(out)).toEqual(['co', 'fill']); // pocket tier first regardless
    expect(out[0].basis).toBe('pocket');
    expect(out[1].basis).toBe('bpm-key');
  });

  it('skips fallback candidates with NO usable bpm/key axis (unrankable)', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const noAudio = song({ id: 'noAudio', bpm: null, camelot: null });
    const good = song({ id: 'good', bpm: 121, camelot: '8A' });
    const out = suggestMixes(seed, ctxOf([seed], [], [noAudio, good]));
    expect(idsOf(out)).toEqual(['good']); // noAudio excluded
  });
});

describe('suggestMixes — null safety', () => {
  it('ranks a partial-audio candidate on its single available axis (bpm only)', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const bpmOnly = song({ id: 'bpmOnly', bpm: 121, camelot: null }); // key missing
    const out = suggestMixes(seed, ctxOf([seed], [], [bpmOnly]));
    expect(idsOf(out)).toEqual(['bpmOnly']); // still rankable via bpm axis
  });

  it('a seed with NO audio still returns pocket co-members (harmonic axes degrade gracefully)', () => {
    const seed = song({ id: 'seed', bpm: null, camelot: null, genre: 'soul' });
    const co = song({ id: 'co', bpm: null, camelot: null, genre: 'soul' });
    const pk = pocket(['seed', 'co']);
    const out = suggestMixes(seed, ctxOf([seed, co], [pk], []));
    expect(idsOf(out)).toEqual(['co']);
    expect(out[0].basis).toBe('pocket');
    expect(typeof out[0].score).toBe('number'); // harmonicDistance never NaN/null
  });
});

describe('suggestMixes — limit', () => {
  it('respects an explicit limit across both tiers', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const co1 = song({ id: 'co1', bpm: 120, camelot: '8A' });
    const co2 = song({ id: 'co2', bpm: 121, camelot: '8A' });
    const pk = pocket(['seed', 'co1', 'co2']);
    const fills = Array.from({ length: 5 }, (_, i) => song({ id: `f${i}`, bpm: 120, camelot: '8A' }));
    const out = suggestMixes(seed, ctxOf([seed, co1, co2], [pk], fills), 3);
    expect(out).toHaveLength(3);
    expect(out.slice(0, 2).map((m) => m.basis)).toEqual(['pocket', 'pocket']);
  });

  it('defaults to 5 when no limit is given', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const fills = Array.from({ length: 9 }, (_, i) => song({ id: `f${i}`, bpm: 120 + i, camelot: '8A' }));
    const out = suggestMixes(seed, ctxOf([seed], [], fills));
    expect(out).toHaveLength(5);
  });

  it('caps pocket co-members at limit even with no fallback', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const co = Array.from({ length: 8 }, (_, i) => song({ id: `c${i}`, bpm: 120 + i, camelot: '8A' }));
    const pk = pocket(['seed', ...co.map((s) => s.id)]);
    const out = suggestMixes(seed, ctxOf([seed, ...co], [pk], []), 4);
    expect(out).toHaveLength(4);
    expect(out.every((m) => m.basis === 'pocket')).toBe(true);
  });

  it('returns empty for a non-positive limit', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const pk = pocket(['seed', 'a']);
    expect(suggestMixes(seed, ctxOf([seed, song({ id: 'a' })], [pk], []), 0)).toEqual([]);
  });
});

describe('suggestMixes — snapshot shape', () => {
  it('produces a self-contained snapshot (artist/name/bpm/camelot/lengthMs frozen)', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', artist: 'Curtis', name: 'Move On Up', bpm: 122, camelot: '9A', lengthMs: 200000 });
    const pk = pocket(['seed', 'a']);
    const [m] = suggestMixes(seed, ctxOf([seed, a], [pk], []));
    expect(m).toMatchObject({
      songId: 'a',
      artist: 'Curtis',
      name: 'Move On Up',
      bpm: 122,
      camelot: '9A',
      lengthMs: 200000,
      basis: 'pocket',
      pocketId: pk.id,
    });
    expect(typeof m.score).toBe('number');
  });

  it('derives camelot from the musical key when the camelot field is null', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 122, camelot: null, key: 'A minor' }); // 8A
    const out = suggestMixes(seed, ctxOf([seed], [], [a]));
    expect(out[0].camelot).toBe('8A');
  });

  it('snapshots null camelot when neither camelot nor key is present', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 122, camelot: null, key: null });
    const out = suggestMixes(seed, ctxOf([seed], [], [a]));
    expect(out[0].camelot).toBeNull();
  });
});

describe('suggestMixes — purity', () => {
  it('does not mutate the seed, pockets, or candidate arrays', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 121, camelot: '8A' });
    const pk = pocket(['seed', 'a']);
    const pockets = [pk];
    const candidates = [a];
    const snapPocketIds = [...pk.songIds];
    suggestMixes(seed, ctxOf([seed, a], pockets, candidates));
    expect(pk.songIds).toEqual(snapPocketIds);
    expect(pockets).toHaveLength(1);
    expect(candidates).toEqual([a]);
    expect(seed.bpm).toBe(120);
  });
});

// ---------------------------------------------------------------------------
describe('suggestMixesForSetlist', () => {
  it('returns COPIES with .mixSuggestions populated, without mutating inputs', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const a = song({ id: 'a', bpm: 121, camelot: '8A' });
    const pk = pocket(['seed', 'a']);
    const tracks = [setlistTrack('seed')];
    const out = suggestMixesForSetlist(tracks, ctxOf([seed, a], [pk], []));
    expect(out[0]).not.toBe(tracks[0]); // a copy
    expect(tracks[0].mixSuggestions).toBeUndefined(); // original untouched
    expect(idsOf(out[0].mixSuggestions ?? [])).toEqual(['a']);
  });

  it('passes through a track whose songId is missing from the catalog (copy, no suggestions)', () => {
    const tracks = [setlistTrack('ghost')];
    const out = suggestMixesForSetlist(tracks, ctxOf([], [], []));
    expect(out[0]).not.toBe(tracks[0]);
    expect(out[0].mixSuggestions).toBeUndefined();
    expect(out[0].songId).toBe('ghost');
  });

  it('honors the limit argument per track', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const fills = Array.from({ length: 6 }, (_, i) => song({ id: `f${i}`, bpm: 120 + i, camelot: '8A' }));
    const out = suggestMixesForSetlist([setlistTrack('seed')], ctxOf([seed], [], fills), 2);
    expect(out[0].mixSuggestions).toHaveLength(2);
  });

  it('preserves other track fields on the copy', () => {
    const seed = song({ id: 'seed', bpm: 120, camelot: '8A' });
    const tracks = [setlistTrack('seed', { source: 'pocket', pocketId: 'pkt_x', sequenceName: 'Warmup' })];
    const out = suggestMixesForSetlist(tracks, ctxOf([seed], [], []));
    expect(out[0]).toMatchObject({ source: 'pocket', pocketId: 'pkt_x', sequenceName: 'Warmup' });
  });
});
