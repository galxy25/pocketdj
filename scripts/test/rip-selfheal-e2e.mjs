#!/usr/bin/env node
// End-to-end test of the rip-server SELF-HEALING queue: the per-job duration-aware
// watchdog, the transient-vs-permanent failure classifier + capped exponential-backoff
// retry, and pump robustness (the queue always advances; a backoff retry never blocks the
// worker). Boots the real rip-server with a temp catalog, the fake `aws` shim, SELECTABLE
// fake digital workers, and TEST-OVERRIDDEN tiny timeouts/backoff so a hang/retry cycle
// runs in seconds. Asserts:
//   (a) a job whose worker NEVER finishes is watchdog-killed, and the NEXT queued job runs.
//   (b) a TRANSIENT-failing job is retried with backoff, then given up after the cap.
//   (c) a PERMANENT failure (unknown song) is not retried (rejected at accept time).
//   (d) a CANCELED job is not retried (no requeue after /rip-cancel).
//
//   node scripts/test/rip-selfheal-e2e.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync, mkdirSync, rmSync, chmodSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8805;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://localhost:${PORT}`;
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-selfheal-'));

// ---- catalog: four DIGITAL songs (each routes through runDigitalJob → the fake worker) ----
const HANG = 'sng_hang';        // worker never finishes → watchdog kills it
const GOOD = 'sng_good';        // worker uploads → proves the queue advanced past the kill
const TRANSIENT = 'sng_trans';  // worker fails transiently every time → retried then given up
const CANCELED = 'sng_cancel';  // queued, then /rip-cancel → must NOT be retried
const UNKNOWN = 'sng_unknown';  // not in catalog → permanent (not retried)

const digitalCatalog = join(work, 'digital.json');
writeFileSync(digitalCatalog, JSON.stringify({
  manifest: { sourceType: 'digital', sourceName: 'Test' },
  albums: [{ id: 'alb_dig', artist: 'Digi', name: 'Digital Album', trackList: [HANG, GOOD, TRANSIENT, CANCELED] }],
  songs: [
    { id: HANG, albumId: 'alb_dig', artist: 'Digi', name: 'Hang', length: 4000 },
    { id: GOOD, albumId: 'alb_dig', artist: 'Digi', name: 'Good', length: 4000 },
    { id: TRANSIENT, albumId: 'alb_dig', artist: 'Digi', name: 'Transient', length: 4000 },
    { id: CANCELED, albumId: 'alb_dig', artist: 'Digi', name: 'Cancel', length: 4000 },
  ],
}));

// ---- fake `aws` shim (deterministic empty manifest; uploads succeed) ----
const shimDir = join(work, 'bin');
mkdirSync(shimDir, { recursive: true });
const awsShim = join(shimDir, 'aws');
writeFileSync(awsShim, `#!/bin/sh\nexec node ${JSON.stringify(join(REPO, 'scripts/test/fake-aws.mjs'))} "$@"\n`);
chmodSync(awsShim, 0o755);

// ---- selectable fake digital worker: behaviour by song-id (no Music/Audio Hijack/S3) ----
// HANG: never exits (tests the watchdog). GOOD: writes uploaded+key (success). everything
// else: writes a transient error (no upload). It also appends one line per invocation to
// a per-song counter file so the test can count retry attempts.
const worker = join(work, 'worker.mjs');
writeFileSync(worker, `
import { writeFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
const a = {}; for (let i=2;i<process.argv.length;i++){const k=process.argv[i];if(k.startsWith('--'))a[k.slice(2)]=process.argv[++i];}
const SONG = a['song-id'];
const COUNTS = process.env.RIP_TEST_COUNTS_DIR;
if (COUNTS) appendFileSync(join(COUNTS, SONG + '.log'), 'x');
if (SONG === ${JSON.stringify(HANG)}) {
  // simulate a stuck capture: report ripping, then hang forever (until the watchdog kills us).
  writeFileSync(a.status, JSON.stringify({ songId: SONG, phase: 'ripping', realtime: true, ripStartedAt: Date.now(), totalMs: 4000, updatedAt: Date.now() }));
  setInterval(() => {}, 1000); // never exit
} else if (SONG === ${JSON.stringify(GOOD)}) {
  const key = 'rips/' + SONG + '.mp3';
  writeFileSync(a.status, JSON.stringify({ songId: SONG, phase: 'uploaded', key, bytes: 4242, updatedAt: Date.now() }));
  console.log('RESULT ' + JSON.stringify({ ok: true, key, bytes: 4242 }));
} else {
  // transient failure (no upload) — server classifies this as retryable.
  writeFileSync(a.status, JSON.stringify({ songId: SONG, phase: 'error', error: 'capture failed (transient)', reason: 'system', updatedAt: Date.now() }));
  console.log('RESULT ' + JSON.stringify({ ok: false, error: 'capture failed (transient)' }));
}
`);

