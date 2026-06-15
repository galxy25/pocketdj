// Harmonic INTERPOLATION — build a gradient "bridge" of target points between
// two anchor songs, then snap catalog songs onto those points.
//
// realize()'s autofill uses this to splice smooth transitions into temporal gaps:
// given a `from` and `to` anchor, interpolatePath() lays down N intermediate
// TARGET POINTS (a linear BPM ramp + a step around the Camelot wheel along the
// SHORTER arc + a genre-category crossfade), and nearestCandidate() picks the
// real catalog song closest to each target.
//
// PURE + DETERMINISTIC: no mutation, no randomness, no DB/React/network. All
// distance work delegates to ./harmonics (the single source of truth for the
// camelot/bpm/genre metrics), so this module just lays out the geometry.

import type { SongItem } from '../types/model';
import { camelotRank, CAMELOT_KEYS } from '../lib/camelot';
import { categorize } from '../starmap/constellationMap';
import { camelotDistance, bpmDistance, genreDistance } from './harmonics';
import type { HarmonicWeights } from './harmonics';

/**
 * Duration (ms) a candidate contributes when inserted — mirrors realize.ts's
 * songMs so the `maxMs` fit check here is identical to autofill's post-pick check
 * (a song with no positive lengthMs falls back to DEFAULT_CANDIDATE_MS).
 */
export const DEFAULT_CANDIDATE_MS = 210_000;
function candidateMs(song: SongItem): number {
  return typeof song.lengthMs === 'number' && song.lengthMs > 0 ? song.lengthMs : DEFAULT_CANDIDATE_MS;
}

/** One sampled point along the bridge between two anchors. */
export interface TargetPoint {
  /** Linear-interpolated BPM (null when either anchor has no BPM). */
  bpm: number | null;
  /** Camelot code stepped toward the target along the shorter arc (null when either anchor lacks one). */
  camelot: string | null;
  /** Genre top-level CATEGORY in force at this point (from's before ratio<0.5, else to's; null if unknown). */
  category: string | null;
  /** Position along the bridge, in (0,1). */
  ratio: number;
}

/** Number of contiguous wheel positions (1A..12B == 24). */
const WHEEL = CAMELOT_KEYS.length; // 24

/**
 * Step from rank `fromRank` toward `toRank` around the 24-slot Camelot wheel by
 * `ratio`, choosing the SHORTER direction. Returns the destination Camelot code.
 *
 * Ranks come from camelotRank (A=even, B=odd, contiguous: 1A=2 … 12B=25), so we
 * normalise to a 0..23 index, walk the shorter signed arc, wrap, and map back
 * through CAMELOT_KEYS.
 */
function stepCamelot(fromRank: number, toRank: number, ratio: number): string {
  // camelotRank returns num*2 + (B?1:0); the lowest value is 1A === 2. Shift to 0-based.
  const fromIdx = fromRank - 2;
  const toIdx = toRank - 2;
  // Forward distance around the wheel, then pick the shorter signed delta.
  let delta = (toIdx - fromIdx) % WHEEL;
  if (delta < 0) delta += WHEEL; // 0..WHEEL-1
  if (delta > WHEEL / 2) delta -= WHEEL; // shorter arc: -WHEEL/2 .. WHEEL/2
  // Round to a discrete wheel slot at this ratio (deterministic; .5 rounds up).
  const stepped = fromIdx + Math.round(delta * ratio);
  const idx = ((stepped % WHEEL) + WHEEL) % WHEEL; // wrap into 0..WHEEL-1
  return CAMELOT_KEYS[idx];
}

/**
 * Build `steps` target points bridging two anchor songs.
 *
 * For point i (0-based): ratio = (i+1)/(steps+1) — evenly spaced, strictly
 * inside (0,1), monotonically increasing.
 *  - bpm: linear lerp(from.bpm, to.bpm); null if EITHER anchor's bpm is null.
 *  - camelot: from.camelot stepped toward to.camelot along the shorter wheel arc
 *    by ratio; null if EITHER anchor's camelot is null/unparseable.
 *  - category: from's genre category while ratio < 0.5, else to's (null if the
 *    relevant anchor's category is unknown / Other-less; categorize never throws).
 *
 * Pure + deterministic. `steps <= 0` yields an empty path.
 */
