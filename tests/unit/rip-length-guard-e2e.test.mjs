// END-TO-END: the REAL rip server's length-guard wiring and POST /rip-repair.
//
// Boots scripts/rip-server.mjs with an isolated HOME, a free port, the fake `aws` (manifest
// round-trips through one file, SQS bodies spool to disk, and every invocation is LOGGED so the
// repair's deletes are assertable), and a fake capture worker that reports a planned outcome.
//
//   · a short-capture rejection is retried through the backoff ladder and never registered
//   · an accepted capture registers its MEASURED length, and the worker is told where its
//     expected length came from
//   · /rip-repair is admin-only, audits by the same rule, refuses in-flight ids, deletes the rip
//     + every derived artifact of exactly the target song, re-rips it, and the re-rip's stems
//     and timbre offloads go out with dedup OFF
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { TIMBRE_VERSION } from '../../scripts/lib/audio-analyze.mjs';
import { freePort } from './helpers/free-port.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const USER_TOKEN = 'test-user-token';
const ADMIN_TOKEN = 'test-admin-token';

const SHORT = 'sng_aaaaaaaaaaaa';   // every capture comes back short
const GOOD = 'sng_bbbbbbbbbbbb';    // captures fine (measured 223.0 s)
const PARTIAL = 'sng_cccccccccccc'; // already in the manifest as a 54.3 s fragment → repair target
const LONG = 'sng_dddddddddddd';    // in the manifest 120 s too long
const HEALTHY = 'sng_eeeeeeeeeeee'; // +13 s overrun → fine
const VINYL = 'sng_ffffffffffff';   // analog catalog song, cloud-captured → exempt
const BUSY = 'sng_999999999999';    // partial, but a stem job is in flight → refused
const WRONG = 'sng_777777777777';   // Music.app plays a different track → terminal, no retry
const DEAD = 'sng_888888888888';    // greyed-out library row (play-failed) → terminal, no retry

const CATALOG = {
  manifest: { sourceType: 'digital', sourceName: 'T' },
  albums: [],
  songs: [
    { id: SHORT, name: 'Short', artist: 'A', length: 221_043 },
    { id: GOOD, name: 'Good', artist: 'A', length: 221_043 },
    { id: PARTIAL, name: 'Partial', artist: 'A', length: 221_043 },
    { id: LONG, name: 'Long', artist: 'A', length: 90_673 },
    { id: HEALTHY, name: 'Healthy', artist: 'A', length: 155_000 },
    { id: BUSY, name: 'Busy', artist: 'A', length: 249_613 },
    { id: WRONG, name: 'Wrong', artist: 'A', length: 200_000 },
    { id: DEAD, name: 'Dead', artist: 'A', length: 200_000 },
  ],
};
const ANALOG_CATALOG = {
  manifest: { sourceType: 'analog', sourceName: 'Vinyl' },
  albums: [{ id: 'alb_v', name: 'V', artist: 'A' }],
  songs: [{ id: VINYL, albumId: 'alb_v', name: 'Vinyl', artist: 'A', length: 200_000 }],
};
const SEED = {
  [PARTIAL]: {
    source: 'digital', key: `rips/${PARTIAL}.mp3`, durationMs: 54_300, analyzed: true, rippedAt: 1, bpm: 120,
    waveform: `rips/waveforms/${PARTIAL}.png`, beatgrid: `rips/analysis/${PARTIAL}.json`,
    lyrics: `rips/lyrics/${PARTIAL}.json`, lyricsVersion: 1,
    stems: { vocals: `rips/stems/${PARTIAL}/vocals.mp3`, drums: `rips/stems/${PARTIAL}/drums.mp3`,
      bass: `rips/stems/${PARTIAL}/bass.mp3`, other: `rips/stems/${PARTIAL}/other.mp3` },
    stemVersion: 99, stemModel: 'htdemucs',
    timbre: `rips/timbre/v${TIMBRE_VERSION}/${PARTIAL}.json`, timbreVersion: TIMBRE_VERSION, timbreSrc: 's3-song',
  },
  [LONG]: { source: 'digital', key: `rips/${LONG}.mp3`, durationMs: 210_500, analyzed: true, rippedAt: 2,
    timbreVersion: TIMBRE_VERSION },
  [HEALTHY]: { source: 'digital', key: `rips/${HEALTHY}.mp3`, durationMs: 168_000, analyzed: true, rippedAt: 3,
    timbreVersion: TIMBRE_VERSION },
  [VINYL]: { source: 'digital', key: `rips/${VINYL}.mp3`, durationMs: 30_000, analyzed: true, rippedAt: 4,
    timbreVersion: TIMBRE_VERSION },
  [BUSY]: { source: 'digital', key: `rips/${BUSY}.mp3`, durationMs: 40_000, analyzed: true, rippedAt: 5,
    timbreVersion: TIMBRE_VERSION },
  amrec_1234: { source: 'digital', key: 'rips/amrec_1234.mp3', durationMs: 5_000, rippedAt: 6, timbreVersion: TIMBRE_VERSION },
};

