#!/usr/bin/env node
// Cloud stem worker — runs OFF the Mac on any Linux box with awscli, ffmpeg, and a python venv
// with `demucs`. Pulls a ripped song's mp3 from the rips bucket, runs Demucs (CPU or GPU),
// uploads 4 stems to rips/stems/<songId>/, and posts the manifest-stamp result to the SQS
// RESULTS queue so rip-server folds it into manifest.json. Decouples stem separation from the
// single serial capture rig on the iMac; mirrors lib/audio-stem.mjs's demucs contract.
//
// Modes:
//   node stem-worker.mjs <songId>   one-shot: process one song, print result JSON (no queue)
//   node stem-worker.mjs --serve    long-running SQS consumer; idle-exit → instance self-terminates
//   node stem-worker.mjs --poll     process at most one SQS message, then exit
//
// Env: POCKETDJ_RIPS_BUCKET, AWS_REGION, POCKETDJ_STEM_JOBS_QUEUE, POCKETDJ_STEM_RESULTS_QUEUE,
//   POCKETDJ_DEMUCS_MODEL, POCKETDJ_STEM_DEVICE(cpu|cuda|mps), POCKETDJ_STEM_FORMAT/_BITRATE,
//   POCKETDJ_STEM_VENV, POCKETDJ_STEM_PY, POCKETDJ_STEM_VISIBILITY, POCKETDJ_STEM_IDLE_SECONDS.
//   AWS creds via the instance role / env / config.
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, copyFileSync, existsSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir, tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const CFG = {
  bucket: process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623',
  region: process.env.AWS_REGION || 'us-west-2',
  jobsQueue: process.env.POCKETDJ_STEM_JOBS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-stem-jobs',
  resultsQueue: process.env.POCKETDJ_STEM_RESULTS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-stem-results',
  visibility: Number(process.env.POCKETDJ_STEM_VISIBILITY || 1800),   // ≥ rip-server stemDeadlineMs (30m) so a slow CPU separation can't be redelivered mid-run
  model: process.env.POCKETDJ_DEMUCS_MODEL || 'htdemucs',
  device: process.env.POCKETDJ_STEM_DEVICE || 'cpu',
  format: process.env.POCKETDJ_STEM_FORMAT || 'mp3',
  bitrate: process.env.POCKETDJ_STEM_BITRATE || '256',
  venv: process.env.POCKETDJ_STEM_VENV || join(homedir(), 'venv-stems'),
  py: process.env.POCKETDJ_STEM_PY || join(HERE, 'separate-one.py'),
  idleSeconds: Number(process.env.POCKETDJ_STEM_IDLE_SECONDS || 300),
};
// Keep in sync with STEMS_VERSION in scripts/lib/audio-stem.mjs.
const STEM_VERSION = 1;
const STEM_NAMES = ['vocals', 'drums', 'bass', 'other'];
const aws = (...args) => execFileSync('aws', [...args, '--region', CFG.region], { encoding: 'utf8' });
const log = (...m) => process.stderr.write(m.join(' ') + '\n');   // stdout stays clean for the result JSON