export function interpolatePath(from: SongItem, to: SongItem, steps: number): TargetPoint[] {
  if (!Number.isFinite(steps) || steps <= 0) return [];

  const fromBpm = from.bpm;
  const toBpm = to.bpm;
  const bpmOk = typeof fromBpm === 'number' && typeof toBpm === 'number';

  const fromRank = camelotRank(from.camelot);
  const toRank = camelotRank(to.camelot);
  const wheelOk = fromRank != null && toRank != null;

  const fromCategory = categoryOf(from.genre);
  const toCategory = categoryOf(to.genre);

  const out: TargetPoint[] = [];
  for (let i = 0; i < steps; i++) {
    const ratio = (i + 1) / (steps + 1);
    out.push({
      bpm: bpmOk ? fromBpm + (toBpm - fromBpm) * ratio : null,
      camelot: wheelOk ? stepCamelot(fromRank, toRank, ratio) : null,
      category: ratio < 0.5 ? fromCategory : toCategory,
      ratio,
    });
  }
  return out;
}

/**
 * Resolve a raw genre string to its top-level category, or null when unknown.
 * categorize() always returns a category; we surface the Other bucket as null so
 * callers (and genreDistance) treat "no usable genre" uniformly.
 */
function categoryOf(genre: string | undefined | null): string | null {
  const cat = categorize(genre).category;
  return cat === 'Other' ? null : cat;
}

/**
 * Pick the catalog song closest to `target`.
 *
 * Eligibility: not already in `used`, and BOTH bpm and camelot present (autofill
 * bridges must be beat/key-mixable, so a candidate missing either is skipped).
 * Score = wKey·camelotDistance(target.camelot, c.camelot)
 *       + wBpm·bpmDistance(target.bpm, c.bpm)
 *       + wGenre·genreDistance(target.category, c.genre).
 *
 * The camelot/bpm axes are NULL-SAFE per harmonics (they return null when the
 * target itself carries no key/tempo — e.g. an anchor lacked audio); a null axis
 * is DROPPED so it never poisons the blend (a null camelot target then ranks
 * purely on bpm+genre, etc.). genreDistance is always finite. Axis weights come
 * from HarmonicWeights.key / .bpm / .genre and DEFAULT to 1 each, so the bare
 * call reproduces the contract's `camelotDistance + bpmDistance + genreDistance`
 * sum; passing `weights` only re-balances. Weighting lives here so harmonics owns
 * the metrics and interpolate owns the geometry + mixing.
 *
 * Deterministic: ties resolve to the FIRST candidate encountered (stable input
 * order). Returns null when no eligible candidate exists.
 *
 * `maxMs` (optional) caps the candidate's duration: any candidate whose songMs
 * exceeds it is skipped, so the returned bridge is the closest *fitting* song.
 * autofill passes the remaining budget here so its post-pick fit check is a true
 * invariant (never the closest-but-too-long song) — see realize.ts.
 */
export function nearestCandidate(
  target: TargetPoint,
  candidates: SongItem[],
  used: Set<string>,
  weights?: HarmonicWeights,
  maxMs?: number,
): SongItem | null {
  const wKey = weights?.key ?? 1;
  const wBpm = weights?.bpm ?? 1;
  const wGenre = weights?.genre ?? 1;
  const cap = typeof maxMs === 'number' && Number.isFinite(maxMs) ? maxMs : Infinity;

  let best: SongItem | null = null;
  let bestScore = Infinity;
  for (const c of candidates) {
    if (used.has(c.id)) continue;
    if (c.bpm == null || c.camelot == null) continue; // must be beat+key mixable
    if (candidateMs(c) > cap) continue; // skip candidates that won't fit the budget

    const cam = camelotDistance(target.camelot, c.camelot); // number | null
    const bpm = bpmDistance(target.bpm, c.bpm); // number | null
    const gen = genreDistance(target.category, c.genre); // always finite

    let score = wGenre * gen;
    if (cam != null) score += wKey * cam; // drop the axis when the target has no key
    if (bpm != null) score += wBpm * bpm; // drop the axis when the target has no tempo

    if (score < bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return best;
}
