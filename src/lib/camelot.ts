// Camelot-wheel (DJ harmonic) key ordering.
//
// Camelot notation is "<num><letter>": num 1..12, letter A (minor) or B (major),
// e.g. "2B", "11A". DJ-meaningful order groups harmonically-related keys: order
// by number (1..12), then letter (A before B). Null/empty/unparseable values are
// reported as `null` so callers can push them last.

/**
 * Returns a comparable rank for a Camelot key, or `null` if it can't be parsed.
 * A=even, B=odd (contiguous), so a simple numeric compare yields the wheel order
 * (1A, 1B, 2A, 2B, …, 12A, 12B).
 */
export function camelotRank(c?: string | null): number | null {
  if (!c) return null;
  const m = /^(\d{1,2})([AB])$/i.exec(c.trim());
  if (!m) return null;
  const num = parseInt(m[1], 10);
  if (num < 1 || num > 12) return null;
  return num * 2 + (m[2].toUpperCase() === 'B' ? 1 : 0); // A=even, B=odd, contiguous
}

/**
 * A color for a Camelot key — the 12 wheel positions map to 12 hues around the circle;
 * B (major) reads brighter, A (minor) deeper. Returns null for unparseable keys (so the
 * caller can fall back to a neutral look). This is what tints the Key-mode grid cells.
 */
export function camelotColor(c?: string | null): string | null {
  const m = /^(\d{1,2})([AB])$/i.exec((c || '').trim());
  if (!m) return null;
  const num = parseInt(m[1], 10);
  if (num < 1 || num > 12) return null;
  const hue = Math.round(((num - 1) / 12) * 360);
  const major = m[2].toUpperCase() === 'B';
  return `hsl(${hue} 68% ${major ? 50 : 38}%)`;
}

// Standard Mixed-In-Key musical-name → Camelot map (both sharp + flat spellings).
const MUSICAL_TO_CAMELOT: Record<string, string> = {
  'G# minor': '1A', 'Ab minor': '1A', 'B major': '1B',
  'D# minor': '2A', 'Eb minor': '2A', 'F# major': '2B', 'Gb major': '2B',
  'A# minor': '3A', 'Bb minor': '3A', 'C# major': '3B', 'Db major': '3B',
  'F minor': '4A', 'G# major': '4B', 'Ab major': '4B',
  'C minor': '5A', 'D# major': '5B', 'Eb major': '5B',
  'G minor': '6A', 'A# major': '6B', 'Bb major': '6B',
  'D minor': '7A', 'F major': '7B',
  'A minor': '8A', 'C major': '8B',
  'E minor': '9A', 'G major': '9B',
  'B minor': '10A', 'D major': '10B',
  'F# minor': '11A', 'Gb minor': '11A', 'A major': '11B',
  'C# minor': '12A', 'Db minor': '12A', 'E major': '12B',
};

/** Convert a musical key name ("A minor", "D# major") to its Camelot code, or null. */
export function keyToCamelot(key?: string | null): string | null {
  if (!key) return null;
  return MUSICAL_TO_CAMELOT[key.trim()] ?? null;
}

// ---- valid-value lists + reverse map (for the edit-modal key dropdowns) ----

/** All 24 Camelot codes in wheel order: 1A, 1B, 2A, … 12B. */
export const CAMELOT_KEYS: string[] = Array.from({ length: 12 }, (_, i) => i + 1).flatMap((n) => [
  `${n}A`,
  `${n}B`,
]);

/** The 24 canonical musical keys (sharp spellings, matching the audio analyzer), pitch-ordered. */
const NOTES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
export const MUSICAL_KEYS: string[] = [
  ...NOTES.map((n) => `${n} minor`),
  ...NOTES.map((n) => `${n} major`),
];

const CAMELOT_TO_KEY: Record<string, string> = {
  '1A': 'G# minor', '1B': 'B major', '2A': 'D# minor', '2B': 'F# major',
  '3A': 'A# minor', '3B': 'C# major', '4A': 'F minor', '4B': 'G# major',
  '5A': 'C minor', '5B': 'D# major', '6A': 'G minor', '6B': 'A# major',
  '7A': 'D minor', '7B': 'F major', '8A': 'A minor', '8B': 'C major',
  '9A': 'E minor', '9B': 'G major', '10A': 'B minor', '10B': 'D major',
  '11A': 'F# minor', '11B': 'A major', '12A': 'C# minor', '12B': 'E major',
};

/** Convert a Camelot code ("8A") to its canonical musical key name, or null. */
export function camelotToKey(code?: string | null): string | null {
  if (!code) return null;
  return CAMELOT_TO_KEY[code.trim()] ?? null;
}