// Separate ONE ripped song into 4 stems on S3. Returns the manifest-stamp fields (throws on
// failure). srcKey is the S3 key of the source audio — the job body carries it because an ANALOG
// song's audio lives at its per-song cut (rips/<id>.cut.mp3), NOT rips/<id>.mp3 (that's the album
// side / a digital rip). Falls back to rips/<id>.mp3 for the digital-only one-shot CLI.
async function processSong(songId, srcKey) {
  if (!/^sng_[0-9a-f]{12}$|^amrec_\d+$/.test(songId)) throw new Error(`bad songId ${songId}`);
  const source = srcKey || `rips/${songId}.mp3`;
  const ext = CFG.format === 'flac' ? 'flac' : 'mp3';
  const contentType = CFG.format === 'flac' ? 'audio/flac' : 'audio/mpeg';
  const work = join(tmpdir(), `stem-${songId}`);
  rmSync(work, { recursive: true, force: true });
  mkdirSync(work, { recursive: true });
  const t0 = Date.now();
  try {
    aws('s3', 'cp', `s3://${CFG.bucket}/${source}`, join(work, 'song.mp3'), '--only-show-errors');
    copyFileSync(CFG.py, join(work, 'separate-one.py'));
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
      p.stderr.on('data', () => {});
      p.on('error', rej);
      p.on('close', (code) => (code === 0 ? res(buf) : rej(new Error(`demucs exit ${code}`))));
    });
    const lines = stdout.trim().split('\n').filter(Boolean);
    const j = JSON.parse(lines.pop());
    if (!j.ok || !j.stems) throw new Error(`demucs said not-ok: ${JSON.stringify(j).slice(0, 200)}`);
    const stems = {};
    let bytes = 0;
    for (const name of STEM_NAMES) {
      const local = join(work, j.stems[name]);
      const key = `rips/stems/${songId}/${name}.${ext}`;
      aws('s3', 'cp', local, `s3://${CFG.bucket}/${key}`, '--content-type', contentType, '--only-show-errors');
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

// Receive ONE job from SQS (the visibility timeout is the atomic claim across the fleet), process
// it, post the result to the results queue, and delete the job. Returns [result] or []. A failed
// job is left un-deleted: it reappears after the visibility timeout and, after the queue's
// maxReceiveCount, moves to the DLQ.
async function poll() {
  let out;
  try {
    out = aws('sqs', 'receive-message', '--queue-url', CFG.jobsQueue, '--max-number-of-messages', '1',
      '--wait-time-seconds', '20', '--visibility-timeout', String(CFG.visibility), '--output', 'json');
  } catch { return []; }
  const msg = ((JSON.parse(out || '{}').Messages) || [])[0];
  if (!msg) return [];
  let body = {};
  try { body = JSON.parse(msg.Body); } catch { /* malformed body */ }
  const songId = body.songId;
  if (!songId) {
    try { aws('sqs', 'delete-message', '--queue-url', CFG.jobsQueue, '--receipt-handle', msg.ReceiptHandle); } catch { /* ignore */ }
    return [];
  }
  try {
    const r = await processSong(songId, body.srcKey);
    execFileSync('aws', ['sqs', 'send-message', '--queue-url', CFG.resultsQueue,
      '--message-body', JSON.stringify(r), '--region', CFG.region], { stdio: 'ignore' });
    aws('sqs', 'delete-message', '--queue-url', CFG.jobsQueue, '--receipt-handle', msg.ReceiptHandle);
    log(`[poll] ${songId} done in ${r.workerSeconds}s`);
    return [r];
  } catch (e) {
    log(`[poll] ${songId} FAILED: ${e.message} — leaving for retry/DLQ`);
    return [];
  }
}

// Long-running consumer. receive-message long-polls up to 20s, which both waits efficiently for
// work and paces the idle loop; after idleSeconds with an empty queue it returns so the launch-
// template boot script can shut the instance down (scale to zero).
async function serve() {
  let lastActivity = Date.now();
  let total = 0;
  log(`[serve] SQS consumer on ${CFG.jobsQueue.split('/').pop()}; idle-exit after ${CFG.idleSeconds}s`);
  for (;;) {
    let done = [];
    try { done = await poll(); } catch (e) { log('[serve] poll error:', e.message); }
    if (done.length) { total += done.length; lastActivity = Date.now(); continue; }
    if ((Date.now() - lastActivity) / 1000 >= CFG.idleSeconds) {
      log(`[serve] idle ${CFG.idleSeconds}s — retiring after ${total} job(s)`);
      break;
    }
  }
  return total;
}

async function main() {
  const arg = process.argv[2];
  if (!arg) { log('usage: stem-worker.mjs <songId> | --serve | --poll'); process.exit(2); }
  if (arg === '--serve') { console.log(JSON.stringify({ ok: true, served: await serve() })); return; }
  if (arg === '--poll') { const d = await poll(); console.log(JSON.stringify({ ok: true, processed: d.length })); return; }
  const r = await processSong(arg);
  console.log(JSON.stringify(r));   // ONE result line on stdout
}

main().catch((e) => { log('FATAL', e.message); console.log(JSON.stringify({ ok: false, error: e.message })); process.exit(1); });
