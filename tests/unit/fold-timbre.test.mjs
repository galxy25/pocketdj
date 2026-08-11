// fold-timbre + rec-features `t` attachment — the fold's attribution invariants: vectors only
// under their own id, aliases explicit and resolvable, nothing dangling, nothing copied blind.
import { describe, it, expect } from 'vitest';
import { foldTimbre } from '../../scripts/fold-timbre.mjs';
import { timbreMap, reduce } from '../../scripts/build-rec-features.mjs';
import { TIMBRE_VERSION } from '../../scripts/lib/audio-analyze.mjs';

const F = { bright: 0.5, punch: 0.7 };
const row = (id, over = {}) => ({ id, v: TIMBRE_VERSION, ok: true, f: F, atMs: 1000, ...over });

describe('foldTimbre', () => {
  it('folds ok rows under their own id; failures and wrong versions drop', () => {
    const { songs, stats } = foldTimbre([
      row('sng_a'),
      { id: 'sng_bad', v: TIMBRE_VERSION, ok: false, permanent: true, error: 'too-short' },
      row('sng_old', { v: TIMBRE_VERSION + 1 }),
    ]);
    expect(Object.keys(songs)).toEqual(['sng_a']);
    expect(stats.dropped).toBe(2);
  });

  it('last write wins per id (re-analysis replaces, never accumulates)', () => {
    const f2 = { bright: 0.9, punch: 0.1 };
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
  const corpus = { songs: { sng_a: { v: 1, f: F }, sng_twin: { alias: 'sng_a' } } };

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
});
