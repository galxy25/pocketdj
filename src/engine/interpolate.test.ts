import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { interpolatePath, nearestCandidate } from './interpolate';
import type { TargetPoint } from './interpolate';
import type { SongItem } from '../types/model';
import { camelotRank, CAMELOT_KEYS } from '../lib/camelot';
import type { HarmonicWeights } from './harmonics';

// nearestCandidate is tested against the REAL harmonics metrics (no mock), so
// the closeness assertions exercise the actual blend the realize engine uses.
// Scale reminder (target 8A / 120bpm / 'soul'):
//   camelotDistance: 0..7 wheel steps     (null if either key unparseable)
//   bpmDistance:     |Δbpm|/30 in [0,1]    (half/double-time folded; null if missing)
//   genreDistance:   0 same category else 1

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

// Build a full HarmonicWeights (all axes 1) with the given overrides — only
// key/bpm/genre matter to nearestCandidate, but the type requires all five.
function W(over: Partial<HarmonicWeights> = {}): HarmonicWeights {
  return { key: 1, bpm: 1, genre: 1, artist: 1, sentiment: 1, ...over };
}

// interpolatePath / nearestCandidate do not log (only realize does), but keep
// console quiet to match the suite convention.
beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
});
afterEach(() => {
  vi.restoreAllMocks();
});

// ---------------------------------------------------------------------------
describe('interpolatePath — shape & ratios', () => {
  it('returns exactly `steps` points', () => {
    const from = song({ bpm: 100, camelot: '8A', genre: 'soul' });
    const to = song({ bpm: 120, camelot: '10A', genre: 'rock' });
    expect(interpolatePath(from, to, 3)).toHaveLength(3);
    expect(interpolatePath(from, to, 1)).toHaveLength(1);
    expect(interpolatePath(from, to, 7)).toHaveLength(7);
  });

  it('ratios are (i+1)/(steps+1): strictly inside (0,1) and monotonically increasing', () => {
    const from = song({ bpm: 100, camelot: '8A' });
    const to = song({ bpm: 130, camelot: '8A' });
    const path = interpolatePath(from, to, 4);
    const ratios = path.map((p) => p.ratio);
    expect(ratios).toEqual([1 / 5, 2 / 5, 3 / 5, 4 / 5]);
    for (const r of ratios) {
      expect(r).toBeGreaterThan(0);
      expect(r).toBeLessThan(1);
    }
    for (let i = 1; i < ratios.length; i++) {
      expect(ratios[i]).toBeGreaterThan(ratios[i - 1]);
    }
  });

  it('steps <= 0 (and non-finite) yields an empty path', () => {
    const a = song({ bpm: 100, camelot: '8A' });
    const b = song({ bpm: 120, camelot: '9A' });
    expect(interpolatePath(a, b, 0)).toEqual([]);
    expect(interpolatePath(a, b, -3)).toEqual([]);
    expect(interpolatePath(a, b, NaN)).toEqual([]);
  });

  it('is pure — does not mutate either anchor', () => {
    const from = song({ bpm: 100, camelot: '8A', genre: 'soul' });
    const to = song({ bpm: 120, camelot: '10A', genre: 'rock' });
    const fromSnap = JSON.stringify(from);
    const toSnap = JSON.stringify(to);
    interpolatePath(from, to, 5);
    expect(JSON.stringify(from)).toBe(fromSnap);
    expect(JSON.stringify(to)).toBe(toSnap);
  });
});