const countsDir = join(work, 'counts');
mkdirSync(countsDir, { recursive: true });
const attempts = (songId) => { try { return readFileSync(join(countsDir, songId + '.log'), 'utf8').length; } catch { return 0; } };

const env = {
  ...process.env,
  PATH: `${shimDir}:${process.env.PATH}`,
  RIP_PORT: String(PORT),
  RIP_BUCKET: 'pocketdj-test-bucket',
  RIP_SOURCES: digitalCatalog,
  RIP_WORKER: worker,
  HOME: join(work, 'home'),
  RIP_TEST_COUNTS_DIR: countsDir,
  // shrink the watchdog + backoff so the whole self-heal cycle runs in seconds.
  RIP_TEST_DIGITAL_BUFFER_MS: '1500',   // digital deadline ≈ len*1.5 + 1.5s
  RIP_TEST_DIGITAL_FLOOR_MS: '1500',
  RIP_TEST_ANALOG_CAP_MS: '8000',
  RIP_TEST_MAX_ATTEMPTS: '3',           // 1 original + 2 retries, then give up
  RIP_TEST_BACKOFF_MS: '600,600,600',   // ~0.6s between retries
};

const post = async (path, body) => {
  const r = await fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json().catch(() => null) };
};
const getStatus = async (songId) => (await fetch(`${base}/status/${songId}`)).json();
const waitUp = async () => { for (let i = 0; i < 60; i++) { try { if ((await fetch(`${base}/health`)).ok) return true; } catch {} await sleep(200); } return false; };
const waitReady = async (songId, ms) => { const end = Date.now() + ms; while (Date.now() < end) { const s = await getStatus(songId); if (s.ready) return s; await sleep(150); } return await getStatus(songId); };
const waitPhase = async (songId, phase, ms) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { const s = await getStatus(songId); if (!s.ready && s.job && s.job.phase === phase) return s; await sleep(150); }
  return await getStatus(songId);
};

console.log('booting rip-server (self-healing, tiny timeouts/backoff)…');
const srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });

