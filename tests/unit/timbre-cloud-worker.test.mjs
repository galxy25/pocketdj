// CLOUD TIMBRE worker — batch planning, the tasks-file contract, the cloud→corpus seam, and the
// idle-vs-error rule that the stem lane got wrong.
import { describe, it, expect } from 'vitest';
import { planBatch, sidecarKey, TIMBRE_SONG_ID, serve } from '../../scripts/timbre-worker.mjs';
import { parseTasksFile } from '../../scripts/timbre-batch.mjs';
import { sidecarsToRows } from '../../scripts/fold-cloud-timbre.mjs';
import { foldTimbre } from '../../scripts/fold-timbre.mjs';
import { TIMBRE_VERSION } from '../../scripts/lib/audio-analyze.mjs';
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

describe('planBatch — worker-side song-id dedup', () => {
  it('skips ids whose sidecar is already on S3, and reports them as deduped', () => {
    const r = planBatch([{ id: 'sng_aaaaaaaaaaaa', key: 'k1' }, { id: 'sng_bbbbbbbbbbbb', key: 'k2' }],
      new Set(['sng_aaaaaaaaaaaa']));
    expect(r.todo.map((t) => t.id)).toEqual(['sng_bbbbbbbbbbbb']);
    expect(r.deduped).toEqual(['sng_aaaaaaaaaaaa']);
  });
  it('dedup:false FORCES a re-run — otherwise a stale sidecar could never be regenerated', () => {
    const r = planBatch([{ id: 'sng_aaaaaaaaaaaa', key: 'k' }], new Set(['sng_aaaaaaaaaaaa']), { dedup: false });
    expect(r.todo).toHaveLength(1);
    expect(r.deduped).toEqual([]);
  });
  it('accepts VARIANT ids — stem-worker rejected sng_<hex>_explicit and dead-lettered those songs', () => {
    expect(TIMBRE_SONG_ID.test('sng_3be2079ad5e3_explicit')).toBe(true);
    expect(TIMBRE_SONG_ID.test('sng_3be2079ad5e3')).toBe(true);
    expect(TIMBRE_SONG_ID.test('amrec_1234')).toBe(true);
    expect(TIMBRE_SONG_ID.test('dmx_whatever')).toBe(false);
    expect(planBatch([{ id: 'sng_3be2079ad5e3_explicit', key: 'k' }], new Set()).todo).toHaveLength(1);
  });
  it('rejects a malformed id or a missing key PERMANENTLY rather than looping it forever', () => {
    const r = planBatch([{ id: 'nope', key: 'k' }, { id: 'sng_aaaaaaaaaaaa' }], new Set());
    expect(r.todo).toEqual([]);
    expect(r.bad).toHaveLength(2);
    expect(r.bad.every((b) => b.permanent)).toBe(true);
  });
  it('dedups duplicate ids inside one batch', () => {
    expect(planBatch([{ id: 'sng_aaaaaaaaaaaa', key: 'k' }, { id: 'sng_aaaaaaaaaaaa', key: 'k' }], new Set()).todo)
      .toHaveLength(1);
  });
  it('version-prefixes the sidecar key so a TIMBRE_VERSION bump invalidates every sidecar', () => {
    expect(sidecarKey('sng_a', 'rips/timbre/')).toBe(`rips/timbre/v${TIMBRE_VERSION}/sng_a.json`);
    expect(sidecarKey('sng_a', 'rips/timbre-parity/')).toContain('timbre-parity');
  });
});