describe('interpolatePath — BPM linear lerp', () => {
  it('lerps bpm linearly across the bridge', () => {
    // steps=3 -> ratios 1/4, 2/4, 3/4 over 100..140 -> 110, 120, 130
    const path = interpolatePath(song({ bpm: 100, camelot: '8A' }), song({ bpm: 140, camelot: '8A' }), 3);
    expect(path.map((p) => p.bpm)).toEqual([110, 120, 130]);
  });

  it('handles a descending bpm ramp', () => {
    const path = interpolatePath(song({ bpm: 128, camelot: '8A' }), song({ bpm: 120, camelot: '8A' }), 1);
    expect(path[0].bpm).toBe(124); // ratio 1/2 of 128..120
  });

  it('bpm is null when EITHER anchor has null bpm', () => {
    const fromNull = interpolatePath(song({ bpm: null, camelot: '8A' }), song({ bpm: 120, camelot: '8A' }), 2);
    expect(fromNull.every((p) => p.bpm === null)).toBe(true);
    const toNull = interpolatePath(song({ bpm: 120, camelot: '8A' }), song({ bpm: null, camelot: '8A' }), 2);
    expect(toNull.every((p) => p.bpm === null)).toBe(true);
  });
});

describe('interpolatePath — Camelot stepping along the shorter arc', () => {
  it('steps toward the target through intermediate wheel slots (same letter band)', () => {
    // 8A (rank idx 14) -> 12A (idx 22): forward delta +8, steps 5 -> ratios 1/6..5/6
    // rounded steps: round(8*r) = 1,3,4,5,7 -> idx 15,17,18,19,21 -> 9A,11A,11B?,...
    const path = interpolatePath(song({ bpm: 100, camelot: '8A' }), song({ bpm: 100, camelot: '12A' }), 5);
    const idxOf = (c: string | null) => CAMELOT_KEYS.indexOf(c as string);
    const idxs = path.map((p) => idxOf(p.camelot));
    // Monotonic non-decreasing toward the target index (22), never overshooting.
    for (let i = 1; i < idxs.length; i++) expect(idxs[i]).toBeGreaterThanOrEqual(idxs[i - 1]);
    expect(idxs[idxs.length - 1]).toBeLessThanOrEqual(CAMELOT_KEYS.indexOf('12A'));
    // Last step (ratio 5/6, delta 8 -> round 6.67 = 7) lands near the target.
    expect(path[path.length - 1].camelot).toBe('11B');
  });

  it('takes the SHORTER arc when wrapping the wheel is closer (1A near 12B)', () => {
    // from 1B (idx 1) to 12A (idx 22). Forward = 21, backward = 3. Shorter = backward 3 slots.
    // So points should move DOWN/wrap (1B -> 1A -> 12B ...), not up through 2A,3A,...
    const path = interpolatePath(song({ bpm: 100, camelot: '1B' }), song({ bpm: 100, camelot: '12A' }), 2);
    // ratios 1/3, 2/3 with shorter delta -3: round(-1) = -1, round(-2) = -2
    // fromIdx 1 -> 0 (1A) and -1 -> wrap to 23 (12B)
    expect(path.map((p) => p.camelot)).toEqual(['1A', '12B']);
  });

  it('camelot is null when EITHER anchor has null/unparseable camelot', () => {
    const a = interpolatePath(song({ bpm: 100, camelot: null }), song({ bpm: 100, camelot: '8A' }), 3);
    expect(a.every((p) => p.camelot === null)).toBe(true);
    const b = interpolatePath(song({ bpm: 100, camelot: '8A' }), song({ bpm: 100, camelot: 'ZZ' }), 3);
    expect(b.every((p) => p.camelot === null)).toBe(true);
  });

  it('endpoints used for stepping line up with camelotRank (sanity on the ranks)', () => {
    // Guard against rank/offset drift between camelot.ts and our stepping math.
    expect(camelotRank('1A')).toBe(2);
    expect(camelotRank('12B')).toBe(25);
    expect(CAMELOT_KEYS).toHaveLength(24);
  });
});

