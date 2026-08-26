// CLOUD TIMBRE lane — the pure job/enqueue layer.
import { describe, it, expect } from 'vitest';
import { timbreKeyFor, wantTimbre, buildTimbreBatches, timbreHealth } from '../../scripts/lib/timbre-jobs.mjs';
import { TIMBRE_VERSION } from '../../scripts/lib/audio-analyze.mjs';

describe('wantTimbre — layer 1 of idempotence', () => {
  it('is false with no audio at all: a song with no key can never be analysed', () => {
    expect(wantTimbre({ source: 'digital' })).toBe(false);
    expect(wantTimbre({})).toBe(false);
    expect(wantTimbre(null)).toBe(false);
  });
  it('is true for a fresh digital rip', () => {
    expect(wantTimbre({ source: 'digital', key: 'rips/sng_a.mp3' })).toBe(true);
  });
  it('reads an ANALOG song from its per-song cut, never the shared album file', () => {
    // Every track on a vinyl side shares one raw file; the cut is what stops them sharing a vector.
    expect(timbreKeyFor({ source: 'analog', key: 'rips/album.mp3', cutKey: 'rips/cuts/sng_a.mp3' }))
      .toBe('rips/cuts/sng_a.mp3');
    expect(wantTimbre({ source: 'analog', key: 'rips/album.mp3' })).toBe(false);   // no cut yet
    expect(wantTimbre({ source: 'analog', cutKey: 'rips/cuts/sng_a.mp3' })).toBe(true);
  });
  it('is FALSE once analysed at the current version — re-adding an analysed song is a no-op', () => {
    expect(wantTimbre({ source: 'digital', key: 'k', timbreVersion: TIMBRE_VERSION })).toBe(false);
  });
  it('is TRUE again when the stamp is version-STALE, so a recalibration reaches the corpus', () => {
    expect(wantTimbre({ source: 'digital', key: 'k', timbreVersion: TIMBRE_VERSION - 1 })).toBe(true);
  });
});

describe('buildTimbreBatches — bounded, deduped enqueue', () => {
  const many = (n) => Array.from({ length: n }, (_, i) => [`sng_${String(i).padStart(12, '0')}`, `rips/${i}.mp3`, 'digital']);

  it('a 500-song collection add becomes 10 messages, not 500 jobs', () => {
    const b = buildTimbreBatches(many(500), { size: 50 });
    expect(b).toHaveLength(10);
    expect(b.every((x) => x.songs.length === 50)).toBe(true);
    expect(b.flatMap((x) => x.songs).length).toBe(500);
  });
  it('dedups by song id and keeps a stable order', () => {
    const b = buildTimbreBatches([['sng_a', 'k1', 'digital'], ['sng_a', 'k2', 'digital'], ['sng_b', 'k3', 'digital']], { size: 50 });
    expect(b[0].songs).toEqual([{ id: 'sng_a', key: 'k1' }, { id: 'sng_b', key: 'k3' }]);
  });
  it('drops entries with no key rather than enqueueing an unstageable job', () => {
    expect(buildTimbreBatches([['sng_a', null, 'digital'], ['sng_b', 'k', 'digital']], { size: 50 })[0].songs)
      .toEqual([{ id: 'sng_b', key: 'k' }]);
  });
  it('tags analog songs s3-cut so the worker records the right provenance', () => {
    expect(buildTimbreBatches([['sng_a', 'rips/cuts/a.mp3', 'analog']], {})[0].songs[0].kind).toBe('s3-cut');
  });
  it('carries kind:timbre — the guard that stops a foreign worker claiming the batch', () => {
    expect(buildTimbreBatches(many(1), {})[0].kind).toBe('timbre');
  });
  it('omits dedup by default and sets dedup:false only on a FORCED re-analysis', () => {
    // Without dedup:false a skip-if-exists would re-stamp a stale sidecar as current, and the
    // song could then never be regenerated.
    expect(buildTimbreBatches(many(1), {})[0].dedup).toBeUndefined();
    expect(buildTimbreBatches(many(1), { dedup: false })[0].dedup).toBe(false);
  });
  it('returns nothing for an empty input — an add of already-analysed songs sends no message', () => {
    expect(buildTimbreBatches([], {})).toEqual([]);
  });
});

describe('timbreHealth — the freeze signal', () => {
  it('counts analysed vs outstanding and ages the oldest un-analysed rip', () => {
    const now = 1_000_000_000;
    const h = timbreHealth({
      a: { source: 'digital', key: 'k', timbreVersion: TIMBRE_VERSION },
      b: { source: 'digital', key: 'k', rippedAt: now - 3 * 86400_000 },
      c: { source: 'digital', key: 'k', rippedAt: now - 86400_000 },
      d: { source: 'digital' },                              // no audio → not a timbre candidate
    }, now);
    expect(h.analysed).toBe(1);
    expect(h.outstanding).toBe(2);
    expect(h.oldestOutstandingAgeMs).toBe(3 * 86400_000);
  });
  it('reports a null age when nothing is outstanding — silence that is genuinely healthy', () => {
    const h = timbreHealth({ a: { source: 'digital', key: 'k', timbreVersion: TIMBRE_VERSION } });
    expect(h.outstanding).toBe(0);
    expect(h.oldestOutstandingAgeMs).toBeNull();
  });
});
