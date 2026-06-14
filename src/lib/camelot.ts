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
