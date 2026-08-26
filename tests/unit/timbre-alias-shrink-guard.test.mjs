// The alias-map SHRINK GUARD. build-timbre-aliases derives its alias TARGETS from buildWorkList(),
// which needs /Volumes/RipBurnMix mounted. With the volume unmounted every vinyl target vanishes,
// the map collapses from ~2,900 entries to near zero, and the next fold silently DELETES that much
// coverage while exiting 0 — a green run that quietly destroys the corpus.
import { describe, it, expect } from 'vitest';
import { shrinkGuard } from '../../scripts/build-timbre-aliases.mjs';

describe('shrinkGuard', () => {
  it('allows the first run, when there is no previous artifact to compare against', () => {
    expect(shrinkGuard(null, 100)).toBeNull();
    expect(shrinkGuard(0, 100)).toBeNull();
  });
  it('allows growth — the normal case as new rips land', () => {
    expect(shrinkGuard(12153, 15247)).toBeNull();
  });
  it('allows a small shrink — songs do get removed from the library', () => {
    expect(shrinkGuard(12153, 11800)).toBeNull();
  });
  it('REFUSES the unmounted-volume collapse, and says why', () => {
    const r = shrinkGuard(12153, 200);
    expect(r).toMatch(/collapsed 12153 → 200/);
    expect(r).toMatch(/POCKETDJ_ANALOG_BASE/);
  });
  it('refuses right at the boundary of the tolerance', () => {
    expect(shrinkGuard(1000, 950)).toBeNull();        // exactly 5% — allowed
    expect(shrinkGuard(1000, 949)).toMatch(/collapsed/);
  });
});