describe('timbre-batch --tasks — the cloud work list', () => {
  it('takes the supplied list verbatim (no manifest, no analog catalog, no /Volumes)', () => {
    expect(parseTasksFile([{ id: 'sng_a', key: 'rips/a.mp3' }]))
      .toEqual([{ id: 'sng_a', kind: 's3-song', key: 'rips/a.mp3' }]);
  });
  it('accepts {tasks:[…]} as well as a bare array', () => {
    expect(parseTasksFile({ tasks: [{ id: 'sng_a', key: 'k' }] })).toHaveLength(1);
  });
  it('THROWS on a bad entry instead of silently dropping it', () => {
    // A silently-dropped task looks exactly like a completed song that never got a vector.
    expect(() => parseTasksFile([{ id: 'sng_a' }])).toThrow(/no S3 key/);
    expect(() => parseTasksFile([{ key: 'k' }])).toThrow(/no id/);
    expect(() => parseTasksFile({ nope: 1 })).toThrow(/expected an array/);
  });
  it('keeps one task per song id', () => {
    expect(parseTasksFile([{ id: 'sng_a', key: 'k1' }, { id: 'sng_a', key: 'k2' }])).toHaveLength(1);
  });

  it('really does NOT read the manifest in --tasks mode', () => {
    // Asserting on the parsed list alone would not prove this: the EC2 worker has no manifest,
    // no public/current-index.json and no /Volumes/RipBurnMix, so a stray read there is a boot
    // failure, not a slow path. Point --manifest at a file that cannot exist — the run must
    // still reach the dry-run summary.
    const tasks = join(tmpdir(), `pdj-tasks-${Date.now()}.json`);
    writeFileSync(tasks, JSON.stringify([{ id: 'sng_aaaaaaaaaaaa', key: 'rips/a.mp3' }]));
    try {
      const out = execFileSync(process.execPath,
        [join(REPO, 'scripts/timbre-batch.mjs'), '--tasks', tasks, '--dry-run',
         '--manifest', '/definitely/not/a/file.json', '--state-dir', join(tmpdir(), `pdj-st-${Date.now()}`)],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
      expect(out + '').toBeDefined();
    } catch (e) {
      // A non-zero exit here means the driver touched the manifest path anyway.
      expect(`timbre-batch --tasks read the manifest: ${e.stderr || e.message}`).toBe('');
    }
  });
});

describe('sidecarsToRows — the cloud→corpus seam', () => {
  const f = { bright: 0.5 };
  it('produces rows the EXISTING fold accepts, with no changes to fold-timbre', () => {
    const rows = sidecarsToRows([{ id: 'sng_a', v: TIMBRE_VERSION, ok: true, f, atMs: 5, by: 'cloud' }]);
    const { songs, stats } = foldTimbre(rows, {});
    expect(songs.sng_a).toEqual({ v: TIMBRE_VERSION, f });
    expect(stats.vectors).toBe(1);
  });
  it('drops a sidecar at a DIFFERENT timbre version — never mix two calibrations', () => {
    expect(sidecarsToRows([{ id: 'sng_a', v: TIMBRE_VERSION + 1, ok: true, f, atMs: 1 }])).toEqual([]);
  });
  it('drops a permanent-failure sidecar: resume state is not coverage', () => {
    expect(sidecarsToRows([{ id: 'sng_a', v: TIMBRE_VERSION, ok: false, permanent: true, atMs: 1 }])).toEqual([]);
  });
  it('keeps the LATEST row per id (LWW by atMs) so a re-analysis replaces, never accumulates', () => {
    const rows = sidecarsToRows([
      { id: 'sng_a', v: TIMBRE_VERSION, ok: true, f: { bright: 0.1 }, atMs: 1 },
      { id: 'sng_a', v: TIMBRE_VERSION, ok: true, f: { bright: 0.9 }, atMs: 2 },
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0].f.bright).toBe(0.9);
  });
  it('emits ids in sorted order so the file is deterministic and diffable', () => {
    const rows = sidecarsToRows([
      { id: 'sng_b', v: TIMBRE_VERSION, ok: true, f, atMs: 1 },
      { id: 'sng_a', v: TIMBRE_VERSION, ok: true, f, atMs: 1 },
    ]);
    expect(rows.map((r) => r.id)).toEqual(['sng_a', 'sng_b']);
  });
});

describe('serve — an ERROR is activity, not idleness', () => {
  // stem-worker.mjs returned [] for BOTH "queue empty" and "receive failed", so a run of failing
  // jobs read as idleness and the worker retired holding its SQS claims. Two real jobs sat
  // inflight for 24+ minutes that way. This is the regression test for not repeating it.
  it('does not retire while polls are failing — it exits LOUDLY instead', async () => {
    let t = 0; let calls = 0;
    // `sleep` is injected so the error backoff does not make this test take a real minute.
    const r = await serve({ now: () => t, sleep: async () => {},
      pollFn: async () => { calls += 1; t += 200_000; return { state: 'error', error: 'sqs down' }; } });
    expect(r.fatal).toBe(true);
    expect(calls).toBeGreaterThan(5);
  });
  it('retires on genuine idleness once the idle window passes', async () => {
    let t = 0; let n = 0;
    const r = await serve({ now: () => t, pollFn: async () => { n += 1; t += 200_000; return { state: 'empty' }; } });
    expect(r.fatal).toBe(false);
    expect(n).toBe(1);
  });
  it('counts work and resets the error streak', async () => {
    let t = 0; let i = 0;
    const seq = [{ state: 'error', error: 'x' }, { state: 'work' }, { state: 'empty' }];
    const r = await serve({ now: () => t, sleep: async () => {},
      pollFn: async () => { t += 200_000; return seq[Math.min(i++, seq.length - 1)]; } });
    expect(r.total).toBe(1);
    expect(r.errors).toBe(0);
  });
});