describe('interpolatePath — genre category crossfade', () => {
  it("uses from's category before ratio < 0.5, to's category at/after 0.5", () => {
    // steps=3 -> ratios .25, .5, .75 -> from, to, to
    const path = interpolatePath(
      song({ bpm: 100, camelot: '8A', genre: 'soul' }),
      song({ bpm: 100, camelot: '8A', genre: 'rock' }),
      3,
    );
    expect(path.map((p) => p.category)).toEqual(['soul', 'rock', 'rock']);
  });

  it('unknown / empty genre surfaces as a null category on the relevant side', () => {
    const path = interpolatePath(
      song({ bpm: 100, camelot: '8A', genre: undefined }),
      song({ bpm: 100, camelot: '8A', genre: '' }),
      2,
    );
    // both sides unknown -> null categories throughout
    expect(path.map((p) => p.category)).toEqual([null, null]);
  });
});

describe('nearestCandidate', () => {
  const target: TargetPoint = { bpm: 120, camelot: '8A', category: 'soul', ratio: 0.5 };

  it('picks the closest eligible candidate (camelot+bpm+genre blend)', () => {
    const near = song({ id: 'near', bpm: 121, camelot: '8A', genre: 'soul' }); // cam0 + ~0.03 + 0
    const far = song({ id: 'far', bpm: 140, camelot: '2B', genre: 'rock' }); //   cam7 + ~0.67 + 1
    const mid = song({ id: 'mid', bpm: 126, camelot: '9A', genre: 'soul' }); //   cam1 + 0.2  + 0
    const pick = nearestCandidate(target, [far, mid, near], new Set());
    expect(pick?.id).toBe('near');
  });

  it('respects `used` — skips already-placed candidates', () => {
    const near = song({ id: 'near', bpm: 120, camelot: '8A', genre: 'soul' });
    const next = song({ id: 'next', bpm: 122, camelot: '8A', genre: 'soul' });
    const used = new Set<string>(['near']);
    const pick = nearestCandidate(target, [near, next], used);
    expect(pick?.id).toBe('next');
  });

  it('skips candidates missing bpm or camelot (not beat/key mixable)', () => {
    const noBpm = song({ id: 'noBpm', bpm: null, camelot: '8A', genre: 'soul' });
    const noKey = song({ id: 'noKey', bpm: 120, camelot: null, genre: 'soul' });
    const ok = song({ id: 'ok', bpm: 130, camelot: '9A', genre: 'rock' });
    const pick = nearestCandidate(target, [noBpm, noKey, ok], new Set());
    expect(pick?.id).toBe('ok');
  });

  it('returns null when no eligible candidate exists', () => {
    const allUsed = nearestCandidate(target, [song({ id: 'a', bpm: 120, camelot: '8A' })], new Set(['a']));
    expect(allUsed).toBeNull();
    const allUnmixable = nearestCandidate(
      target,
      [song({ id: 'b', bpm: null, camelot: '8A' }), song({ id: 'c', bpm: 120, camelot: null })],
      new Set(),
    );
    expect(allUnmixable).toBeNull();
    expect(nearestCandidate(target, [], new Set())).toBeNull();
  });

  it('ties resolve to the first candidate in input order (deterministic)', () => {
    const a = song({ id: 'a', bpm: 120, camelot: '8A', genre: 'soul' });
    const b = song({ id: 'b', bpm: 120, camelot: '8A', genre: 'soul' }); // identical score
    expect(nearestCandidate(target, [a, b], new Set())?.id).toBe('a');
    expect(nearestCandidate(target, [b, a], new Set())?.id).toBe('b');
  });

  it('weights re-balance the axes (heavy bpm weight flips the pick)', () => {
    // aKey: perfect key, off tempo -> cam 0, bpm 12/30=0.4, gen 0.
    // bBpm: off key (3 hours), on tempo -> cam 3, bpm 0, gen 0.
    const aKey = song({ id: 'aKey', bpm: 132, camelot: '8A', genre: 'soul' });
    const bBpm = song({ id: 'bBpm', bpm: 120, camelot: '11A', genre: 'soul' });
    // Default weights (1,1,1): A=0.4, B=3.0 -> the tighter KEY wins (A).
    expect(nearestCandidate(target, [aKey, bBpm], new Set())?.id).toBe('aKey');
    // Heavy bpm weight: A=20*0.4=8.0, B=3.0 -> flips to the on-tempo B.
    expect(
      nearestCandidate(target, [aKey, bBpm], new Set(), W({ bpm: 20 }))?.id,
    ).toBe('bBpm');
  });

  it('drops a null axis: a target with no key ranks purely on bpm+genre', () => {
    const noKeyTarget: TargetPoint = { bpm: 120, camelot: null, category: 'soul', ratio: 0.5 };
    // camelotDistance(null, …) is null -> dropped. So the wildly-off key on `b`
    // costs nothing; the closer TEMPO wins instead.
    const a = song({ id: 'a', bpm: 150, camelot: '8A', genre: 'soul' }); // bpm 30/30=1.0
    const b = song({ id: 'b', bpm: 121, camelot: '2B', genre: 'soul' }); // bpm ~0.03, key ignored
    expect(nearestCandidate(noKeyTarget, [a, b], new Set())?.id).toBe('b');
  });

  it('drops a null axis: a target with no tempo ranks purely on key+genre', () => {
    const noBpmTarget: TargetPoint = { bpm: null, camelot: '8A', category: 'soul', ratio: 0.5 };
    const a = song({ id: 'a', bpm: 200, camelot: '8A', genre: 'soul' }); // cam 0, bpm ignored
    const b = song({ id: 'b', bpm: 120, camelot: '4B', genre: 'soul' }); // cam large, bpm ignored
    expect(nearestCandidate(noBpmTarget, [a, b], new Set())?.id).toBe('a');
  });

  it('does not mutate the `used` set or candidate list', () => {
    const used = new Set<string>(['x']);
    const cands = [song({ id: 'a', bpm: 120, camelot: '8A', genre: 'soul' })];
    const snapUsed = [...used];
    const snapIds = cands.map((c) => c.id);
    nearestCandidate(target, cands, used);
    expect([...used]).toEqual(snapUsed);
    expect(cands.map((c) => c.id)).toEqual(snapIds);
  });

  it('maxMs skips candidates that are too long, returning the closest FITTING one', () => {
    // `near` is the harmonically closest but is too long; `next` fits the cap.
    const near = song({ id: 'near', bpm: 120, camelot: '8A', genre: 'soul', lengthMs: 300_000 });
    const next = song({ id: 'next', bpm: 122, camelot: '8A', genre: 'soul', lengthMs: 100_000 });
    // Without a cap, the closest (`near`) wins.
    expect(nearestCandidate(target, [near, next], new Set())?.id).toBe('near');
    // With maxMs = 150_000, `near` (300s) is excluded; `next` (100s) is chosen.
    expect(nearestCandidate(target, [near, next], new Set(), undefined, 150_000)?.id).toBe('next');
  });

  it('maxMs uses DEFAULT_CANDIDATE_MS for candidates without a positive lengthMs', () => {
    // No lengthMs -> treated as 210_000ms; a 150_000 cap excludes it.
    const noLen = song({ id: 'noLen', bpm: 120, camelot: '8A', genre: 'soul' });
    expect(nearestCandidate(target, [noLen], new Set(), undefined, 150_000)).toBeNull();
    // A cap above the default admits it.
    expect(nearestCandidate(target, [noLen], new Set(), undefined, 250_000)?.id).toBe('noLen');
  });

  it('returns null when every fitting-by-harmony candidate exceeds maxMs', () => {
    const a = song({ id: 'a', bpm: 120, camelot: '8A', genre: 'soul', lengthMs: 400_000 });
    const b = song({ id: 'b', bpm: 121, camelot: '8A', genre: 'soul', lengthMs: 500_000 });
    expect(nearestCandidate(target, [a, b], new Set(), undefined, 100_000)).toBeNull();
  });
});
