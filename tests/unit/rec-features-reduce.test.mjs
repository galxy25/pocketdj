// Rec-engine feature reduction (build-rec-features.mjs) — segment-attribution discipline.
//
// REGRESSION: the original audioTracks fallback matched by trackNumber. Catalog trackNumber is
// the wiki-tracklist position, NOT the rip's segment ordinal, so un-analyzed duplicate/bonus
// entries (live cuts, demos, music videos, second tracklist listings — pointer.startMs absent)
// silently borrowed ANOTHER recording's bpm/camelot whenever their trackNumber collided with a
// segment ordinal. 49 fabricated rows shipped in rec-features.json between 08-07 and 08-10
// (e.g. Duran Duran "Evil Woman" carrying "Secret Oktober 31st"'s 123 bpm). The fallback must
// key on the song's OWN segment identity: pointer.startMs === audioTracks[k].startMs.
import { describe, it, expect } from 'vitest';
import { reduce, assertNoTimbreRegression } from '../../scripts/build-rec-features.mjs';

/** Minimal analog-index shape: one album, three catalog entries, two analyzed segments. */
function fixture() {
  return {
    albums: [{
      id: 'alb_1',
      genre: 'new wave',
      year: 1978,
      audioTracks: [
        { trackNumber: 1, startMs: 11726, endMs: 147168, bpm: 152, key: 'D# major', camelot: '5B' },
        { trackNumber: 2, startMs: 154784, endMs: 363299, bpm: 161.5, key: 'B minor', camelot: '10A' },
      ],
    }],
    songs: [
      // Analyzed song: bpm/camelot already folded at the song level; pointer carries its segment.
      {
        id: 'sng_analyzed', albumId: 'alb_1', artist: 'Blondie', name: 'One Way or Another',
        trackNumber: 2, bpm: 162, camelot: '10A',
        pointer: { disc: 1, track: 2, startMs: 154784, endMs: 363299 },
      },
      // Un-analyzed duplicate entry: trackNumber 1 COLLIDES with segment ordinal 1, but it has no
      // segment of its own (no startMs). Must get NO bpm/camelot — never segment 1's 152/5B.
      {
        id: 'sng_bonus', albumId: 'alb_1', artist: 'Blondie', name: 'Hanging on the Telephone',
        trackNumber: 1, bpm: null, key: null,
        pointer: { disc: 5, track: 2, timestamps: null },
      },
      // Fold-miss recovery: song OWNS segment 1 (startMs matches) but the song-level fold is
      // missing. The fallback may legitimately fill from the song's own segment.
      {
        id: 'sng_foldmiss', albumId: 'alb_1', artist: 'Blondie', name: 'Hanging on the Telephone (The Nerves cover)',
        trackNumber: 13, bpm: null, key: null,
        pointer: { disc: 1, track: 1, startMs: 11726, endMs: 147168 },
      },
    ],
  };
}

describe('reduce() bpm/camelot attribution', () => {
  const rows = reduce(fixture());
  const byId = new Map(rows.map((r) => [r.i, r]));

  it('keeps song-level bpm/camelot when present', () => {
    expect(byId.get('sng_analyzed').b).toBe(162);
    expect(byId.get('sng_analyzed').c).toBe('10A');
  });

  it('REGRESSION: never borrows a segment via trackNumber collision (b/c stay absent)', () => {
    const bonus = byId.get('sng_bonus');
    expect(bonus).toBeDefined();
    expect(bonus.b).toBeUndefined();
    expect(bonus.c).toBeUndefined();
  });

  it('recovers a fold-miss from the song\'s OWN segment (pointer.startMs identity)', () => {
    expect(byId.get('sng_foldmiss').b).toBe(152);
    expect(byId.get('sng_foldmiss').c).toBe('5B');
  });
});

// ── THE PUBLISH GUARD ──────────────────────────────────────────────────────────────────────────
// `timbreMap` refuses a corpus at the wrong calibration and says so loudly but NOT fatally, so an
// out-of-date audio corpus cannot hold a catalog deploy hostage. On its own that makes the worst
// outcome the QUIETEST one: the nightly runs, prints a warning into a log nobody reads, and
// overwrites a rec-features.json carrying 18,705 timbre vectors with one carrying zero. The term
// then dies on every device and in the Lambda, and the only symptom is a feed that feels slightly
// worse. So the artifact already on disk gets a vote.
describe('assertNoTimbreRegression', () => {
  const withT = { timbreVersion: 1, songs: [{ i: 'a', t: { bright: 0.5 } }, { i: 'b' }] };
  const withoutT = { timbreVersion: null, songs: [{ i: 'a' }, { i: 'b' }] };

  it('REFUSES to replace a corpus-carrying artifact with one that carries none', () => {
    expect(() => assertNoTimbreRegression(withoutT, false, withT)).toThrow(/REFUSING TO PUBLISH/);
    // …and the message has to be actionable, because the operator has to know what to re-run.
    expect(() => assertNoTimbreRegression(withoutT, false, withT)).toThrow(/fold-timbre/);
  });

  it('lets every non-regression through', () => {
    expect(() => assertNoTimbreRegression(withT, false, withT)).not.toThrow();
    expect(() => assertNoTimbreRegression(withT, false, withoutT)).not.toThrow();
    expect(() => assertNoTimbreRegression(withoutT, false, withoutT)).not.toThrow();
    expect(() => assertNoTimbreRegression(withT, false, null)).not.toThrow();
    // A first run with nothing on disk has nothing to protect.
    expect(() => assertNoTimbreRegression(withoutT, false, null)).not.toThrow();
  });

  it('can be overridden BY NAME, for the deliberate case', () => {
    expect(() => assertNoTimbreRegression(withoutT, true, withT)).not.toThrow();
  });
});
