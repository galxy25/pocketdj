// TIMBRE CALIBRATION-VERSION PARITY — one number, four consumers, no comment-only sync.
//
// The rails ARE the units: `bright` under the v1 rails and `bright` under the v2 rails are
// different physical quantities wearing the same name and the same 0…1 range, so a distance taken
// across them is arithmetic on incomparable numbers — and it yields an ordinary-looking float,
// which is the dangerous kind of wrong. Every consumer therefore REFUSES a corpus stamped at a
// version it does not speak:
//
//   · scripts/lib/audio-analyze.mjs   TIMBRE_VERSION            ← the writer, the source of truth
//   · scripts/fold-timbre.mjs         `versionDropped`          (imports it)
//   · scripts/build-rec-features.mjs  `timbreMap`               (imports it)
//   · scripts/lambda/rec-engine/      const TIMBRE_VERSION = N  ← a LITERAL, deploys separately
//   · apple/…/SimilarityFamilies      static let timbreVersion  ← a LITERAL, ships via TestFlight
//
// The last two cannot import it, and both say "MIRRORS TIMBRE_VERSION" in a comment. A comment is
// not a check, and the failure mode is silent: whichever copy is stale reads a corpus it cannot
// measure, or refuses one it could.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { TIMBRE_VERSION } from '../../scripts/lib/audio-analyze.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SWIFT = join(ROOT, 'apple', 'PocketDJ', 'Services', 'Recommendations', 'SimilarityFamilies.swift');
const CATALOG = join(ROOT, 'apple', 'PocketDJ', 'Services', 'Recommendations', 'TimbreCatalog.swift');
const LAMBDA = join(ROOT, 'scripts', 'lambda', 'rec-engine', 'index.mjs');

/** Read a literal declaration out of a source file, with // comments stripped first. */
function literal(path, re) {
  const src = readFileSync(path, 'utf8').replace(/^\s*\/\/[^\n]*$/gm, '').replace(/^\s*\/\/\/[^\n]*$/gm, '');
  const m = re.exec(src);
  expect(m, `${path}: no declaration matching ${re}`).toBeTruthy();
  return Number(m[1]);
}

describe('timbre calibration version', () => {
  it('is the SAME number in the writer, the Lambda and the device', () => {
    expect(Number.isInteger(TIMBRE_VERSION)).toBe(true);
    expect(literal(LAMBDA, /^const TIMBRE_VERSION = (\d+);/m)).toBe(TIMBRE_VERSION);
    expect(literal(SWIFT, /^\s*static let timbreVersion = (\d+)\s*$/m)).toBe(TIMBRE_VERSION);
  });

  it('is actually ENFORCED on the device — the reader that computes the distances', () => {
    // The other three consumers are covered by their own tests (fold-timbre.test.mjs's
    // `versionDropped`, rec-features-reduce's `timbreMap`). This pins the fourth, which was once
    // dropped in a merge and left the only surface that runs the sound door with no version check
    // at all — while `build-rec-features` correctly refused the same corpus, so the Lambda would
    // have scored v(N) `t` values against a device measuring v(N+1) vectors for the same catalog.
    const src = readFileSync(CATALOG, 'utf8');
    expect(src).toMatch(/doc\.timbreVersion \?\? 1/);
    expect(src).toMatch(/guard docVersion == SimilarityFamilies\.timbreVersion else \{ return \[:\] \}/);
    expect(src).toMatch(/if let rowVersion = row\.v, rowVersion != docVersion \{ continue \}/);
  });
});
