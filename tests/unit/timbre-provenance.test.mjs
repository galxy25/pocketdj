// THE PARITY GAP THE PARITY GATE CANNOT SEE.
//
// timbre-parity-check compares 120 songs measured in the cloud against the same songs measured
// locally — and all 120 are `s3-song`, the one class where both lanes read the SAME BYTES. It is
// therefore silent about the class where they DO NOT: an analog song's local vector is a
// `vinyl-cut` (an ffmpeg stream copy of the song's own window out of the raw album file, often
// AIFF/PCM), while the cloud can only ever produce an `s3-cut` (the burned, re-encoded cut mp3),
// because /Volumes/RipBurnMix is not on EC2.
//
// 10,388 of the corpus's 15,489 vectors are vinyl-cut. Plain recency in the fold would let a
// cloud sweep replace them one batch at a time, leaving a corpus on two calibrations with nothing
// in the artifact recording which row is which — worse than a stale corpus, because it cannot be
// detected after the fact. These tests pin the three places that now refuse it.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  indexResultRows, reconcileTimbreStamps, crossesTimbreProvenance, cloudKindFor,
  timbreSrcRank, timbreHealth, buildTimbreBatches,
} from '../../scripts/lib/timbre-jobs.mjs';
import { foldTimbre, corpusShrinkGuard } from '../../scripts/fold-timbre.mjs';
import { TIMBRE_VERSION } from '../../scripts/lib/audio-analyze.mjs';
import { TIMBRE_AXES } from '../../scripts/lib/timbre-hygiene.mjs';

const V = TIMBRE_VERSION;
const FOLD = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', 'scripts', 'fold-timbre.mjs');
/// A REALISTIC vector — all 14 axes, none of them 0. Provenance is not the only guard the fold
/// applies any more: `isUsableTimbreRow` quarantines rows below the 8-axis floor, so a one-key
/// stand-in would be thrown away before the rank comparison this file is about ever ran.
const F14 = Object.fromEntries(TIMBRE_AXES.map((a, i) => [a, Math.round((0.11 + i * 0.055) * 1e4) / 1e4]));
const row = (id, src, atMs, extra = {}) => ({ id, v: V, src, atMs, ok: true, f: F14, ...extra });

describe('provenance rank', () => {
  it('ranks the burned re-encoded cut BELOW the raw-file cut and the per-song rip', () => {
    expect(timbreSrcRank('s3-cut')).toBeLessThan(timbreSrcRank('vinyl-cut'));
    expect(timbreSrcRank('s3-cut')).toBeLessThan(timbreSrcRank('s3-song'));
    expect(timbreSrcRank('vinyl-cut')).toBe(timbreSrcRank('s3-song'));  // the two corpus classes tie
    expect(timbreSrcRank(undefined)).toBe(0);                            // unknown provenance is lowest
  });

  it('names the kind the CLOUD would use — analog can only ever be the burned cut', () => {
    expect(cloudKindFor({ source: 'analog' })).toBe('s3-cut');
    expect(cloudKindFor({ source: 'digital' })).toBe('s3-song');
    // and buildTimbreBatches stamps exactly that onto the wire
    expect(buildTimbreBatches([['sng_a', 'rips/cuts/a.mp3', 'analog']])[0].songs[0].kind).toBe('s3-cut');
    expect(buildTimbreBatches([['sng_b', 'rips/b.mp3', 'digital']])[0].songs[0].kind).toBeUndefined();
  });
});

describe('indexResultRows', () => {
  it('keeps the HIGHER-provenance row even when the lower one is newer', () => {
    const d = indexResultRows([row('sng_a', 'vinyl-cut', 100), row('sng_a', 's3-cut', 999)]);
    expect(d.get('sng_a').src).toBe('vinyl-cut');
  });
  it('is order-independent — the same answer whichever row is read first', () => {
    const d = indexResultRows([row('sng_a', 's3-cut', 999), row('sng_a', 'vinyl-cut', 100)]);
    expect(d.get('sng_a').src).toBe('vinyl-cut');
  });
  it('falls back to last-write-wins WITHIN one provenance class', () => {
    const d = indexResultRows([row('sng_a', 's3-song', 100), row('sng_a', 's3-song', 900)]);
    expect(d.get('sng_a').atMs).toBe(900);
  });
  it('counts a PERMANENT failure as measured (it must never wedge the queue) but not as ok', () => {
    const d = indexResultRows([{ id: 'sng_x', v: V, permanent: true, error: 'too short' }]);
    expect(d.get('sng_x')).toMatchObject({ ok: false, permanent: true });
  });
  it('ignores rows at a different calibration', () => {
    expect(indexResultRows([row('sng_a', 's3-song', 1, { v: V + 1 })]).size).toBe(0);
  });
});

