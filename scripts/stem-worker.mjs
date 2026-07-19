#!/usr/bin/env node
// Cloud stem worker — runs OFF the Mac, on any Linux box that has: awscli, ffmpeg, and a
// python venv with `demucs` installed. It pulls a ripped song's mp3 from the PUBLIC rips
// bucket, runs Demucs (htdemucs, CPU or GPU), uploads the 4 stems to
// rips/stems/<songId>/<stem>.<ext>, and prints ONE JSON result line so a coordinator can
// stamp the manifest. This decouples stem separation from the single serial capture rig on
// the iMac: today scripts/rip-server.mjs runs stems inline on the same box and
// realtimeCaptureActive() BLOCKS them during a capture (thermal/CPU contention) — moving
// them here lets N cloud workers stem in parallel while the Mac does nothing but capture.
//
// It deliberately mirrors scripts/lib/audio-stem.mjs's demucs contract (same STEM_* env, same
// separate-one.py, same S3 key scheme) so the two paths stay interchangeable.
//
// Modes:
//   node stem-worker.mjs <songId>     one-shot: process one song, print result JSON, exit
//   node stem-worker.mjs --poll       queue mode: claim + process jobs from rips/stem-jobs/*.job.json
//                                     until drained (best-effort S3 queue; production would use SQS)
//
// Env:
//   POCKETDJ_RIPS_BUCKET   S3 bucket (default pocketdj-rips-011183829623)
//   AWS_REGION             (default us-west-2). AWS creds come from the instance role / env / config.
//   POCKETDJ_DEMUCS_MODEL  demucs model (default htdemucs)
//   POCKETDJ_STEM_DEVICE   cpu | cuda | mps (default cpu — this box has no Apple GPU)
//   POCKETDJ_STEM_FORMAT   mp3 | flac (default mp3)
//   POCKETDJ_STEM_BITRATE  mp3 kbps (default 256)
//   POCKETDJ_STEM_VENV     path to the python venv whose `python` has demucs (default ~/venv-stems)
//   POCKETDJ_STEM_PY       path to separate-one.py (default: sibling ./separate-one.py)
import { spawn } from 'node:child_process';
import { execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, copyFileSync, existsSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir, tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const CFG = {
  bucket: process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623',
  region: process.env.AWS_REGION || 'us-west-2',
  model: process.env.POCKETDJ_DEMUCS_MODEL || 'htdemucs',
  device: process.env.POCKETDJ_STEM_DEVICE || 'cpu',
  format: process.env.POCKETDJ_STEM_FORMAT || 'mp3',
  bitrate: process.env.POCKETDJ_STEM_BITRATE || '256',
  venv: process.env.POCKETDJ_STEM_VENV || join(homedir(), 'venv-stems'),
  py: process.env.POCKETDJ_STEM_PY || join(HERE, 'separate-one.py'),
  // --serve loop: poll every pollSeconds; exit (→ instance self-terminates) after idleSeconds
  // with an empty queue. This is the SCALE-DOWN half of autoscaling — the autoscaler only ever
  // scales UP on queue depth; workers retire themselves on idle so the fleet drains to zero.
  idleSeconds: Number(process.env.POCKETDJ_STEM_IDLE_SECONDS || 300),
  pollSeconds: Number(process.env.POCKETDJ_STEM_POLL_SECONDS || 15),
};
// Keep in sync with STEMS_VERSION in scripts/lib/audio-stem.mjs — bump when the algorithm
// changes so /backfill-stems re-runs stale entries.
const STEM_VERSION = 1;
const STEM_NAMES = ['vocals', 'drums', 'bass', 'other'];
const JOBS_PREFIX = 'rips/stem-jobs/';

const s3 = (...args) => execFileSync('aws', ['s3', ...args, '--region', CFG.region], { encoding: 'utf8' });
const s3api = (...args) => execFileSync('aws', ['s3api', ...args, '--region', CFG.region], { encoding: 'utf8' });
const log = (...m) => process.stderr.write(m.join(' ') + '\n');   // stdout stays clean for the result JSON

// Separate ONE ripped song into 4 stems on S3. Returns the manifest-stamp fields (or {ok:false}).
async function processSong(songId) {
  if (!/^sng_[0-9a-f]{12}$|^amrec_\d+$/.test(songId)) throw new Error(`bad songId ${songId}`);
  const ext = CFG.format === 'flac' ? 'flac' : 'mp3';
  const contentType = CFG.format === 'flac' ? 'audio/flac' : 'audio/mpeg';
  const work = join(tmpdir(), `stem-${songId}`);
  rmSync(work, { recursive: true, force: true });
  mkdirSync(work, { recursive: true });
  const t0 = Date.now();
  try {
    // 1. pull the ripped mp3 from S3
    s3('cp', `s3://${CFG.bucket}/rips/${songId}.mp3`, join(work, 'song.mp3'), '--only-show-errors');
    copyFileSync(CFG.py, join(work, 'separate-one.py'));

    // 2. run demucs (async spawn: a separation takes minutes; keep it killable/observable)
    const senv = {
      ...process.env,
      STEM_MODEL: CFG.model, STEM_DEVICE: CFG.device,
      STEM_FORMAT: CFG.format, STEM_BITRATE: String(CFG.bitrate),
      PYTORCH_ENABLE_MPS_FALLBACK: '1',
    };
    const python = existsSync(join(CFG.venv, 'bin', 'python')) ? join(CFG.venv, 'bin', 'python') : 'python3';
    log(`[${songId}] demucs (${CFG.model}/${CFG.device}) via ${python} …`);
    const stdout = await new Promise((res, rej) => {
      const p = spawn(python, [join(work, 'separate-one.py'), join(work, 'song.mp3')], { env: senv });
      let buf = '';
      p.stdout.on('data', (d) => { buf += d; });
      p.stderr.on('data', () => {});   // demucs progress goes to its own stderr; ignore
      p.on('error', rej);
      p.on('close', (code) => (code === 0 ? res(buf) : rej(new Error(`demucs exit ${code}`))));
    });
    const lines = stdout.trim().split('\n').filter(Boolean);
    const j = JSON.parse(lines.pop());
    if (!j.ok || !j.stems) throw new Error(`demucs said not-ok: ${JSON.stringify(j).slice(0, 200)}`);

    // 3. upload each stem to rips/stems/<songId>/<stem>.<ext>
    const stems = {};
    let bytes = 0;
    for (const name of STEM_NAMES) {
      const local = join(work, j.stems[name]);
      const key = `rips/stems/${songId}/${name}.${ext}`;
      s3('cp', local, `s3://${CFG.bucket}/${key}`, '--content-type', contentType, '--only-show-errors');
      stems[name] = key;
      try { bytes += statSync(local).size; } catch { /* ignore */ }
    }
    return {
      ok: true, songId, stems, stemModel: j.model || CFG.model, stemVersion: STEM_VERSION,
      stemFormat: CFG.format, stemBytes: bytes || null, stemmedAt: Date.now(),
      workerSeconds: Math.round((Date.now() - t0) / 1000),
    };
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

// --poll: drain the S3-marker job queue. Each job is rips/stem-jobs/<songId>.job.json.
// On success we write <songId>.result.json and delete the .job.json. Best-effort (no atomic
// claim — fine for a single worker / prototype; production would front this with SQS).
// Claim + process at most ONE job per call. The claim is `aws s3 mv <id>.job.json ->
// <id>.claimed.json`: a worker that polls later won't see the marker, so the fleet spreads out
// across distinct songs. NOTE: S3 mv is not a truly atomic claim — with a large fleet two
// workers could still race the same marker. Fine for a small fleet / prototype; production
// should front this with SQS (or an S3 conditional PUT / If-None-Match) for exactly-once claim.
async function poll() {
  let out;
  try { out = s3('ls', `s3://${CFG.bucket}/${JOBS_PREFIX}`); }
  catch { return []; }
  const jobs = out.split('\n').map((l) => l.trim().split(/\s+/).pop())
    .filter((n) => n && n.endsWith('.job.json'))
    .map((n) => n.replace(/\.job\.json$/, ''));
  for (const songId of jobs) {
    const jobKey = `${JOBS_PREFIX}${songId}.job.json`;
    const claimKey = `${JOBS_PREFIX}${songId}.claimed.json`;
    try { s3('mv', `s3://${CFG.bucket}/${jobKey}`, `s3://${CFG.bucket}/${claimKey}`, '--only-show-errors'); }
    catch { continue; }               // lost the claim — another worker took it; try the next job
    try {
      const r = await processSong(songId);
      execFileSync('aws', ['s3', 'cp', '-', `s3://${CFG.bucket}/${JOBS_PREFIX}${songId}.result.json`,
        '--content-type', 'application/json', '--region', CFG.region, '--only-show-errors'],
        { input: JSON.stringify(r) });
      s3('rm', `s3://${CFG.bucket}/${claimKey}`, '--only-show-errors');
      log(`[poll] ${songId} done in ${r.workerSeconds}s`);
      return [r];
    } catch (e) {
      log(`[poll] ${songId} FAILED: ${e.message} — releasing claim`);
      try { s3('mv', `s3://${CFG.bucket}/${claimKey}`, `s3://${CFG.bucket}/${jobKey}`, '--only-show-errors'); }
      catch { /* ignore */ }
      return [];
    }
  }
  return [];
}

const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

// --serve: long-running worker. Drains the queue repeatedly, and once it has sat idle (empty
// queue) for CFG.idleSeconds, returns so the launch-template user-data can `shutdown -h now`
// (the instance launches with InstanceInitiatedShutdownBehavior=terminate → scale to zero).
async function serve() {
  let lastActivity = Date.now();
  let total = 0;
  log(`[serve] poll every ${CFG.pollSeconds}s; idle-exit after ${CFG.idleSeconds}s`);
  for (;;) {
    let done = [];
    try { done = await poll(); } catch (e) { log('[serve] poll error:', e.message); }
    if (done.length) { total += done.length; lastActivity = Date.now(); continue; }  // drain back-to-back
    if ((Date.now() - lastActivity) / 1000 >= CFG.idleSeconds) {
      log(`[serve] idle ${CFG.idleSeconds}s — retiring after ${total} job(s)`);
      break;
    }
    await sleep(CFG.pollSeconds);
  }
  return total;
}

async function main() {
  const arg = process.argv[2];
  if (!arg) { log('usage: stem-worker.mjs <songId> | --poll | --serve'); process.exit(2); }
  if (arg === '--serve') {
    const served = await serve();
    console.log(JSON.stringify({ ok: true, served }));
    return;
  }
  if (arg === '--poll') {
    const done = await poll();
    console.log(JSON.stringify({ ok: true, processed: done.length, results: done }));
    return;
  }
  const r = await processSong(arg);
  console.log(JSON.stringify(r));   // ONE result line on stdout for the coordinator
}

main().catch((e) => { log('FATAL', e.message); console.log(JSON.stringify({ ok: false, error: e.message })); process.exit(1); });
