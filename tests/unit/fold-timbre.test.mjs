// fold-timbre + rec-features `t` attachment — the fold's attribution invariants: vectors only
// under their own id, aliases explicit and resolvable, nothing dangling, nothing copied blind.
import { describe, it, expect } from 'vitest';
import { foldTimbre } from '../../scripts/fold-timbre.mjs';
import { timbreMap, reduce } from '../../scripts/build-rec-features.mjs';
import { TIMBRE_VERSION } from '../../scripts/lib/audio-analyze.mjs';
import { TIMBRE_AXES, isUsableTimbreRow } from '../../scripts/lib/timbre-hygiene.mjs';

/// A REALISTIC vector — all 14 axes, none of them 0. The fold, the device decode, the Lambda and
/// the feature builder all apply `isUsableTimbreRow` now, so a two-axis stand-in is no longer a
/// valid corpus row: it sits below the 8-shared-axis floor and is quarantined exactly like the
/// junk it resembles. A fixture that would be thrown away by the code under test proves nothing.
const F = Object.fromEntries(TIMBRE_AXES.map((a, i) => [a, Math.round((0.11 + i * 0.055) * 1e4) / 1e4]));
const row = (id, over = {}) => ({ id, v: TIMBRE_VERSION, ok: true, f: F, atMs: 1000, ...over });

describe('foldTimbre', () => {
  it('folds ok rows under their own id; failures and wrong versions drop', () => {
    const { songs, stats } = foldTimbre([
      row('sng_a'),
      { id: 'sng_bad', v: TIMBRE_VERSION, ok: false, permanent: true, error: 'too-short' },
      row('sng_old', { v: TIMBRE_VERSION + 1 }),
    ]);
    expect(Object.keys(songs)).toEqual(['sng_a']);
    expect(stats.dropped).toBe(1);           // the failed row
    expect(stats.versionDropped).toBe(1);    // counted SEPARATELY — see below
  });

  it('REFUSES to mix calibrations, and counts that apart from malformed rows', () => {
    // The rails are the UNITS. A v(N-1) vector and a v(N) vector are different quantities sharing
    // a name, so folding both would publish a corpus whose own rows are not comparable to each
    // other. The count is kept apart from `dropped` because DURING a re-extraction sweep a large
    // versionDropped is the healthy signal and says something completely different from a
    // malformed-row count. (The live results dir carries 2,651 such rows right now.)
    const { songs, stats } = foldTimbre([
      row('sng_prev', { v: TIMBRE_VERSION - 1 }),
      row('sng_now'),
      row('sng_next', { v: TIMBRE_VERSION + 1 }),
    ]);
    expect(Object.keys(songs)).toEqual(['sng_now']);
    expect(stats.versionDropped).toBe(2);
    expect(stats.dropped).toBe(0);
  });

  it('QUARANTINES degenerate rows so the corpus never carries a fake similarity cluster', () => {
    // The three shapes observed in the shipping corpus, one row each. All-zero rows are the SAME
    // POINT, so they read as each other's nearest neighbours and get recommended in a clump.
    const allZero = Object.fromEntries(TIMBRE_AXES.map((a) => [a, 0]));
    const nullAxis = { ...F, punch: null };
    const tooFew = { bright: 0.5, punch: 0.7 };
    const { songs, stats } = foldTimbre([
      row('sng_zero', { f: allZero }),
      row('sng_null', { f: nullAxis }),
      row('sng_thin', { f: tooFew }),
      row('sng_ok'),
    ]);
    expect(Object.keys(songs)).toEqual(['sng_ok']);
    expect(stats.quarantined).toBe(3);
    // …and the predicate itself, so the RULE is pinned and not merely its effect here.
    expect(isUsableTimbreRow(allZero)).toBe(false);
    expect(isUsableTimbreRow(nullAxis)).toBe(false);
    expect(isUsableTimbreRow(tooFew)).toBe(false);
    expect(isUsableTimbreRow(F)).toBe(true);
  });

  it('a degenerate row cannot win a provenance comparison and displace a usable one', () => {
    // Quarantine runs BEFORE the src-rank check, so a junk `s3-song` row (rank 2) cannot beat a
    // good `s3-cut` row (rank 1) and leave the song with no vector at all.
    const junk = Object.fromEntries(TIMBRE_AXES.map((a) => [a, 0]));
    const { songs, stats } = foldTimbre([
      row('sng_a', { src: 's3-cut', atMs: 1000 }),
      row('sng_a', { src: 's3-song', atMs: 2000, f: junk }),
    ]);
    expect(songs.sng_a.f).toEqual(F);
    expect(stats.quarantined).toBe(1);
    expect(stats.held).toBe(0);
  });

  it('an alias whose target got quarantined is dropped, not left pretending coverage', () => {
    const junk = Object.fromEntries(TIMBRE_AXES.map((a) => [a, 0]));
    const { songs, stats } = foldTimbre([row('sng_a', { f: junk })], { sng_twin: { to: 'sng_a' } });
    expect(songs.sng_twin).toBeUndefined();
    expect(stats.pending).toBe(1);
  });

  it('collects the RAW block for the calibrator WITHOUT putting it in the published corpus', () => {
    // 14 more floats per row would roughly double a file every device downloads, to serve a
    // script that runs on a laptop. Keeping them is what makes the NEXT rail change arithmetic
    // on measurements already taken rather than a multi-day re-extraction — which is exactly the
    // price that kept a 76-song calibration in force while the corpus grew past 15,000.
    const raw = new Map();
    const r = { cent: 2000, centStd: 700, roll: 4000, band: 2200, flat: 0.01, zcr: 0.08,
                perc: 0.3, onsetRate: 4, crest: 2.5, rms: 0.05, m1: 200, m2: 50, m3: 90, m4: -10 };
    const { songs } = foldTimbre([row('sng_a', { r }), row('sng_b')], {}, raw);
    expect(raw.get('sng_a')).toEqual(r);
    expect(songs.sng_a.r).toBeUndefined();
    expect(raw.has('sng_b')).toBe(false, 'a row predating raw-persistence contributes nothing');
  });

  it('a re-analysis WITHOUT a raw block clears the stale one — LWW applies to `r` too', () => {
    // Otherwise the raw map would keep a block from a measurement the corpus no longer holds,
    // and the calibrator would derive rails from a vector that is not in the file it calibrates.
    const raw = new Map();
    const r = { cent: 2000, centStd: 700, roll: 4000, band: 2200, flat: 0.01, zcr: 0.08,
                perc: 0.3, onsetRate: 4, crest: 2.5, rms: 0.05, m1: 200, m2: 50, m3: 90, m4: -10 };
    foldTimbre([row('sng_a', { r, atMs: 1000 }), row('sng_a', { atMs: 2000 })], {}, raw);
    expect(raw.has('sng_a')).toBe(false);
  });

  it('last write wins per id (re-analysis replaces, never accumulates)', () => {
    const f2 = Object.fromEntries(TIMBRE_AXES.map((a, i) => [a, Math.round((0.9 - i * 0.05) * 1e4) / 1e4]));
    const { songs } = foldTimbre([row('sng_a'), row('sng_a', { f: f2, atMs: 2000 })]);
    expect(songs.sng_a.f).toEqual(f2);
  });

  it('aliases are EXPLICIT indirections, never copies', () => {
    const { songs } = foldTimbre([row('sng_a')], { sng_twin: { to: 'sng_a' } });
    expect(songs.sng_twin).toEqual({ alias: 'sng_a' });
    expect(songs.sng_twin.f).toBeUndefined();
  });

  it('a dangling alias (target has no vector) is dropped and counted, not emitted', () => {
    const { songs, stats } = foldTimbre([row('sng_a')], { sng_x: { to: 'sng_missing' } });
    expect(songs.sng_x).toBeUndefined();
    expect(stats.pending).toBe(1);
  });

  it('own analysis beats an alias for the same id', () => {
    const { songs, stats } = foldTimbre([row('sng_a'), row('sng_b')], { sng_b: { to: 'sng_a' } });
    expect(songs.sng_b.f).toEqual(F);
    expect(songs.sng_b.alias).toBeUndefined();
    expect(stats.shadowed).toBe(1);
  });

  it('an alias to an alias never chains (one-hop rule)', () => {
    const { songs } = foldTimbre([row('sng_a')], { sng_b: { to: 'sng_a' }, sng_c: { to: 'sng_b' } });
    expect(songs.sng_b).toEqual({ alias: 'sng_a' });
    expect(songs.sng_c).toBeUndefined();               // sng_b is itself an alias → pending
  });
});

