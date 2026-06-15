import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  DEFAULT_WEIGHTS,
  camelotDistance,
  bpmDistance,
  genreDistance,
  sentimentDistance,
  artistDistance,
  harmonicDistance,
  type HarmonicWeights,
} from './harmonics';
import type { SongItem } from '../types/model';

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

// These primitives never log; still silence console to honor the house pattern.
beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
});
afterEach(() => {
  vi.restoreAllMocks();
});

// ---------------------------------------------------------------------------
// camelotDistance
// ---------------------------------------------------------------------------
describe('camelotDistance', () => {
  it('same code is 0', () => {
    expect(camelotDistance('8A', '8A')).toBe(0);
    expect(camelotDistance('12B', '12B')).toBe(0);
  });

  it('is case-insensitive and trims', () => {
    expect(camelotDistance(' 8a ', '8A')).toBe(0);
  });

  it('adjacent hour, same mode = 1', () => {
    expect(camelotDistance('8A', '9A')).toBe(1);
    expect(camelotDistance('8A', '7A')).toBe(1);
  });

  it('wraps 12<->1 (adjacent): 1A vs 12A = 1', () => {
    expect(camelotDistance('1A', '12A')).toBe(1);
    expect(camelotDistance('1B', '12B')).toBe(1);
  });

  it('relative major/minor (same hour, A<->B) = 1', () => {
    expect(camelotDistance('8A', '8B')).toBe(1);
    expect(camelotDistance('1A', '1B')).toBe(1);
  });

  it('1A vs 12B: 1 hour wrap + mode flip = 2', () => {
    expect(camelotDistance('1A', '12B')).toBe(2);
  });

  it('far same-mode = wheel-hour gap (max 6)', () => {
    expect(camelotDistance('8A', '2A')).toBe(6); // 6 hours, same mode
    expect(camelotDistance('8A', '11A')).toBe(3);
  });

  it('far + mode flip = gap + 1', () => {
    expect(camelotDistance('8A', '2B')).toBe(7); // 6 hours + mode flip
    expect(camelotDistance('8A', '11B')).toBe(4); // 3 hours + mode flip
  });

  it('returns null when either key is unparseable', () => {
    expect(camelotDistance('xx', '8A')).toBeNull();
    expect(camelotDistance('8A', 'nope')).toBeNull();
    expect(camelotDistance('13A', '8A')).toBeNull(); // out of 1..12 range
  });

  it('null-safe: null / undefined / empty -> null', () => {
    expect(camelotDistance(null, '8A')).toBeNull();
    expect(camelotDistance('8A', null)).toBeNull();
    expect(camelotDistance(undefined, undefined)).toBeNull();
    expect(camelotDistance('', '8A')).toBeNull();
    expect(camelotDistance(null, null)).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// bpmDistance
// ---------------------------------------------------------------------------
describe('bpmDistance', () => {
  it('identical tempo = 0', () => {
    expect(bpmDistance(120, 120)).toBe(0);
  });

  it('half-time / double-time folds to a tight match (70 vs 140 ~ 0)', () => {
    expect(bpmDistance(70, 140)).toBe(0);
    expect(bpmDistance(140, 70)).toBe(0);
    expect(bpmDistance(60, 120)).toBe(0);
  });

  it('folds even when not an exact multiple (125 vs 250)', () => {
    // 250 folds to 125 -> gap 0
    expect(bpmDistance(125, 250)).toBe(0);
  });

  it('small gap normalizes by ~30 BPM spread', () => {
    expect(bpmDistance(120, 125)).toBeCloseTo(5 / 30, 5);
    expect(bpmDistance(120, 135)).toBeCloseTo(15 / 30, 5);
  });

  it('clamps to 1 for a wide un-foldable gap', () => {
    // 120 vs 160: gap 40; folding 160->80 gives gap 40 too (no improvement) -> clamp 1.
    expect(bpmDistance(120, 160)).toBe(1);
  });

  it('double-time fold can beat the raw gap (120 vs 200 -> uses 100)', () => {
    // raw gap 80; fold 200->100 gives gap 20 -> 20/30
    expect(bpmDistance(120, 200)).toBeCloseTo(20 / 30, 5);
  });

  it('null-safe: null / undefined / non-positive -> null', () => {
    expect(bpmDistance(null, 120)).toBeNull();
    expect(bpmDistance(120, null)).toBeNull();
    expect(bpmDistance(undefined, 120)).toBeNull();
    expect(bpmDistance(null, null)).toBeNull();
    expect(bpmDistance(0, 120)).toBeNull();
    expect(bpmDistance(120, -10)).toBeNull();
  });

  it('non-finite (NaN / Infinity) -> null (treated like missing, never NaN)', () => {
    expect(bpmDistance(NaN, 120)).toBeNull();
    expect(bpmDistance(120, NaN)).toBeNull();
    expect(bpmDistance(NaN, NaN)).toBeNull();
    expect(bpmDistance(Infinity, 120)).toBeNull();
    expect(bpmDistance(120, -Infinity)).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// genreDistance
// ---------------------------------------------------------------------------
describe('genreDistance', () => {
  it('same top-level category = 0', () => {
    // both map to the 'soul' category
    expect(genreDistance('soul', 'Soul / Motown')).toBe(0);
    expect(genreDistance('Rock', 'indie rock')).toBe(0);
  });

  it('different category = 1', () => {
    expect(genreDistance('rock', 'soul')).toBe(1);
    expect(genreDistance('hip hop', 'classical')).toBe(1);
  });

  it('both null/empty -> same Other bucket = 0', () => {
    expect(genreDistance(null, null)).toBe(0);
    expect(genreDistance(undefined, undefined)).toBe(0);
    expect(genreDistance('', '')).toBe(0);
  });

  it('one known vs one unknown = 1', () => {
    expect(genreDistance('rock', null)).toBe(1);
    expect(genreDistance(null, 'jazz')).toBe(1);
  });

  it('is case-insensitive on the category mapping', () => {
    expect(genreDistance('JAZZ', 'bebop')).toBe(0); // both -> jazz
  });
});

// ---------------------------------------------------------------------------
// sentimentDistance
// ---------------------------------------------------------------------------
describe('sentimentDistance', () => {
  it('identical sets = 0', () => {
    expect(sentimentDistance(['love', 'joy'], ['joy', 'love'])).toBe(0);
  });

  it('1 - Jaccard for partial overlap', () => {
    // inter 1, union 2 -> 1 - 0.5 = 0.5
    expect(sentimentDistance(['love', 'joy'], ['love'])).toBeCloseTo(0.5, 5);
    // inter 1 (love), union 4 -> 1 - 1/4 = 0.75
    expect(sentimentDistance(['love', 'joy'], ['love', 'anger', 'fear'])).toBeCloseTo(0.75, 5);
  });

  it('disjoint sets = 1', () => {
    expect(sentimentDistance(['love'], ['anger'])).toBe(1);
  });

  it('case-insensitive + trimmed membership', () => {
    expect(sentimentDistance(['Love', ' Joy '], ['love', 'joy'])).toBe(0);
  });

  it('neutral 0.5 when either set is empty / missing', () => {
    expect(sentimentDistance([], ['love'])).toBe(0.5);
    expect(sentimentDistance(['love'], [])).toBe(0.5);
    expect(sentimentDistance([], [])).toBe(0.5);
    expect(sentimentDistance(undefined, ['love'])).toBe(0.5);
    expect(sentimentDistance(['love'], undefined)).toBe(0.5);
  });
});

// ---------------------------------------------------------------------------
// artistDistance
// ---------------------------------------------------------------------------
describe('artistDistance', () => {
  it('same artist (case-insensitive, trimmed) = 0', () => {
    expect(artistDistance('Daft Punk', 'daft punk')).toBe(0);
    expect(artistDistance(' Prince ', 'prince')).toBe(0);
  });

  it('different artist = 1', () => {
    expect(artistDistance('A', 'B')).toBe(1);
  });

  it('null-safe: missing/empty artists are NOT a match', () => {
    expect(artistDistance(null, null)).toBe(1);
    expect(artistDistance('', '')).toBe(1);
    expect(artistDistance(undefined, 'A')).toBe(1);
    expect(artistDistance('A', null)).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// harmonicDistance
// ---------------------------------------------------------------------------
describe('harmonicDistance', () => {
  it('identical-on-every-axis songs distance to 0', () => {
    const a = song({
      camelot: '8A',
      bpm: 120,
      genre: 'soul',
      artist: 'Prince',
      sentimentKeywords: ['love', 'joy'],
    });
    const b = song({
      camelot: '8A',
      bpm: 120,
      genre: 'soul',
      artist: 'Prince',
      sentimentKeywords: ['love', 'joy'],
    });
    expect(harmonicDistance(a, b)).toBe(0);
  });

  it('result is always in [0,1]', () => {
    const a = song({ camelot: '8A', bpm: 90, genre: 'rock', artist: 'X', sentimentKeywords: ['anger'] });
    const b = song({ camelot: '2B', bpm: 160, genre: 'classical', artist: 'Y', sentimentKeywords: ['calm'] });
    const d = harmonicDistance(a, b);
    expect(d).toBeGreaterThanOrEqual(0);
    expect(d).toBeLessThanOrEqual(1);
  });

  it('renormalizes when bpm AND key (camelot) are null on both songs', () => {
    // No audio at all: only genre/artist/sentiment axes remain.
    const a = song({ camelot: null, bpm: null, genre: 'soul', artist: 'Same', sentimentKeywords: ['love'] });
    const b = song({ camelot: null, bpm: null, genre: 'soul', artist: 'Same', sentimentKeywords: ['love'] });
    // genre 0, artist 0, sentiment 0 -> blended 0 over active weight.
    expect(harmonicDistance(a, b)).toBe(0);
  });

  it('dropped audio axes do not collapse the score toward 0', () => {
    // Same audio-less songs but DIFFERENT on every categorical axis.
    const w: HarmonicWeights = DEFAULT_WEIGHTS;
    const a = song({ camelot: null, bpm: null, genre: 'rock', artist: 'A', sentimentKeywords: ['anger'] });
    const b = song({ camelot: null, bpm: null, genre: 'jazz', artist: 'B', sentimentKeywords: ['calm'] });
    // active weights: genre .20 (dist 1) + artist .05 (dist 1) + sentiment .10 (dist 1)
    // = (.20 + .05 + .10) / (.20 + .05 + .10) = 1
    expect(harmonicDistance(a, b, w)).toBeCloseTo(1, 5);
  });

  it('renormalization matches a hand-computed blend (key present, bpm null)', () => {
    // a/b: same camelot (key dist 0), bpm null (dropped), same genre (0),
    // same artist (0), partial sentiment overlap.
    const a = song({
      camelot: '8A',
      bpm: null,
      genre: 'soul',
      artist: 'Prince',
      sentimentKeywords: ['love', 'joy'],
    });
    const b = song({
      camelot: '8A',
      bpm: null,
      genre: 'soul',
      artist: 'Prince',
      sentimentKeywords: ['love'],
    });
    // active axes: key .35*0 + genre .20*0 + artist .05*0 + sentiment .10*0.5
    // active weight = .35 + .20 + .05 + .10 = .70
    const expected = (0.1 * 0.5) / 0.7;
    expect(harmonicDistance(a, b)).toBeCloseTo(expected, 6);
  });

  it('matches a hand-computed full blend (all axes present)', () => {
    // key: 8A vs 9A -> camelot 1 / 7 = 0.142857
    // bpm: 120 vs 125 -> 5/30 = 0.166667
    // genre: soul vs rock -> 1
    // artist: X vs Y -> 1
    // sentiment: ['love'] vs ['love'] -> 0
    const a = song({ camelot: '8A', bpm: 120, genre: 'soul', artist: 'X', sentimentKeywords: ['love'] });
    const b = song({ camelot: '9A', bpm: 125, genre: 'rock', artist: 'Y', sentimentKeywords: ['love'] });
    const w = DEFAULT_WEIGHTS;
    const key = (1 / 7) * w.key;
    const bpm = (5 / 30) * w.bpm;
    const genre = 1 * w.genre;
    const artist = 1 * w.artist;
    const sentiment = 0 * w.sentiment;
    const total = w.key + w.bpm + w.genre + w.artist + w.sentiment;
    const expected = (key + bpm + genre + artist + sentiment) / total;
    expect(harmonicDistance(a, b, w)).toBeCloseTo(expected, 6);
  });

  it('a NaN bpm is dropped (renormalized), never poisoning the blend to NaN', () => {
    // Same key (8A), same genre/artist/sentiment; one bpm is NaN -> bpm axis dropped.
    const a = song({ camelot: '8A', bpm: NaN, genre: 'soul', artist: 'Same', sentimentKeywords: ['love'] });
    const b = song({ camelot: '8A', bpm: 120, genre: 'soul', artist: 'Same', sentimentKeywords: ['love'] });
    const d = harmonicDistance(a, b);
    expect(Number.isNaN(d)).toBe(false);
    expect(d).toBe(0); // all surviving axes are identical
  });

  it('returns neutral 0.5 when ALL axes are null/zero-weight', () => {
    // No audio, and zero weight on the always-present categorical axes.
    const zeroCats: HarmonicWeights = { key: 0.5, bpm: 0.5, genre: 0, artist: 0, sentiment: 0 };
    const a = song({ camelot: null, bpm: null });
    const b = song({ camelot: null, bpm: null });
    expect(harmonicDistance(a, b, zeroCats)).toBe(0.5);
  });

  it('does not mutate its inputs', () => {
    const a = song({ camelot: '8A', bpm: 120, genre: 'soul', sentimentKeywords: ['love'] });
    const b = song({ camelot: '9A', bpm: 130, genre: 'rock', sentimentKeywords: ['anger'] });
    const aSnap = JSON.parse(JSON.stringify(a));
    const bSnap = JSON.parse(JSON.stringify(b));
    harmonicDistance(a, b);
    expect(a).toEqual(aSnap);
    expect(b).toEqual(bSnap);
  });

  it('DEFAULT_WEIGHTS has the documented shape', () => {
    expect(DEFAULT_WEIGHTS).toEqual({ key: 0.35, bpm: 0.3, genre: 0.2, artist: 0.05, sentiment: 0.1 });
  });
});
