// Star-map SONG grouping for the BPM / KEY "nebula" modes. Pure, renderer- and
// React-agnostic. Owned by the ARCHITECT.
//
// In BPM and KEY modes the star map does NOT place one star per album or per
// song. Instead it groups ALL SONGS into a handful of CONSTELLATIONS (a bpm
// range, or a key) and renders each as a hazy NEBULA (see computeNebulaLayout in
// ./layout.ts). This module owns ONLY the grouping: songs -> an ordered list of
// constellation descriptors, each carrying the browser FILTER that selects
// exactly its songs (so "click a nebula" can pre-filter the browser table).
//
//   - 'bpm': bucket = floor(bpm / 10) * 10. Labels like "120–130", ordered
//     ascending. Null/non-finite bpm -> a single "Unknown" constellation, LAST.
//     filter = { field:'bpm', op:'between', min:start, max:start+10 }.
//   - 'key' + 'camelot': group by `camelot` (label e.g. "8A"), ordered by the
//     camelot wheel (camelotRank). filter = { field:'camelot', op:'eq', value }.
//   - 'key' + 'musical': group by `key` (label e.g. "A minor"), ordered by pitch
//     then minor-before-major. filter = { field:'key', op:'eq', value }.
//     Null/unparseable key -> a single "Unknown" constellation, LAST. The Unknown
//     constellation carries NO filter (there is no clean predicate for "missing").
//
// GENRE mode is unchanged and is NOT handled here — it stays album-based and
// two-tier in ./layout.ts (computeLayout).
import type { SongItem } from '../types/model';
import { camelotRank } from '../lib/camelot';

/** Grouping mode for the star map. (Genre is handled separately in layout.ts.) */
export type GroupBy = 'genre' | 'bpm' | 'key';
/** Key notation used when groupBy === 'key'. */
export type KeyNotation = 'camelot' | 'musical';

/** Stable id/label used for songs whose audio rollup is missing (sorted last). */
export const UNKNOWN_LABEL = 'Unknown';

/**
 * The browser filter that selects a constellation's songs. Mirrors a FilterClause
 * (src/types/filter.ts) minus the runtime `id`. The integrate agent feeds this
 * straight into useBrowserStore (addClause + updateClause) so clicking a nebula
 * opens the browser pre-filtered to that constellation:
 *
 *   - bpm  -> { field: 'bpm', op: 'between', min: start, max: start + 10 }
 *   - key  -> { field: 'camelot' | 'key', op: 'eq', value }
 *
 * BPM bounds: a decade bucket is the half-open range [start, start+10) — grouping
 * uses floor(bpm/10)*10, so a song at exactly start+10 belongs to the NEXT bucket.
 * We emit min = start, max = start + 10. The browser's `between` is inclusive on
 * both ends; the only double-count would be a song whose bpm equals an exact
 * decade boundary (e.g. 130.0), which grouping already floors into the upper
 * bucket, so the table and the nebula stay consistent in practice.
 */
export type ConstellationFilter =
  | { field: 'bpm'; op: 'between'; min: number; max: number }
  | { field: 'camelot' | 'key'; op: 'eq'; value: string };

/**
 * One ordered constellation (a bpm range or a key). The layout module turns each
 * into a nebula; the integrate agent turns `filter` into a browser filter on
 * click. `id` is the stable grouping/test/seed id; `label` is displayed.
 */
export interface Constellation {
  /** Stable grouping key: seed for the nebula + data-testid suffix + cache id. */
  id: string;
  /** Human display label (e.g. "120–130", "8A", "A minor", "Unknown"). */
  label: string;
  /** Number of songs in this constellation (drives the nebula size + caption). */
  songCount: number;
  /**
   * Browser filter that selects exactly these songs, or `null` for the catch-all
   * "Unknown" constellation (missing bpm/key has no clean predicate, so clicking
   * it is a no-op / the integrate agent may leave the filter unchanged).
   */
  filter: ConstellationFilter | null;
}

// ---------------------------------------------------------------------------
// BPM
// ---------------------------------------------------------------------------

/** Decade bucket start for a BPM value, e.g. 124 -> 120. */
export function bpmBucketStart(bpm: number): number {
  return Math.floor(bpm / 10) * 10;
}

/** Display label for a BPM decade bucket, e.g. 120 -> "120–130". */
export function bpmBucketLabel(start: number): string {
  return `${start}–${start + 10}`;
}

// ---------------------------------------------------------------------------
// KEY — musical-notation pitch ordering
// ---------------------------------------------------------------------------