describe('rec-features t attachment', () => {
  const corpus = { timbreVersion: TIMBRE_VERSION,
                   songs: { sng_a: { v: TIMBRE_VERSION, f: F }, sng_twin: { alias: 'sng_a' } } };

  it('timbreMap resolves vectors and one-hop aliases', () => {
    const m = timbreMap(corpus);
    expect(m.get('sng_a')).toEqual(F);
    expect(m.get('sng_twin')).toEqual(F);
    expect(m.get('sng_other')).toBeUndefined();
  });

  it('reduce attaches t under the song\'s own id and omits it when unknown', () => {
    const idx = { albums: [], songs: [
      { id: 'sng_a', artist: 'A', name: 'X' },
      { id: 'sng_twin', artist: 'A', name: 'X' },
      { id: 'sng_none', artist: 'B', name: 'Y' },
    ] };
    const rows = reduce(idx, timbreMap(corpus));
    const byId = new Map(rows.map((r) => [r.i, r]));
    expect(byId.get('sng_a').t).toEqual(F);
    expect(byId.get('sng_twin').t).toEqual(F);
    expect(byId.get('sng_none').t).toBeUndefined();
  });

  it('reduce without a timbre map behaves exactly as before (no t anywhere)', () => {
    const idx = { albums: [], songs: [{ id: 'sng_a', artist: 'A', name: 'X' }] };
    expect(reduce(idx)[0].t).toBeUndefined();
  });

  it('timbreMap REFUSES a corpus written under a different calibration', () => {
    // Attaching it would ship numbers to every device and to the Lambda that nothing downstream
    // could tell apart from correct ones. Refuse whole; the term then simply fails open.
    const stale = { timbreVersion: TIMBRE_VERSION + 1, songs: { sng_a: { f: F } } };
    expect(timbreMap(stale).size).toBe(0);
    // …loudly, and fatally under --strict, so CI cannot ship a silently timbre-less catalog.
    expect(() => timbreMap(stale, { strict: true })).toThrow(/TIMBRE CORPUS REFUSED/);
  });

  it('a corpus with NO version field is read as v1 — the version that predates the field', () => {
    const unstamped = { songs: { sng_a: { f: F } } };
    expect(timbreMap(unstamped).size).toBe(TIMBRE_VERSION === 1 ? 1 : 0);
  });

  it('timbreMap quarantines degenerate rows too — a reader never trusts the writer', () => {
    const withJunk = { timbreVersion: TIMBRE_VERSION, songs: {
      sng_ok: { f: F },
      sng_zero: { f: Object.fromEntries(TIMBRE_AXES.map((a) => [a, 0])) },
    } };
    expect([...timbreMap(withJunk).keys()]).toEqual(['sng_ok']);
  });
});