try {
  ok(await waitUp(), 'server is up (/health)');

  // ===== (a) watchdog: HANG never finishes → killed; the NEXT queued job (GOOD) runs =====
  // Enqueue HANG first, GOOD right after. Concurrency-1: GOOD can only run once the watchdog
  // kills HANG and the worker is released. GOOD becoming ready PROVES the queue advanced.
  await post('/rip', { songId: HANG });
  await post('/rip', { songId: GOOD });
  // HANG deadline ≈ 4000*1.5 + 1500 = 7500ms; allow margin + GOOD's run + a possible HANG retry.
  const sGood = await waitReady(GOOD, 30000);
  ok(sGood.ready === true, `(a) NEXT queued job (GOOD) ran after the hang was watchdog-killed (ready=${sGood.ready})`);
  ok(attempts(HANG) >= 1, `(a) the hang worker WAS spawned/killed (attempts=${attempts(HANG)})`);

  // ===== (a2) watchdog-timeout RETRY: a DIGITAL job that HANGS on EVERY attempt must be
  // RE-RUN (retried) after each timeout kill — exactly maxAttempts spawns, then given up —
  // mirroring the transient-failure assertion (b). This catches the timeout-retry bug where
  // the orphaned killed-worker continuation wiped the retry's inflight entry, silently
  // dropping the retry (the worker would be spawned only ONCE). Each HANG attempt costs a
  // full ~7.5s deadline + ~0.6s backoff, so 3 attempts span ~24s; wait generously.
  // Wait until the 3rd (final) attempt has been spawned AND its watchdog has killed it +
  // the give-up fired (no active job remains). Each attempt: ~7.5s deadline + ~0.6s backoff.
  const aEnd = Date.now() + 45000;
  while (Date.now() < aEnd) { const s = await getStatus(HANG); if (attempts(HANG) >= 3 && !s.job) break; await sleep(200); }
  await sleep(2000); // past a full deadline+backoff window — a given-up job must NOT spawn a 4th time
  ok(attempts(HANG) === 3, `(a2) hung DIGITAL job retried exactly maxAttempts=3 times (timeout-retry fires) then stopped (got ${attempts(HANG)})`);
  const sHang = await getStatus(HANG);
  ok(!sHang.ready && !sHang.job, `(a2) after the cap the hung job is terminal — no active job, never ready (ready=${sHang.ready}, job=${sHang.job})`);

  // ===== (b) transient failure → retried with backoff, then given up after the cap =====
  const tAccept = await post('/rip', { songId: TRANSIENT });
  const tJobId = tAccept.body?.jobId;
  // maxAttempts=3 → exactly 3 worker spawns, then a terminal give-up. Each is ~instant + 0.6s backoff.
  // Wait until the attempt counter settles at the cap AND no retry is pending (it stays put).
  const end = Date.now() + 20000;
  while (Date.now() < end) { if (attempts(TRANSIENT) >= 3) break; await sleep(100); }
  await sleep(1500); // past a full backoff window — a given-up job must NOT spawn a 4th time
  ok(attempts(TRANSIENT) === 3, `(b) transient job tried exactly maxAttempts=3 times then stopped (got ${attempts(TRANSIENT)})`);
  // terminal give-up: no ACTIVE (non-terminal) job remains for this song, and it never readied.
  const sTrans = await getStatus(TRANSIENT);
  ok(!sTrans.ready && !sTrans.job, `(b) after the cap the job is terminal — no active job, never ready (ready=${sTrans.ready}, job=${sTrans.job})`);
  // after give-up, inflight is released: a fresh /rip is accepted as a NEW job (different jobId).
  const reaccept = await post('/rip', { songId: TRANSIENT });
  const newPhase = reaccept.body?.phase;
  ok(reaccept.body && reaccept.body.jobId && reaccept.body.jobId !== tJobId && newPhase !== 'ready',
    `(b) after give-up the song is re-acceptable as a NEW job (jobId=${reaccept.body?.jobId} != ${tJobId}, phase=${newPhase})`);
  // (that re-accepted job will just retry+giveup again harmlessly in the background)

  // ===== (c) permanent failure (unknown song) is not retried =====
  const unk = await post('/rip', { songId: UNKNOWN });
  ok(unk.status === 404, `(c) unknown song → 404 at accept (permanent, never queued/retried) (got ${unk.status})`);
  ok(attempts(UNKNOWN) === 0, `(c) no worker was ever spawned for the unknown song (attempts=${attempts(UNKNOWN)})`);

  // ===== (d) a canceled job is not retried =====
  // Queue CANCELED behind a job that is currently working so it sits in the queue, then cancel
  // it. A canceled queued job must never reach the worker and must never be requeued.
  // Re-enqueue TRANSIENT (it'll occupy the worker), then CANCELED queues behind it; cancel CANCELED.
  await post('/rip', { songId: CANCELED });
  // CANCELED may be running or queued; cancel it either way.
  await sleep(50);
  const before = attempts(CANCELED);
  const cancel = await post('/rip-cancel', { songIds: [CANCELED] });
  const cres = (cancel.body?.results || []).find((x) => x.songId === CANCELED);
  ok(cres && cres.status === 'canceled', `(d) /rip-cancel reports 'canceled' (got ${cres?.status})`);
  // wait well past a full backoff cycle: a canceled job must NOT be requeued/re-run.
  await sleep(3000);
  const after = attempts(CANCELED);
  ok(after <= before + 1, `(d) canceled job was NOT retried (attempts before=${before} after=${after}, no requeue)`);
  const sc = await getStatus(CANCELED);
  ok(!sc.ready, `(d) canceled job never became ready (ready=${sc.ready})`);

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all self-heal checks passed'}`);
} finally {
  srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
