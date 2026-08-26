#!/usr/bin/env node
// CLOUD TIMBRE WORKER — the EC2 side of the timbre offload. Mirrors scripts/stem-worker.mjs
// (SQS claim → work → post result → delete; idle-exit → shutdown → instance-terminate) but for
// the 14-axis timbre vector, and on its OWN arm64 fleet.
//
// ── WHY A SECOND FLEET AND NOT A `tasks:['timbre']` BRANCH IN stem-worker.mjs ──────────────────
//  1. ARCHITECTURE. The 12,395 existing vectors were measured inside the arm64 pocketdj-audio
//     image. The stem fleet is x86_64 m7i. It cannot run that image without qemu.
//  2. UNPINNED ENVIRONMENT. stem-worker-userdata.sh `pip install`s librosa unpinned, at boot,
//     outside Docker. That produces plausible vectors in a DIFFERENT numeric space. Reusing the
//     stem lane's TRANSPORT is right; reusing its python environment is the one thing that would
//     break the numerical-identity constraint.
//  3. WARM BATCH. One SQS message per song = one python process per song = exactly the 14 s cold
//     path scripts/timbre-warm-worker.py exists to avoid (93 % of naive per-song cost is warm-up).
// Everything else IS reused: the queue/redrive shape, the bounded dispatcher on the server side,
// the results pump, the DLQ drain, the autoscaler, and the worker-side song-id dedup.
//
// ── THE PARITY ARGUMENT ────────────────────────────────────────────────────────────────────────
// This worker does NOT re-implement analysis. It writes the batch to a tasks file and runs the
// SAME driver that measured the existing corpus — `timbre-batch.mjs --tasks` — inside the SAME
// pocketdj-audio image (loaded from a `docker save` tarball of the very image the Mac used, its
// digest asserted at boot), with the SAME ranged 5 MB GET and the SAME 90 s window. The result
// rows it uploads are byte-for-byte the rows scripts/fold-timbre.mjs already consumes.
//
// Job body (pocketdj-timbre-jobs):
//   {kind:'timbre', v:1, batchId, songs:[{id, key}, …], dedup?:false, outPrefix?:'rips/timbre/'}
// Result body (pocketdj-timbre-results):
//   {ok:true, kind:'timbre', batchId, timbreVersion, workerSeconds, instanceId, image,
//    songs:[{id, ok, key?, deduped?, permanent?, error?}, …]}
// The VECTOR is never in the SQS body — the S3 sidecar is the source of truth and the message
// stays small. Sidecars are uploaded AS EACH SONG FINISHES, so a scaled-in or crashed worker
// loses nothing: the message redelivers and the dedup listing skips what already landed.
//
// Modes:
//   node timbre-worker.mjs --serve        long-running SQS consumer; idle-exit → self-terminate
//   node timbre-worker.mjs --poll         process at most one SQS message, then exit
//   node timbre-worker.mjs --once <file>  run a local tasks file (no SQS) — smoke test
//
// Env: POCKETDJ_RIPS_BUCKET, AWS_REGION, POCKETDJ_TIMBRE_JOBS_QUEUE,
//   POCKETDJ_TIMBRE_RESULTS_QUEUE, POCKETDJ_TIMBRE_SHARDS, POCKETDJ_TIMBRE_VISIBILITY,
//   POCKETDJ_TIMBRE_IDLE_SECONDS, POCKETDJ_TIMBRE_OUT_PREFIX, AUDIO_IMAGE.
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, existsSync, readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { TIMBRE_VERSION } from './lib/audio-analyze.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CFG = {
  bucket: process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623',
  region: process.env.AWS_REGION || 'us-west-2',
  jobsQueue: process.env.POCKETDJ_TIMBRE_JOBS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-timbre-jobs',
  resultsQueue: process.env.POCKETDJ_TIMBRE_RESULTS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-timbre-results',
  visibility: Number(process.env.POCKETDJ_TIMBRE_VISIBILITY || 1800),
  idleSeconds: Number(process.env.POCKETDJ_TIMBRE_IDLE_SECONDS || 120),
  shards: Number(process.env.POCKETDJ_TIMBRE_SHARDS || 8),
  outPrefix: process.env.POCKETDJ_TIMBRE_OUT_PREFIX || 'rips/timbre/',
  image: process.env.AUDIO_IMAGE || 'pocketdj-audio:latest',
  driver: process.env.POCKETDJ_TIMBRE_DRIVER || join(HERE, 'timbre-batch.mjs'),
  maxErrors: Number(process.env.POCKETDJ_TIMBRE_MAX_ERRORS || 20),
};
// Variant ids (`sng_<12hex>_explicit`) are minted by rip-server's VARIANT_ID and keyed through the
// whole pipeline. stem-worker.mjs's regex rejects them — a live bug that has been dead-lettering
// those songs' stems. Accept them here.
export const TIMBRE_SONG_ID = /^(?:sng_[0-9a-f]{12}|amrec_\d+)(?:_explicit|_clean)?$/;
const aws = (...args) => execFileSync('aws', [...args, '--region', CFG.region], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
const log = (...m) => process.stderr.write(`[timbre-worker] ${m.join(' ')}\n`);

// Sidecars are VERSION-PREFIXED, so dedup is a plain key-existence check (no GET-and-inspect) and
// a TIMBRE_VERSION bump automatically invalidates every existing sidecar without a sweep.
export const sidecarKey = (id, prefix = CFG.outPrefix, v = TIMBRE_VERSION) => `${prefix}v${v}/${id}.json`;

let instanceId = null;
function whoAmI() {
  if (instanceId != null) return instanceId;
  try {                                  // IMDSv2 (the launch template requires a token)
    const tok = execFileSync('curl', ['-sf', '-X', 'PUT', 'http://169.254.169.254/latest/api/token',
      '-H', 'X-aws-ec2-metadata-token-ttl-seconds: 60'], { encoding: 'utf8', timeout: 3000 });
    instanceId = execFileSync('curl', ['-sf', 'http://169.254.169.254/latest/meta-data/instance-id',
      '-H', `X-aws-ec2-metadata-token: ${tok}`], { encoding: 'utf8', timeout: 3000 }).trim();
  } catch { instanceId = 'local'; }
  return instanceId;
}
function imageDigest() {
  try { return execFileSync('docker', ['image', 'inspect', '--format', '{{.Id}}', CFG.image], { encoding: 'utf8' }).trim(); }
  catch { return null; }
}

// WORKER-SIDE SONG-ID DEDUP, the existingStems() pattern — but ONE prefix listing per batch
// instead of one `s3 ls` per song (a 50-song batch would otherwise fork 50 aws processes).
function existingIds(prefix) {
  const done = new Set();
  let out;
  try {
    // NO --max-items / --page-size: with neither set the CLI auto-paginates and aggregates EVERY
    // page before applying --query. Passing --max-items instead caps the result and hides the
    // continuation token behind --query, which would silently degrade dedup to "the first N keys"
    // the moment the corpus outgrew that cap — a bug that gets worse exactly as the corpus grows.
    out = aws('s3api', 'list-objects-v2', '--bucket', CFG.bucket,
      '--prefix', `${prefix}v${TIMBRE_VERSION}/`, '--query', 'Contents[].Key', '--output', 'json');
  } catch { return done; }          // listing failed → dedup off for this batch (re-analysis is safe)
  let keys = [];
  try { keys = JSON.parse(out || '[]') || []; } catch { keys = []; }
  for (const k of keys) { const m = /([^/]+)\.json$/.exec(k); if (m) done.add(m[1]); }
  return done;
}

/// Pure: split a job's song list into {todo, deduped} given the set of ids already on S3.
export function planBatch(songs, doneIds, { dedup = true } = {}) {
  const todo = []; const deduped = []; const bad = [];
  const seen = new Set();
  for (const s of songs || []) {
    const id = s && s.id;
    if (!id || !TIMBRE_SONG_ID.test(id)) { bad.push({ id: id ?? null, ok: false, permanent: true, error: 'bad songId' }); continue; }
    if (!s.key) { bad.push({ id, ok: false, permanent: true, error: 'no source key' }); continue; }
    if (seen.has(id)) continue;
    seen.add(id);
    if (dedup !== false && doneIds.has(id)) { deduped.push(id); continue; }
    todo.push({ id, kind: s.kind === 's3-cut' ? 's3-cut' : 's3-song', key: s.key });
  }
  return { todo, deduped, bad };
}

// Upload one result row as its own sidecar. The row IS the NDJSON shape fold-timbre.mjs consumes;
// `by`/`image`/`instance` ride along as provenance the fold ignores but an audit can read.
function uploadSidecar(row, prefix, work, digest) {
  const key = sidecarKey(row.id, prefix);
  const f = join(work, 'sidecar.json');
  writeFileSync(f, JSON.stringify({ ...row, by: 'cloud', image: digest, instance: whoAmI() }));
  aws('s3', 'cp', f, `s3://${CFG.bucket}/${key}`, '--content-type', 'application/json', '--only-show-errors');
  return key;
}

/// Run the SAME driver the local corpus was measured with, over a tasks file, uploading each
/// song's sidecar the moment its row lands. Returns the per-song summary rows.
async function runDriver(todo, { prefix, work }) {
  const stateDir = join(work, 'state');
  const resultsDir = join(stateDir, 'results');
  mkdirSync(resultsDir, { recursive: true });
  const tasksFile = join(work, 'tasks.json');
  writeFileSync(tasksFile, JSON.stringify(todo));
  const digest = imageDigest();
  const shards = Math.max(1, Math.min(CFG.shards, todo.length));

  const uploaded = new Map();      // id -> summary row
  const sweep = () => {
    for (const f of readdirSync(resultsDir)) {
      if (!f.endsWith('.ndjson')) continue;
      for (const line of readFileSync(join(resultsDir, f), 'utf8').split('\n')) {
        if (!line.trim()) continue;
        let r; try { r = JSON.parse(line); } catch { continue; }   // torn tail — next sweep sees it whole
        if (!r.id || uploaded.has(r.id)) continue;
        if (r.ok && r.f) {
          try { uploaded.set(r.id, { id: r.id, ok: true, key: uploadSidecar(r, prefix, work, digest) }); }
          catch (e) { log(`upload ${r.id} failed: ${e.message}`); }   // retried on the next sweep
        } else if (r.permanent) {
          // Engine ran, nothing usable (too-short/undecodable). Record it as a sidecar too, so a
          // redelivery dedups it instead of re-running a song that can never succeed.
          try { uploaded.set(r.id, { id: r.id, ok: false, permanent: true, error: r.error || 'no vector', key: uploadSidecar(r, prefix, work, digest) }); }
          catch (e) { log(`upload ${r.id} failed: ${e.message}`); }
        }
      }
    }
  };

  await new Promise((res, rej) => {
    const p = spawn(process.execPath, [CFG.driver, '--tasks', tasksFile, '--shards', String(shards),
      '--state-dir', stateDir, '--profile', '-'],
      { env: { ...process.env, AUDIO_IMAGE: CFG.image }, stdio: ['ignore', 'inherit', 'inherit'] });
    const tick = setInterval(sweep, 3000);
    p.on('error', (e) => { clearInterval(tick); rej(e); });
    p.on('close', (code) => { clearInterval(tick); code === 0 ? res() : rej(new Error(`timbre-batch exit ${code}`)); });
  });
  sweep();                                   // final pass picks up the last songs
  return [...uploaded.values()];
}

/// Process ONE job body. Anything not uploaded is reported ok:false WITHOUT `permanent`, so the
/// server can re-enqueue it; the message itself is only deleted by the caller on success.
export async function processJob(body) {
  const t0 = Date.now();
  const prefix = typeof body.outPrefix === 'string' && body.outPrefix ? body.outPrefix : CFG.outPrefix;
  const doneIds = body.dedup === false ? new Set() : existingIds(prefix);
  const { todo, deduped, bad } = planBatch(body.songs, doneIds, { dedup: body.dedup });
  const work = join(tmpdir(), `timbre-${body.batchId || Date.now()}`);
  rmSync(work, { recursive: true, force: true });
  mkdirSync(work, { recursive: true });
  log(`batch ${body.batchId}: ${todo.length} to run, ${deduped.length} deduped, ${bad.length} rejected`);
  try {
    const rows = todo.length ? await runDriver(todo, { prefix, work }) : [];
    const byId = new Map(rows.map((r) => [r.id, r]));
    const songs = [
      ...deduped.map((id) => ({ id, ok: true, key: sidecarKey(id, prefix), deduped: true })),
      ...bad,
      ...todo.map((t) => byId.get(t.id) || { id: t.id, ok: false, error: 'no result row (stage failed)' }),
    ];
    return {
      ok: true, kind: 'timbre', v: 1, batchId: body.batchId || null, timbreVersion: TIMBRE_VERSION,
      workerSeconds: Math.round((Date.now() - t0) / 1000), instanceId: whoAmI(), image: imageDigest(),
      songs,
    };
  } finally { rmSync(work, { recursive: true, force: true }); }
}

/// Receive ONE job, process it, post the result, delete the job. Returns a DISCRIMINATED state —
/// stem-worker.mjs returns [] for BOTH "queue empty" and "receive failed", so a run of failures
/// reads as idleness and the worker retires holding its claims. Never copy that.
export async function poll() {
  let out;
  try {
    out = aws('sqs', 'receive-message', '--queue-url', CFG.jobsQueue, '--max-number-of-messages', '1',
      '--wait-time-seconds', '20', '--visibility-timeout', String(CFG.visibility), '--output', 'json');
  } catch (e) { return { state: 'error', error: e.message }; }
  const msg = ((JSON.parse(out || '{}').Messages) || [])[0];
  if (!msg) return { state: 'empty' };
  let body = {};
  try { body = JSON.parse(msg.Body); } catch { /* malformed */ }
  if (body.kind && body.kind !== 'timbre') {
    // Not ours. Leave it UNDELETED rather than swallowing another lane's work silently.
    log(`ignoring kind=${body.kind} message — left on queue`);
    return { state: 'error', error: `foreign kind ${body.kind}` };
  }
  if (!Array.isArray(body.songs) || !body.songs.length) {
    try { aws('sqs', 'delete-message', '--queue-url', CFG.jobsQueue, '--receipt-handle', msg.ReceiptHandle); } catch { /* ignore */ }
    return { state: 'empty' };
  }
  try {
    const r = await processJob(body);
    execFileSync('aws', ['sqs', 'send-message', '--queue-url', CFG.resultsQueue,
      '--message-body', JSON.stringify(r), '--region', CFG.region], { stdio: 'ignore' });
    aws('sqs', 'delete-message', '--queue-url', CFG.jobsQueue, '--receipt-handle', msg.ReceiptHandle);
    const okN = r.songs.filter((s) => s.ok).length;
    log(`batch ${r.batchId} done in ${r.workerSeconds}s — ${okN}/${r.songs.length} ok`);
    return { state: 'work', result: r };
  } catch (e) {
    log(`batch ${body.batchId} FAILED: ${e.message} — leaving for retry/DLQ`);
    return { state: 'error', error: e.message };
  }
}

export async function serve({ pollFn = poll, now = () => Date.now(),
                             sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  let lastActivity = now();
  let total = 0; let errors = 0;
  log(`SQS consumer on ${CFG.jobsQueue.split('/').pop()}; ${CFG.shards} shards; idle-exit after ${CFG.idleSeconds}s`);
  for (;;) {
    let r;
    try { r = await pollFn(); } catch (e) { r = { state: 'error', error: e.message }; }
    if (r.state === 'work') { total += 1; errors = 0; lastActivity = now(); continue; }
    if (r.state === 'error') {
      // An ERROR IS ACTIVITY, not idleness: a worker must not retire (dropping its claims) just
      // because SQS or a batch is failing. It exits loudly after maxErrors consecutive failures.
      errors += 1; lastActivity = now();
      log(`poll error ${errors}/${CFG.maxErrors}: ${r.error}`);
      if (errors >= CFG.maxErrors) { log('too many consecutive errors — exiting'); return { total, errors, fatal: true }; }
      // A fast-failing receive skips the 20 s long poll, so back off rather than spin hot.
      await sleep(Math.min(30_000, 1000 * errors));
      continue;
    }
    if ((now() - lastActivity) / 1000 >= CFG.idleSeconds) { log(`idle ${CFG.idleSeconds}s — retiring after ${total} batch(es)`); break; }
  }
  return { total, errors, fatal: false };
}

async function main() {
  const arg = process.argv[2];
  if (arg === '--serve') { const r = await serve(); console.log(JSON.stringify({ ok: !r.fatal, served: r.total })); if (r.fatal) process.exit(1); return; }
  if (arg === '--poll') { const r = await poll(); console.log(JSON.stringify({ ok: r.state !== 'error', state: r.state })); return; }
  if (arg === '--once') {
    const songs = JSON.parse(readFileSync(process.argv[3], 'utf8'));
    console.log(JSON.stringify(await processJob({ batchId: 'local', songs: Array.isArray(songs) ? songs : songs.songs, dedup: false })));
    return;
  }
  log('usage: timbre-worker.mjs --serve | --poll | --once <tasks.json>');
  process.exit(2);
}

if (process.argv[1] && process.argv[1].endsWith('timbre-worker.mjs')) {
  main().catch((e) => { log('FATAL', e.message); process.exit(1); });
}