// Chromatic pitch index 0..11 (C..B). Sharps and their enharmonic flats map to
// the same index so "A# minor" and "Bb minor" sort together.
const PITCH_INDEX: Record<string, number> = {
  c: 0,
  'c#': 1,
  db: 1,
  d: 2,
  'd#': 3,
  eb: 3,
  e: 4,
  fb: 4,
  'e#': 5,
  f: 5,
  'f#': 6,
  gb: 6,
  g: 7,
  'g#': 8,
  ab: 8,
  a: 9,
  'a#': 10,
  bb: 10,
  b: 11,
  cb: 11,
};

/**
 * Parse a musical key string like "A minor" / "F# major" / "Bb Major" into a
 * comparable rank: pitchIndex * 2 + (minor ? 0 : 1) so within a pitch class
 * MINOR sorts before MAJOR, and pitches order chromatically C..B. Returns null
 * for unparseable / unknown values (callers push those last).
 */
export function musicalKeyRank(key?: string | null): number | null {
  if (!key) return null;
  const m = /^\s*([a-gA-G][#b]?)\s+(major|minor|maj|min)\s*$/.exec(key);
  if (!m) return null;
  const pitch = PITCH_INDEX[m[1].toLowerCase()];
  if (pitch == null) return null;
  const quality = m[2].toLowerCase();
  const isMinor = quality === 'minor' || quality === 'min';
  return pitch * 2 + (isMinor ? 0 : 1);
}

// ---------------------------------------------------------------------------
// groupSongs — the single entry point
// ---------------------------------------------------------------------------

interface Accum {
  id: string;
  label: string;
  rank: number;
  songCount: number;
  filter: ConstellationFilter | null;
}

/**
 * Group SONGS into ordered constellations for the requested audio mode. Returns
 * a flat, ORDERED list (display order); the layout module packs them as nebulae
 * in this order. Every song lands in exactly one constellation (including the
 * catch-all "Unknown", appended LAST when present).
 *
 *   - groupBy 'bpm': decade buckets, ascending; filter = bpm BETWEEN start..start+10.
 *   - groupBy 'key' + keyNotation 'camelot': by `camelot`, camelot-wheel order;
 *     filter = camelot EQ value.
 *   - groupBy 'key' + keyNotation 'musical': by `key`, pitch order;
 *     filter = key EQ value.
 *
 * `keyNotation` is ignored when groupBy === 'bpm'. Throws on groupBy 'genre'
 * (genre is album-based + two-tier; handled by computeLayout, not here) so a
 * miswire is caught loudly rather than silently empty.
 */
export function groupSongs(
  songs: SongItem[],
  groupBy: Exclude<GroupBy, 'genre'>,
  keyNotation: KeyNotation = 'camelot',
): Constellation[] {
  if (groupBy !== 'bpm' && groupBy !== 'key') {
    throw new Error(`groupSongs: unsupported groupBy "${groupBy as string}"`);
  }

  const known = new Map<string, Accum>();
  let unknownCount = 0;

  const bump = (
    id: string,
    make: () => Omit<Accum, 'songCount'>,
  ): void => {
    let entry = known.get(id);
    if (!entry) {
      entry = { ...make(), songCount: 0 };
      known.set(id, entry);
    }
    entry.songCount++;
  };

  for (const s of songs) {
    if (groupBy === 'bpm') {
      const bpm = s.bpm;
      if (bpm == null || !isFinite(bpm)) {
        unknownCount++;
        continue;
      }
      const start = bpmBucketStart(bpm);
      const id = String(start);
      bump(id, () => ({
        id,
        label: bpmBucketLabel(start),
        rank: start,
        filter: { field: 'bpm', op: 'between', min: start, max: start + 10 },
      }));
      continue;
    }

    // groupBy === 'key'
    const value = keyNotation === 'camelot' ? s.camelot : s.key;
    const rank = keyNotation === 'camelot' ? camelotRank(value) : musicalKeyRank(value);
    if (value == null || value.length === 0 || rank == null) {
      unknownCount++;
      continue;
    }
    bump(value, () => ({
      id: value,
      label: value,
      rank,
      filter:
        keyNotation === 'camelot'
          ? { field: 'camelot', op: 'eq', value }
          : { field: 'key', op: 'eq', value },
    }));
  }

  const constellations: Constellation[] = [...known.values()]
    .sort((a, b) => a.rank - b.rank || a.id.localeCompare(b.id))
    .map((e) => ({ id: e.id, label: e.label, songCount: e.songCount, filter: e.filter }));

  if (unknownCount > 0) {
    constellations.push({
      id: UNKNOWN_LABEL,
      label: UNKNOWN_LABEL,
      songCount: unknownCount,
      filter: null,
    });
  }

  return constellations;
}
