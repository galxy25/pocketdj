// Harmonic-distance toolkit — the shared similarity math the realize +
// mixSuggest engines build on. PURE: no DB, no React, no network, no logging
// (only the top-level playlist.realize op logs; these primitives never do).
//
// Every distance function is NULL-SAFE: ~18% of songs have no audio analysis,
// so bpm/key/camelot are null. camelotDistance + bpmDistance return `null` when
// data is missing; the categorical axes (genre/artist/sentiment) always return a
// finite value (with a neutral default for missing data). harmonicDistance then
// DROPS any null axis and renormalizes the remaining weights, so the blended
// result always stays in [0,1] regardless of how much audio metadata exists.

import type { SongItem } from '../types/model';
import { camelotRank } from '../lib/camelot';
import { categorize } from '../starmap/constellationMap';

/** Per-axis weights for the blended harmonic distance. */
export interface HarmonicWeights {
  key: number;
  bpm: number;
  genre: number;
  artist: number;
  sentiment: number;
}

/**
 * Sensible defaults: key + bpm dominate (the DJ-mix essentials), genre shapes
 * the vibe, sentiment nudges, artist barely matters (variety > repetition).
 * Need not sum to 1 — harmonicDistance normalizes by the active weight total.
 */
export const DEFAULT_WEIGHTS: HarmonicWeights = {
  key: 0.35,
  bpm: 0.3,
  genre: 0.2,
  artist: 0.05,
  sentiment: 0.1,
};

// --- camelot helpers --------------------------------------------------------

/**
 * Decompose a Camelot rank (camelotRank: num*2 + (B?1:0)) back into its wheel
 * "hour" (1..12) and mode (A=minor, B=major). Returns null if unparseable.
 */
function camelotParts(c?: string | null): { hour: number; major: boolean } | null {
  const rank = camelotRank(c);
  if (rank == null) return null;
  // rank = hour*2 + (B?1:0). B is odd, A is even.
  const major = (rank & 1) === 1;
  const hour = rank >> 1;
  return { hour, major };
}

/** Shortest distance between two wheel hours (1..12), wrapping 12<->1. 0..6. */
function hourGap(a: number, b: number): number {
  const raw = Math.abs(a - b);
  return Math.min(raw, 12 - raw);
}

/**
 * Camelot-wheel distance in "steps" (0..7), null if either key is unparseable.
 *
 *   same code                                   -> 0
 *   adjacent hour, same mode (wraps 12<->1)     -> 1
 *   relative major/minor (same hour, A<->B)     -> 1
 *   otherwise -> shortest wheel-hour gap (0..6) + 1 if the modes differ
 *
 * (1A vs 12A == 1 proves the wrap; 8A vs 8B == 1 is the relative-key shift.)
 */
export function camelotDistance(a?: string | null, b?: string | null): number | null {
  const pa = camelotParts(a);
  const pb = camelotParts(b);
  if (!pa || !pb) return null;

  if (pa.hour === pb.hour && pa.major === pb.major) return 0; // same code

  const gap = hourGap(pa.hour, pb.hour);
  const modesDiffer = pa.major !== pb.major;

  // ±1 hour, same mode (energy-boost / -drop neighbors on the wheel).
  if (gap === 1 && !modesDiffer) return 1;
  // Relative major/minor: same hour, different mode.
  if (gap === 0 && modesDiffer) return 1;

  return gap + (modesDiffer ? 1 : 0);
}

// --- bpm ---------------------------------------------------------------------

/** Spread (in BPM) at which two tempos are considered maximally far (clamp pt). */
const BPM_SPREAD = 30;

/**
 * Tempo distance, normalized to [0,1] and null-safe. Half-/double-time aware:
 * folds `b` toward `a` by *2 or /2 as long as that shrinks the gap (so 70 vs 140
 * reads as a tight match, the classic double-time blend). Returns null if either
 * tempo is missing.
 */