describe('reconcileTimbreStamps — the durable corpus IS the record of "analysed"', () => {
  // 15,489 vectors were measured before the manifest stamp existed. Without this every one of
  // them reads as outstanding forever: the 6-hourly sweep re-runs 500 at a time on EC2, /health
  // reports a permanent five-thousand-song backlog, and the staleness alarm cries wolf nightly.
  const seed = () => ({
    sng_dig: { source: 'digital', key: 'rips/sng_dig.mp3' },
    sng_ana: { source: 'analog', key: 'rips/album.mp3', cutKey: 'rips/cuts/sng_ana.mp3' },
    sng_new: { source: 'digital', key: 'rips/sng_new.mp3' },      // genuinely un-measured
    sng_noaudio: { source: 'digital' },                            // nothing to stamp
  });

  it('stamps every already-measured song, recording WHICH audio produced the vector', () => {
    const m = seed();
    const r = reconcileTimbreStamps(m, indexResultRows([row('sng_dig', 's3-song', 10), row('sng_ana', 'vinyl-cut', 20)]));
    expect(r.stamped).toBe(2);
    expect(m.sng_dig).toMatchObject({ timbreVersion: V, timbreSrc: 's3-song', timbreAt: 10 });
    expect(m.sng_ana).toMatchObject({ timbreVersion: V, timbreSrc: 'vinyl-cut' });
    expect(m.sng_new.timbreVersion).toBeUndefined();
    expect(m.sng_noaudio.timbreVersion).toBeUndefined();
  });

  it('marks a permanently-unanalysable song rather than claiming it has a vector', () => {
    const m = seed();
    const r = reconcileTimbreStamps(m, indexResultRows([{ id: 'sng_dig', v: V, permanent: true }]));
    expect(r).toMatchObject({ stamped: 0, failed: 1 });
    expect(m.sng_dig.timbrePermanent).toBe(true);
    // …and /health counts it as failed, NOT as coverage
    const h = timbreHealth(m);
    expect(h.analysed).toBe(0);
    expect(h.failed).toBe(1);
    expect(h.outstanding).toBe(2);                                 // sng_ana + sng_new
  });

  it('never re-stamps or downgrades a song the pump already stamped', () => {
    const m = seed();
    m.sng_dig = { ...m.sng_dig, timbre: 'rips/timbre/v1/sng_dig.json', timbreVersion: V, timbreAt: 999 };
    const r = reconcileTimbreStamps(m, indexResultRows([row('sng_dig', 's3-song', 10)]));
    expect(r.stamped).toBe(0);
    expect(m.sng_dig.timbreAt).toBe(999);
  });
});

describe('crossesTimbreProvenance — the gate, held even under force', () => {
  const analog = { source: 'analog', key: 'rips/album.mp3', cutKey: 'rips/cuts/sng_ana.mp3' };
  const digital = { source: 'digital', key: 'rips/sng_dig.mp3' };

  it('HOLDS an analog song whose vector was measured from the raw album file', () => {
    expect(crossesTimbreProvenance(analog, indexResultRows([row('x', 'vinyl-cut', 1)]).get('x'))).toBe(true);
  });
  it('lets a digital song through — the cloud reads the same bytes the local lane did', () => {
    expect(crossesTimbreProvenance(digital, indexResultRows([row('x', 's3-song', 1)]).get('x'))).toBe(false);
  });
  it('lets an analog song through when its vector already came from the burned cut', () => {
    expect(crossesTimbreProvenance(analog, indexResultRows([row('x', 's3-cut', 1)]).get('x'))).toBe(false);
  });
  it('never holds a song that has no vector at all', () => {
    expect(crossesTimbreProvenance(analog, undefined)).toBe(false);
    expect(crossesTimbreProvenance(analog, { ok: false, permanent: true, src: 'vinyl-cut' })).toBe(false);
  });
  it('releases only on the explicit operator opt-out', () => {
    const r = indexResultRows([row('x', 'vinyl-cut', 1)]).get('x');
    expect(crossesTimbreProvenance(analog, r, { allowSrcChange: true })).toBe(false);
  });
});

