// timbre-hygiene — the ONE predicate that decides whether a stored timbre row is usable at all.
//
// Deliberately separate from anything that knows the RAILS. Hygiene asks "is this fourteen finite
// numbers or is it wreckage", which is true or false in any calibration; the rails ask "what do
// those numbers mean", which is not. Keeping them apart is what lets this ship without the
// recalibration it was written alongside.
//
// Mirrored in three more places, because a reader must not depend on the writer's discipline:
//   · apple/PocketDJ/…/SimilarityFamilies.isUsableTimbreRow  (device decode)
//   · scripts/lambda/rec-engine/index.mjs                     (server scoring)
//   · .claude/skills/analog-indexer/audio/analyze-timbre.py   (extraction, `degenerate-axes`)
export const TIMBRE_AXES = ['bright', 'brightVar', 'air', 'width', 'noisy', 'fizz', 'punch',
                            'busy', 'dynamic', 'loud', 'm1', 'm2', 'm3', 'm4'];
/// Below this many finite axes a vector is not comparable to anything — half a vector is a
/// different instrument, not a noisier reading of the same one. Mirrors
/// `SimilarityFamilies.timbreMinSharedAxes`.
export const TIMBRE_MIN_AXES = 8;
/// At or above this many axes pinned to exactly 0.0, the row is the SAME DEGENERATE POINT as
/// every other such row. Mirrors `analyze-timbre.py`'s MAX_ZERO_AXES.
export const TIMBRE_MAX_ZERO_AXES = 7;

/// IS THIS ROW USABLE AT ALL? Three ways a row is junk, all observed in the shipping corpus:
///   · a null / non-finite axis — 2 rows, both SILENT captures whose ratio axes divided by zero;
///   · fewer than TIMBRE_MIN_AXES finite axes — not comparable to anything by construction;
///   · TIMBRE_MAX_ZERO_AXES or more axes at exactly 0.0 — 30 rows that are all the same point,
///     and therefore read as each other's NEAREST NEIGHBOURS and get recommended in a little
///     self-referential clump. That is strictly worse than having no vector: a missing vector
///     makes the term fail open and the row rank on metadata, while a degenerate one actively
///     asserts a similarity that does not exist.
export function isUsableTimbreRow(f) {
  if (!f || typeof f !== 'object') return false;
  let usable = 0;
  let zeros = 0;
  for (const axis of TIMBRE_AXES) {
    if (!(axis in f)) continue;
    const v = f[axis];
    // A key that is PRESENT but not a finite number is a failed measurement, not an absent one —
    // the 14-finite-numbers contract is violated and the whole row is a failed capture.
    if (v == null || !Number.isFinite(Number(v))) return false;
    usable += 1;
    if (Number(v) === 0) zeros += 1;
  }
  if (usable < TIMBRE_MIN_AXES) return false;
  if (zeros >= TIMBRE_MAX_ZERO_AXES) return false;
  return true;
}