let work, srv, base, manifestPath, awsLog, sqsDir, argsDir, serverLog = '';
const H = (tok) => ({ authorization: `Bearer ${tok}`, 'content-type': 'application/json' });
const post = (p, body, tok = ADMIN_TOKEN) => fetch(base + p, { method: 'POST', headers: H(tok), body: JSON.stringify(body) });
const disk = () => JSON.parse(readFileSync(manifestPath, 'utf8'));
const awsCalls = () => (existsSync(awsLog) ? readFileSync(awsLog, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
const spool = (q) => {
  const f = join(sqsDir, `${q}.ndjson`);
  return existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
};
const until = async (fn, ms = 15_000) => {
  const end = Date.now() + ms;
  for (;;) { const v = fn(); if (v || Date.now() > end) return v; await sleep(100); }
};

beforeAll(async () => {
  work = mkdtempSync(join(tmpdir(), 'pdj-lenguard-e2e-'));
  const shimDir = join(work, 'bin');
  sqsDir = join(work, 'sqs'); argsDir = join(work, 'args');
  for (const d of [shimDir, sqsDir, argsDir, join(work, 'home'), join(work, 'timbre-results')]) mkdirSync(d, { recursive: true });
  manifestPath = join(work, 'manifest.json');
  awsLog = join(work, 'aws.ndjson');
  writeFileSync(manifestPath, JSON.stringify(SEED));
  writeFileSync(join(shimDir, 'aws'),
    `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(join(REPO, 'scripts/test/fake-aws.mjs'))} "$@"\n`);
  chmodSync(join(shimDir, 'aws'), 0o755);
  // The durable timbre corpus already holds a (pre-repair) row for PARTIAL.
  writeFileSync(join(work, 'timbre-results', 'cloud.ndjson'),
    JSON.stringify({ id: PARTIAL, v: TIMBRE_VERSION, ok: true, src: 's3-song', atMs: 1000 }) + '\n');
  const digital = join(work, 'digital.json'); writeFileSync(digital, JSON.stringify(CATALOG));
  const analog = join(work, 'analog.json'); writeFileSync(analog, JSON.stringify(ANALOG_CATALOG));

  const env = {
    ...process.env,
    PATH: `${shimDir}:${dirname(process.execPath)}:/usr/bin:/bin`,
    HOME: join(work, 'home'),
    RIP_BUCKET: 'pocketdj-test-bucket',
    RIP_SOURCES: `${analog},${digital}`,
    RIP_PUBLIC_FOLD: '0',
    RIP_TOKEN: USER_TOKEN,
    RIP_ADMIN_TOKEN: ADMIN_TOKEN,
    RIP_WORKER: join(REPO, 'scripts/test/fake-length-worker.mjs'),
    RIP_MUSIC_HEAL: '0',
    RIP_TEST_MAX_ATTEMPTS: '2',
    RIP_TEST_BACKOFF_MS: '300,300',
    POCKETDJ_LIBRARY_XML: join(work, 'none.xml'),
    POCKETDJ_STEM_OFFLOAD: '1',
    POCKETDJ_AUTO_STEM_ON_RIP: '1',
    POCKETDJ_ANALYSIS_OFFLOAD: '1',
    POCKETDJ_LYRICS_OFFLOAD: '1',
    POCKETDJ_STEM_JOBS_QUEUE: 'https://sqs.test/pocketdj-stem-jobs',
    POCKETDJ_STEM_RESULTS_QUEUE: 'https://sqs.test/pocketdj-stem-results',
    POCKETDJ_STEM_DLQ_QUEUE: 'https://sqs.test/pocketdj-stem-dlq',
    POCKETDJ_TIMBRE_JOBS_QUEUE: 'https://sqs.test/pocketdj-timbre-jobs',
    POCKETDJ_TIMBRE_RESULTS_QUEUE: 'https://sqs.test/pocketdj-timbre-results',
    POCKETDJ_TIMBRE_DLQ_QUEUE: 'https://sqs.test/pocketdj-timbre-dlq',
    POCKETDJ_TIMBRE_RESULTS: join(work, 'timbre-results'),
    POCKETDJ_TIMBRE_SWEEP_MS: '86400000',
    FAKE_AWS_MANIFEST: manifestPath,
    FAKE_AWS_SQS_DIR: sqsDir,
    FAKE_AWS_LOG: awsLog,
    FAKE_LENGTH_ARGS_DIR: argsDir,
    FAKE_LENGTH_PLAN: JSON.stringify({
      [SHORT]: { outcome: 'short', measuredMs: 54_300 },
      [GOOD]: { outcome: 'ok', measuredMs: 223_000 },
      [PARTIAL]: { outcome: 'ok', measuredMs: 220_500 },
      [WRONG]: { outcome: 'refuse', reason: 'wrong-track' },
      [DEAD]: { outcome: 'refuse', reason: 'play-failed' },
    }),
  };
  for (let attempt = 1; ; attempt++) {
    const port = await freePort();
    base = `http://127.0.0.1:${port}`;
    serverLog = '';
    srv = spawn(process.execPath, [join(REPO, 'scripts/rip-server.mjs')],
      { env: { ...env, RIP_PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe'] });
    let dead = false;
    srv.on('exit', () => { dead = true; });
    srv.stdout.on('data', (d) => { serverLog += d; });
    srv.stderr.on('data', (d) => { serverLog += d; });
    let up = false;
    for (let i = 0; i < 200 && !dead && !up; i++) {
      try { up = (await fetch(`${base}/health`, { headers: H(USER_TOKEN) })).ok; } catch { /* not up */ }
      if (!up) await sleep(100);
    }
    if (up) break;
    try { srv.kill('SIGKILL'); } catch { /* gone */ }
    if (dead && /EADDRINUSE/.test(serverLog) && attempt < 5) continue;
    throw new Error(`rip-server never came up on ${base}\n--- server log ---\n${serverLog}`);
  }
}, 60_000);

afterAll(() => {
  try { srv?.kill('SIGKILL'); } catch { /* gone */ }
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('capture length guard — server wiring', () => {
  it('/health exposes the guard thresholds', async () => {
    const h = await (await fetch(`${base}/health`, { headers: H(USER_TOKEN) })).json();
    expect(h.lengthGuard).toMatchObject({ enabled: true, underRatio: 0.95, underSlackMs: 5000, overSlackMs: 20000 });
  });

  it('a short-capture is retried through the backoff ladder and NEVER registered', async () => {
    // Watch the durable queue record: during the backoff the retry must be on DISK with the
    // bumped attempt, or a restart in that window drops it (the queue file is keyed by songId).
    const qf = join(work, 'home', '.pocketdj', 'rips', 'queue', `${SHORT}.json`);
    let sawDurableRetry = false, watching = true;
    const watch = (async () => {
      while (watching && !sawDurableRetry) {
        try { sawDurableRetry = JSON.parse(readFileSync(qf, 'utf8')).attempt === 2; } catch { /* absent */ }
        await sleep(5);
      }
    })();
    const r = await (await post('/rip', { songId: SHORT }, USER_TOKEN)).json();
    expect(r.jobId).toBeTruthy();
    const gaveUp = await until(() => serverLog.includes(`gave-up ${SHORT}`));
    expect(gaveUp, serverLog).toBe(true);
    expect(serverLog).toContain(`✗ short-capture ${SHORT} attempt 1/2`);
    expect(serverLog).toContain(`retry-scheduled ${SHORT} attempt 2/2`);
    expect(serverLog).toContain(`✗ short-capture ${SHORT} attempt 2/2`);
    watching = false; await watch;
    expect(sawDurableRetry, 'retry record persisted to the durable queue during backoff').toBe(true);
    expect(existsSync(qf)).toBe(false); // terminal give-up drops it
    expect(disk()[SHORT]).toBeUndefined();
    // nothing downstream was fed the fragment
    expect(spool('pocketdj-stem-jobs').some((j) => j.songId === SHORT)).toBe(false);
  }, 30_000);

  it.each([['wrong-track', WRONG], ['play-failed', DEAD]])('a %s refusal is terminal: one attempt, no retry', async (reason, id) => {
    await post('/rip', { songId: id }, USER_TOKEN);
    const done = await until(() => serverLog.includes(`✗ ${reason} ${id} (terminal, not retried)`));
    expect(done, serverLog).toBe(true);
    await sleep(800); // longer than the test backoff (300 ms): a retry would have been scheduled by now
    expect(serverLog).not.toContain(`retry-scheduled ${id}`);
    expect(serverLog).not.toContain(`gave-up ${id}`); // not a give-up either: never transient
    expect(existsSync(join(work, 'home', '.pocketdj', 'rips', 'queue', `${id}.json`))).toBe(false);
    expect(disk()[id]).toBeUndefined();
  }, 20_000);

  it('an accepted capture registers its MEASURED length; the worker learns the expected-length source', async () => {
    await post('/rip', { songId: GOOD }, USER_TOKEN);
    const e = await until(() => disk()[GOOD]);
    expect(e).toMatchObject({ key: `rips/${GOOD}.mp3`, durationMs: 223_000, source: 'digital' });
    const a = JSON.parse(readFileSync(join(argsDir, `${GOOD}.json`), 'utf8'));
    expect(a).toMatchObject({ 'length-ms': '221043', 'length-source': 'catalog', 'source-type': 'digital' });
  }, 20_000);
});

describe('POST /rip-repair', () => {
  it('is ADMIN-tier', async () => {
    expect((await post('/rip-repair', {}, USER_TOKEN)).status).toBe(403);
  });

  it('audit (the default) lists short + long captures and exempts analog / no-catalog / healthy', async () => {
    const r = await (await post('/rip-repair', {})).json();
    expect(r.mode).toBe('audit');
    const ids = r.violations.map((v) => v.songId).sort();
    expect(ids).toEqual([BUSY, PARTIAL, LONG].sort());
    expect(r.violations.find((v) => v.songId === PARTIAL)).toMatchObject({ verdict: 'short', measuredMs: 54_300, expectedMs: 221_043 });
    expect(r.violations.find((v) => v.songId === LONG).reason).toBe('long-capture');
    expect(r.skipped).toMatchObject({ analogExempt: 1, noExpectedLength: 1 });
    // a dry run changes nothing
    expect(disk()[PARTIAL].durationMs).toBe(54_300);
    expect(awsCalls().some((c) => c[0] === 's3' && c[1] === 'rm')).toBe(false);
  });

  it('apply needs explicit songIds (or all:true)', async () => {
    expect((await post('/rip-repair', { apply: true })).status).toBe(400);
  });

  it('apply: refuses in-flight and healthy ids, deletes exactly the target\'s artifacts, re-rips it with dedup OFF', async () => {
    // put BUSY in flight: a stem job offloaded and awaiting its cloud result
    const st = await (await post('/stemify', { songId: BUSY }, USER_TOKEN)).json();
    expect(st.phase).toMatch(/queued|stemming/);
    const stemJobsBefore = spool('pocketdj-stem-jobs').length;
    const timbreJobsBefore = spool('pocketdj-timbre-jobs').length;

    const r = await (await post('/rip-repair', { apply: true, songIds: [PARTIAL, BUSY, HEALTHY, 'sng_000000000000'] })).json();
    const by = Object.fromEntries(r.results.map((x) => [x.songId, x]));
    expect(by[BUSY]).toMatchObject({ status: 'refused', reason: 'in-flight' });
    expect(by[HEALTHY]).toMatchObject({ status: 'refused', reason: 'passes-length-guard' });
    expect(by.sng_000000000000).toMatchObject({ status: 'refused', reason: 'not-in-manifest' });
    expect(by[PARTIAL]).toMatchObject({ status: 'repaired', rip: 'queued', errors: [] });

    // deletes: the rip and EVERY derived artifact — and nothing belonging to any other song
    const rms = awsCalls().filter((c) => c[0] === 's3' && c[1] === 'rm');
    const targets = rms.map((c) => c[2].replace('s3://pocketdj-test-bucket/', ''));
    for (const k of [`rips/${PARTIAL}.mp3`, `rips/analysis/${PARTIAL}.json`, `rips/waveforms/${PARTIAL}.png`,
      `rips/lyrics/${PARTIAL}.json`, `rips/timbre/v${TIMBRE_VERSION}/${PARTIAL}.json`, `rips/stems/${PARTIAL}/`]) {
      expect(targets).toContain(k);
    }
    expect(rms.find((c) => c[2].endsWith(`rips/stems/${PARTIAL}/`))).toContain('--recursive');
    expect(targets.every((k) => k.includes(PARTIAL))).toBe(true);

    // the re-rip lands with a fresh, MEASURED entry — no stale derived fields carried over
    const e = await until(() => (disk()[PARTIAL]?.durationMs === 220_500 ? disk()[PARTIAL] : null));
    expect(e, serverLog).toBeTruthy();
    for (const f of ['stems', 'lyrics', 'waveform', 'beatgrid', 'timbre', 'timbreVersion', 'bpm']) expect(e[f]).toBeUndefined();

    // re-offloads are NOT deduped away
    const stemJob = await until(() => spool('pocketdj-stem-jobs').slice(stemJobsBefore).find((j) => j.songId === PARTIAL && j.tasks?.includes('stems')));
    expect(stemJob).toMatchObject({ dedup: false });
    const analysisJob = await until(() => spool('pocketdj-stem-jobs').slice(stemJobsBefore).find((j) => j.songId === PARTIAL && j.tasks?.includes('analysis')));
    expect(analysisJob).toBeTruthy();
    const timbreJob = await until(() => spool('pocketdj-timbre-jobs').slice(timbreJobsBefore).find((j) => j.songs?.some((s) => s.id === PARTIAL)));
    expect(timbreJob).toMatchObject({ dedup: false });

    // durable repair record (drives dedup-off + pre-repair timbre-row filtering across restarts)
    const rec = JSON.parse(readFileSync(join(work, 'home', '.pocketdj', 'rips', 'repaired.json'), 'utf8'));
    expect(rec[PARTIAL]).toMatchObject({ stems: true, lyrics: true, timbre: true });
    expect(rec[PARTIAL].rip).toBe(false);   // cleared by the successful re-rip
    expect(serverLog).toContain(`REPAIR re-ripped ${PARTIAL}`);
  }, 30_000);

  it('a stems result for the repaired song clears its stems lane (fresh, non-dedup)', async () => {
    writeFileSync(join(sqsDir, 'pocketdj-stem-results.inbox.ndjson'), JSON.stringify({
      songId: PARTIAL, ok: true, stems: { vocals: `rips/stems/${PARTIAL}/vocals.mp3` }, stemModel: 'htdemucs', stemVersion: 99,
    }) + '\n');
    const cleared = await until(() => {
      try { return JSON.parse(readFileSync(join(work, 'home', '.pocketdj', 'rips', 'repaired.json'), 'utf8'))[PARTIAL].stems === false; }
      catch { return false; }
    });
    expect(cleared, serverLog).toBe(true);
  }, 20_000);
});