export function bpmDistance(a?: number | null, b?: number | null): number | null {
  if (a == null || b == null || !Number.isFinite(a) || !Number.isFinite(b)) return null;
  if (a <= 0 || b <= 0) return null;

  let folded = b;
  let gap = Math.abs(a - folded);

  // Fold toward `a` while doubling/halving keeps shrinking the gap.
  for (let i = 0; i < 4; i++) {
    let improved = false;
    if (folded < a) {
      const up = folded * 2;
      if (Math.abs(a - up) < gap) {
        folded = up;
        gap = Math.abs(a - folded);
        improved = true;
      }
    } else if (folded > a) {
      const down = folded / 2;
      if (Math.abs(a - down) < gap) {
        folded = down;
        gap = Math.abs(a - folded);
        improved = true;
      }
    }
    if (!improved) break;
  }

  const norm = gap / BPM_SPREAD;
  return norm < 0 ? 0 : norm > 1 ? 1 : norm;
}

// --- genre -------------------------------------------------------------------

/**
 * Genre distance: 0 if both strings land in the same top-level star-map category
 * (via constellationMap.categorize), else 1. A null/empty genre categorizes to
 * the 'Other' bucket, so two ungenred items read as same-category (0) and an
 * ungenred vs genred pair reads as 1.
 */
export function genreDistance(a?: string | null, b?: string | null): number {
  const ca = categorize(a == null ? null : a.toLowerCase()).category;
  const cb = categorize(b == null ? null : b.toLowerCase()).category;
  return ca === cb ? 0 : 1;
}

// --- sentiment ---------------------------------------------------------------

/**
 * Sentiment distance = 1 - Jaccard(lowercased keyword sets). If EITHER set is
 * empty (no sentiment data), returns 0.5 — a neutral "we don't know" so missing
 * data never falsely reads as identical or maximally distant.
 */
export function sentimentDistance(a?: string[], b?: string[]): number {
  if (!a || !b || a.length === 0 || b.length === 0) return 0.5;
  const sa = new Set(a.map((s) => s.toLowerCase().trim()));
  const sb = new Set(b.map((s) => s.toLowerCase().trim()));
  let inter = 0;
  for (const x of sa) if (sb.has(x)) inter++;
  const union = sa.size + sb.size - inter;
  if (union === 0) return 0.5;
  return 1 - inter / union;
}

// --- artist ------------------------------------------------------------------

/** 0 if the same artist (case-insensitive, trimmed), else 1. */
export function artistDistance(a?: string | null, b?: string | null): number {
  const na = (a ?? '').toLowerCase().trim();
  const nb = (b ?? '').toLowerCase().trim();
  return na === nb && na.length > 0 ? 0 : 1;
}

// --- blended -----------------------------------------------------------------

/** Max camelot-step distance, used to normalize camelotDistance into [0,1]. */
const MAX_CAMELOT_STEPS = 7; // 6 hours apart + mode mismatch

/**
 * Weighted harmonic distance between two songs, in [0,1].
 *
 * Each axis is normalized to [0,1] then combined by `w`. NULL-SAFE: any axis
 * whose raw distance is null (missing bpm/key) is DROPPED and the remaining
 * weights are renormalized, so the blend never collapses toward 0 just because
 * audio data is absent. If EVERY axis is null/zero-weight, returns 0.5.
 */
export function harmonicDistance(a: SongItem, b: SongItem, w: HarmonicWeights = DEFAULT_WEIGHTS): number {
  // camelot may live on either `camelot` (preferred) or be derived elsewhere;
  // SongItem carries `camelot?: string | null`.
  const camRaw = camelotDistance(a.camelot, b.camelot);
  const bpmRaw = bpmDistance(a.bpm, b.bpm);

  const axes: Array<{ weight: number; dist: number | null }> = [
    { weight: w.key, dist: camRaw == null ? null : camRaw / MAX_CAMELOT_STEPS },
    { weight: w.bpm, dist: bpmRaw },
    { weight: w.genre, dist: genreDistance(a.genre, b.genre) },
    { weight: w.artist, dist: artistDistance(a.artist, b.artist) },
    { weight: w.sentiment, dist: sentimentDistance(a.sentimentKeywords, b.sentimentKeywords) },
  ];

  let weighted = 0;
  let activeWeight = 0;
  for (const ax of axes) {
    if (ax.dist == null || !Number.isFinite(ax.dist) || ax.weight <= 0) continue;
    weighted += ax.weight * ax.dist;
    activeWeight += ax.weight;
  }

  if (activeWeight === 0) return 0.5; // all axes missing -> neutral
  const blended = weighted / activeWeight;
  return blended < 0 ? 0 : blended > 1 ? 1 : blended;
}