describe('foldTimbre — provenance-ranked LWW', () => {
  // A REALISTIC 14-axis vector, distinguishable by `n`. `{ centroid: n }` used to do, but the
  // fold now quarantines anything below the 8-axis floor, so that stand-in would be thrown away
  // before the provenance rank comparison this block is about ever ran.
  const vec = (n) => Object.fromEntries(TIMBRE_AXES.map((a, i) => [a, Math.round((0.05 * n + i * 0.05) * 1e4) / 1e4]));
  const r = (id, src, atMs, f) => ({ id, v: V, src, atMs, ok: true, f });

  it('a NEWER s3-cut does not replace an older vinyl-cut', () => {
    const { songs, stats } = foldTimbre([r('sng_a', 'vinyl-cut', 100, vec(1)), r('sng_a', 's3-cut', 999, vec(2))]);
    expect(songs.sng_a.f).toEqual(vec(1));
    expect(stats.held).toBe(1);
    expect(stats.vectors).toBe(1);
  });

  it('…in EITHER file order — cloud.ndjson sorts before shard-*.ndjson, so order must not decide', () => {
    const { songs } = foldTimbre([r('sng_a', 's3-cut', 999, vec(2)), r('sng_a', 'vinyl-cut', 100, vec(1))]);
    expect(songs.sng_a.f).toEqual(vec(1));
  });

  it('still replaces WITHIN a class — a genuine re-measurement of the same audio wins', () => {
    const { songs, stats } = foldTimbre([r('sng_a', 's3-song', 100, vec(1)), r('sng_a', 's3-song', 999, vec(2))]);
    expect(songs.sng_a.f).toEqual(vec(2));
    expect(stats.held).toBe(0);
  });

  it('an s3-cut still lands when it is the only vector the song has', () => {
    const { songs, stats } = foldTimbre([r('sng_a', 's3-cut', 5, vec(9))]);
    expect(songs.sng_a.f).toEqual(vec(9));
    expect(stats.vectors).toBe(1);
  });
});

describe('corpusShrinkGuard — the nightly commits, pushes and SHIPS whatever the fold writes', () => {
  // The vectors live only in an unbacked-up ~/.pocketdj/timbre-batch/results. A lost or
  // wrong-$HOME results dir would otherwise publish an empty corpus to every device, exit 0, and
  // look like a normal night. The alias guard cannot catch it — it measures alias TARGETS.
  it('refuses a collapse', () => {
    expect(corpusShrinkGuard(15489, 0)).toMatch(/collapsed 15489 → 0/);
    expect(corpusShrinkGuard(15489, 12000)).toMatch(/collapsed/);
  });
  it('allows growth and ordinary jitter', () => {
    expect(corpusShrinkGuard(15489, 15489)).toBeNull();
    expect(corpusShrinkGuard(12173, 15489)).toBeNull();
    expect(corpusShrinkGuard(15489, 15000)).toBeNull();          // < 5% — a real, if odd, change
  });
  it('has nothing to say without a baseline', () => {
    expect(corpusShrinkGuard(null, 0)).toBeNull();
    expect(corpusShrinkGuard(0, 0)).toBeNull();
  });
});

describe('the shrink guard vs a CALIBRATION BUMP — driven through the real CLI', () => {
  // The corpus legitimately restarts near zero at a new TIMBRE_VERSION — nothing measured at the
  // old one folds. Comparing across versions would refuse the very first v(N) fold. (At the time
  // of writing a v2 calibration is being measured into the same results dir; the v1 fold drops
  // those rows, which is exactly the behaviour that must not become an error.)
  const runFold = async (results, out) => {
    const { execFile } = await import('node:child_process');
    const { promisify } = await import('node:util');
    try {
      const { stderr } = await promisify(execFile)(process.execPath,
        [FOLD, '--results', results, '--out', out, '--aliases', join(results, 'none.json')]);
      return { code: 0, stderr };
    } catch (e) { return { code: e.code, stderr: e.stderr }; }
  };
  let dir, results, out;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'pdj-fold-guard-'));
    results = join(dir, 'results');
    out = join(dir, 'timbre.json');
    mkdirSync(results, { recursive: true });
    writeFileSync(join(results, 'shard-0.ndjson'),
      [row('sng_a', 's3-song', 1), row('sng_b', 's3-song', 2)].map((r) => JSON.stringify(r)).join('\n') + '\n');
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('REFUSES a same-version collapse and leaves the artifact untouched', async () => {
    writeFileSync(out, JSON.stringify({ v: 1, timbreVersion: V, counts: { vectors: 15489 }, songs: { keep: 1 } }));
    const r = await runFold(results, out);
    expect(r.code).toBe(3);
    expect(r.stderr).toMatch(/REFUSING/);
    expect(JSON.parse(readFileSync(out, 'utf8')).counts.vectors).toBe(15489);   // untouched
  }, 20_000);

  it('WRITES over an artifact at a DIFFERENT timbreVersion — a bump is not a collapse', async () => {
    writeFileSync(out, JSON.stringify({ v: 1, timbreVersion: V + 1, counts: { vectors: 15489 }, songs: { keep: 1 } }));
    const r = await runFold(results, out);
    expect(r.code).toBe(0);
    expect(JSON.parse(readFileSync(out, 'utf8')).counts.vectors).toBe(2);
  }, 20_000);

  it('writes freely when there is no artifact yet', async () => {
    const r = await runFold(results, out);
    expect(r.code).toBe(0);
    expect(JSON.parse(readFileSync(out, 'utf8')).counts.vectors).toBe(2);
  }, 20_000);
});
