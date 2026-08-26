#!/usr/bin/env node
// Cloud audio worker — runs OFF the Mac on any Linux box with awscli, ffmpeg, and a python venv
// that has `demucs` AND `librosa`. Consumes SQS jobs that ask for one or both tasks on a ripped
// song, keyed by the S3 source key carried in the job:
//   • stems    — Demucs → 4 stems → rips/stems/<id>/<stem>.<ext>
//   • analysis — librosa BPM/key/Camelot + beat grid + ffmpeg waveform (DIGITAL songs; keyed by
//                songId) → rips/waveforms/<id>.png + rips/analysis/<id>.json
//   • lyrics   — faster-whisper over the VOCALS stem → timed words → rips/lyrics/<id>.json
//                (fire-and-forget; reuses the just-produced local vocals on a combined stems+lyrics
//                job, else downloads rips/stems/<id>/vocals.<ext>). Needs `faster-whisper` in the venv.
// Posts the manifest-stamp result to the SQS results queue; rip-server folds it into manifest.json.
// This decouples both heavy jobs from the single serial iMac (and the flaky local Docker analysis).
//
// Job body: {songId, srcKey, tasks:["stems"|"analysis"|"lyrics"...]}  (tasks defaults to ["stems"])
// Modes:
//   node stem-worker.mjs <songId>        one-shot stems (digital rips/<id>.mp3), print result
//   node stem-worker.mjs --serve         long-running SQS consumer; idle-exit → self-terminate
//   node stem-worker.mjs --poll          process at most one SQS message, then exit
//
// Env: POCKETDJ_RIPS_BUCKET, AWS_REGION, POCKETDJ_STEM_JOBS_QUEUE, POCKETDJ_STEM_RESULTS_QUEUE,
//   POCKETDJ_DEMUCS_MODEL, POCKETDJ_STEM_DEVICE(cpu|cuda|mps), POCKETDJ_STEM_FORMAT/_BITRATE,
//   POCKETDJ_STEM_VENV, POCKETDJ_STEM_PY, POCKETDJ_ANALYZE_PY, POCKETDJ_BEATGRID_PY,
//   POCKETDJ_TRANSCRIBE_PY, POCKETDJ_LYRICS_MODEL(small), POCKETDJ_LYRICS_DEVICE(cpu),
//   POCKETDJ_LYRICS_COMPUTE(int8), POCKETDJ_STEM_VISIBILITY, POCKETDJ_STEM_IDLE_SECONDS.
//   AWS creds via the instance role.
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, copyFileSync, existsSync, statSync, writeFileSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir, tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const CFG = {
  bucket: process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623',
  region: process.env.AWS_REGION || 'us-west-2',
  jobsQueue: process.env.POCKETDJ_STEM_JOBS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-stem-jobs',
  resultsQueue: process.env.POCKETDJ_STEM_RESULTS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-stem-results',
  visibility: Number(process.env.POCKETDJ_STEM_VISIBILITY || 1800),
  model: process.env.POCKETDJ_DEMUCS_MODEL || 'htdemucs',
  device: process.env.POCKETDJ_STEM_DEVICE || 'cpu',
  format: process.env.POCKETDJ_STEM_FORMAT || 'mp3',
  bitrate: process.env.POCKETDJ_STEM_BITRATE || '256',
  venv: process.env.POCKETDJ_STEM_VENV || join(homedir(), 'venv-stems'),
  stemPy: process.env.POCKETDJ_STEM_PY || join(HERE, 'separate-one.py'),
  analyzePy: process.env.POCKETDJ_ANALYZE_PY || join(HERE, 'analyze-one.py'),
  beatgridPy: process.env.POCKETDJ_BEATGRID_PY || join(HERE, 'analyze-beatgrid.py'),
  transcribePy: process.env.POCKETDJ_TRANSCRIBE_PY || join(HERE, 'transcribe-one.py'),
  lyricsModel: process.env.POCKETDJ_LYRICS_MODEL || 'small',
  lyricsDevice: process.env.POCKETDJ_LYRICS_DEVICE || 'cpu',
  lyricsCompute: process.env.POCKETDJ_LYRICS_COMPUTE || 'int8',
  idleSeconds: Number(process.env.POCKETDJ_STEM_IDLE_SECONDS || 300),
  maxErrors: Number(process.env.POCKETDJ_STEM_MAX_ERRORS || 20),   // bound the error streak (see serve)
};
const STEM_VERSION = 1;        // keep in sync with STEMS_VERSION in scripts/lib/audio-stem.mjs
const ANALYSIS_VERSION = 1;    // keep in sync with ANALYSIS_VERSION in scripts/lib/audio-analyze.mjs
const LYRICS_VERSION = 1;      // keep in sync with LYRICS_VERSION in scripts/rip-server.mjs
const STEM_NAMES = ['vocals', 'drums', 'bass', 'other'];
const stemExt = () => (CFG.format === 'flac' ? 'flac' : 'mp3');
const aws = (...args) => execFileSync('aws', [...args, '--region', CFG.region], { encoding: 'utf8' });
const log = (...m) => process.stderr.write(m.join(' ') + '\n');

const pyBin = () => (existsSync(join(CFG.venv, 'bin', 'python')) ? join(CFG.venv, 'bin', 'python') : 'python3');

// Run a python script and return the last JSON line it prints (the analyze/separate contract).
function runPyJson(scriptPath, mp3, env) {
  return new Promise((res, rej) => {
    const p = spawn(pyBin(), [scriptPath, mp3], { env: { ...process.env, ...env, PYTORCH_ENABLE_MPS_FALLBACK: '1' } });
    let buf = '';
    let errbuf = '';                                             // keep a rolling stderr tail for DLQ diagnosis
    p.stdout.on('data', (d) => { buf += d; });
    p.stderr.on('data', (d) => { errbuf += d; if (errbuf.length > 4000) errbuf = errbuf.slice(-4000); });
    p.on('error', rej);
    p.on('close', (code) => {
      const tail = errbuf.trim().slice(-2000);                  // whisper/librosa failures print here, not to stdout
      if (code !== 0) return rej(new Error(`${scriptPath} exit ${code}${tail ? `: ${tail}` : ''}`));
      const line = buf.trim().split('\n').filter(Boolean).pop();
      try { res(JSON.parse(line)); } catch { rej(new Error(`${scriptPath}: no JSON${tail ? ` — ${tail}` : ''}`)); }
    });
  });
}

// Are all 4 current stems already on S3? Returns their keys + total bytes, else null. This is the
// worker-level song-id DEDUP: a duplicate job (the same song enqueued N times) skips Demucs and
// just re-posts a result reconstructed from the existing stems.
function existingStems(songId) {
  const ext = CFG.format === 'flac' ? 'flac' : 'mp3';
  let out;
  try { out = aws('s3', 'ls', `s3://${CFG.bucket}/rips/stems/${songId}/`); } catch { return null; }
  const sizes = {};
  for (const line of out.split('\n')) {
    const m = line.trim().match(/^\S+\s+\S+\s+(\d+)\s+(\S+\.\w+)$/);
    if (m) sizes[m[2]] = Number(m[1]);
  }
  const stems = {}; let bytes = 0;
  for (const name of STEM_NAMES) {
    if (!sizes[`${name}.${ext}`]) return null;               // missing a stem → not deduped
    stems[name] = `rips/stems/${songId}/${name}.${ext}`;
    bytes += sizes[`${name}.${ext}`];
  }
  return { stems, bytes };
}

// stems task: separate → upload (or, if already present, reconstruct without re-running Demucs).
async function doStems(songId, mp3, work, allowDedup) {
  if (allowDedup !== false) {              // rip-server sends dedup:false to FORCE a re-stem (model/version upgrade)
    const existing = existingStems(songId);
    if (existing) {
      log(`[${songId}] stems already on S3 — dedup skip`);
      return { stems: existing.stems, stemModel: CFG.model, stemVersion: STEM_VERSION, stemFormat: CFG.format, stemBytes: existing.bytes, deduped: true };
    }
  }
  const ext = CFG.format === 'flac' ? 'flac' : 'mp3';
  const contentType = CFG.format === 'flac' ? 'audio/flac' : 'audio/mpeg';
  copyFileSync(CFG.stemPy, join(work, 'separate-one.py'));
  log(`[${songId}] demucs (${CFG.model}/${CFG.device}) …`);
  const j = await runPyJson(join(work, 'separate-one.py'), mp3,
    { STEM_MODEL: CFG.model, STEM_DEVICE: CFG.device, STEM_FORMAT: CFG.format, STEM_BITRATE: String(CFG.bitrate) });
  if (!j.ok || !j.stems) throw new Error(`demucs not-ok: ${JSON.stringify(j).slice(0, 160)}`);
  const stems = {}; let bytes = 0;
  for (const name of STEM_NAMES) {
    const local = join(work, j.stems[name]);
    const key = `rips/stems/${songId}/${name}.${ext}`;
    aws('s3', 'cp', local, `s3://${CFG.bucket}/${key}`, '--content-type', contentType, '--only-show-errors');
    if (name === 'vocals') try { copyFileSync(local, join(work, `vocals.${ext}`)); } catch { /* lyrics falls back to S3 */ }
    stems[name] = key;
    try { bytes += statSync(local).size; } catch { /* ignore */ }
  }
  return { stems, stemModel: j.model || CFG.model, stemVersion: STEM_VERSION, stemFormat: CFG.format, stemBytes: bytes || null };
}

// analysis task (DIGITAL songs, keyed by songId): librosa bpm/key/Camelot + beat grid + waveform.
// Mirrors scripts/lib/audio-analyze.mjs but runs the python in the venv (no Docker) and uploads
// the same artifacts. Each sub-step is best-effort so one failure doesn't sink the others.
async function doAnalysis(songId, mp3, work) {
  const a = { bpm: null, musicalKey: null, camelot: null, keyStrength: null, durationSec: null, waveform: null, beatgrid: null, beatgridKey: null, analysisVersion: ANALYSIS_VERSION };
  try {
    copyFileSync(CFG.analyzePy, join(work, 'analyze-one.py'));
    const j = await runPyJson(join(work, 'analyze-one.py'), mp3, {});
    if (j.ok) { a.bpm = j.bpm; a.musicalKey = j.key; a.camelot = j.camelot; a.keyStrength = j.keyStrength; a.durationSec = j.durationSec; }
  } catch (e) { log(`[${songId}] analyze-one failed: ${e.message}`); }
  try {
    copyFileSync(CFG.beatgridPy, join(work, 'analyze-beatgrid.py'));
    const j = await runPyJson(join(work, 'analyze-beatgrid.py'), mp3, {});
    if (j.ok) {
      a.beatgrid = { firstBeatMs: j.firstBeatMs, firstDownbeatMs: j.firstDownbeatMs, beatGridBpm: j.beatGridBpm, beatsPerBar: j.beatsPerBar, tempoVar: j.tempoVar, tempoConfidence: j.tempoConfidence, gridResidualMs: j.gridResidualMs, steady: j.steady };
      const key = `rips/analysis/${songId}.json`;
      const sidecar = join(work, 'analysis.json');
      writeFileSync(sidecar, JSON.stringify({ version: ANALYSIS_VERSION, analyzer: 'librosa-beatgrid', ...a.beatgrid, beatsMs: j.beatsMs || [], downbeatsMs: j.downbeatsMs || [] }));
      aws('s3', 'cp', sidecar, `s3://${CFG.bucket}/${key}`, '--content-type', 'application/json', '--only-show-errors');
      a.beatgridKey = key;
    }
  } catch (e) { log(`[${songId}] beatgrid failed: ${e.message}`); }
  try {
    const png = join(work, 'waveform.png');
    execFileSync('ffmpeg', ['-y', '-i', mp3, '-filter_complex', 'showwavespic=s=1200x240:colors=#7aa2ff', '-frames:v', '1', png], { stdio: 'ignore' });
    const key = `rips/waveforms/${songId}.png`;
    aws('s3', 'cp', png, `s3://${CFG.bucket}/${key}`, '--content-type', 'image/png', '--only-show-errors');
    a.waveform = key;
  } catch (e) { log(`[${songId}] waveform failed: ${e.message}`); }
  return a;
}

// Is a timed-lyrics sidecar already on S3? Worker-level DEDUP mirror of existingStems: a duplicate
// lyrics job (the same song enqueued twice, or a rip-server restart re-sending the want) skips
// whisper and re-posts the existing key. Returns the S3 key or null.
function existingLyrics(songId) {
  try { aws('s3', 'ls', `s3://${CFG.bucket}/rips/lyrics/${songId}.json`); } catch { return null; }
  return `rips/lyrics/${songId}.json`;
}

// lyrics task: faster-whisper over the VOCALS stem → timed word sidecar rips/lyrics/<id>.json.
// Vocals come from the just-produced local file (combined stems+lyrics job) or, failing that, S3.
// A missing vocals stem throws — the server only enqueues lyrics once stems exist; the DLQ is the
// backstop. The stem is cut-derived (song-relative), so word timestamps need no extra offset.
async function doLyrics(songId, work, { dedup, localVocals } = {}) {
  if (dedup !== false) {
    const key = existingLyrics(songId);
    if (key) { log(`[${songId}] lyrics already on S3 — dedup skip`); return { lyrics: key, lyricsVersion: LYRICS_VERSION, deduped: true }; }
  }
  const ext = stemExt();
  let vocals = localVocals && existsSync(localVocals) ? localVocals : null;
  if (!vocals) {
    vocals = join(work, `vocals.${ext}`);
    try { aws('s3', 'cp', `s3://${CFG.bucket}/rips/stems/${songId}/vocals.${ext}`, vocals, '--only-show-errors'); }
    catch { throw new Error(`no vocals stem rips/stems/${songId}/vocals.${ext} — stemify first`); }
  }
  copyFileSync(CFG.transcribePy, join(work, 'transcribe-one.py'));
  log(`[${songId}] whisper (${CFG.lyricsModel}/${CFG.lyricsDevice}/${CFG.lyricsCompute}) …`);
  const j = await runPyJson(join(work, 'transcribe-one.py'), vocals,
    { LYRICS_MODEL: CFG.lyricsModel, LYRICS_DEVICE: CFG.lyricsDevice, LYRICS_COMPUTE: CFG.lyricsCompute });
  if (!j || !Array.isArray(j.words)) throw new Error(`transcribe not-ok: ${JSON.stringify(j).slice(0, 160)}`);
  const key = `rips/lyrics/${songId}.json`;
  const sidecar = join(work, 'lyrics.json');
  writeFileSync(sidecar, JSON.stringify({ version: j.version ?? LYRICS_VERSION, model: j.model || CFG.lyricsModel, lang: j.lang ?? null, durationMs: j.durationMs ?? null, words: j.words }));
  aws('s3', 'cp', sidecar, `s3://${CFG.bucket}/${key}`, '--content-type', 'application/json', '--only-show-errors');
  return { lyrics: key, lyricsModel: j.model || CFG.lyricsModel, lyricsVersion: LYRICS_VERSION };
}

// Process ONE job: download the source once, run the requested tasks, return the combined result.
async function processJob(songId, srcKey, tasks, dedup) {
  // Variant ids (`sng_<12hex>_explicit`) are minted by rip-server's VARIANT_ID and keyed through
  // the whole pipeline; rejecting them here dead-lettered those songs' stems/analysis silently.
  if (!/^(?:sng_[0-9a-f]{12}|amrec_\d+)(?:_explicit|_clean)?$/.test(songId)) throw new Error(`bad songId ${songId}`);
  const source = srcKey || `rips/${songId}.mp3`;
  const work = join(tmpdir(), `job-${songId}`);
  rmSync(work, { recursive: true, force: true });
  mkdirSync(work, { recursive: true });
  const mp3 = join(work, 'song.mp3');
  const t0 = Date.now();
  const result = { ok: true, songId, tasks, workerSeconds: 0 };
  try {
    aws('s3', 'cp', `s3://${CFG.bucket}/${source}`, mp3, '--only-show-errors');
    let localVocals = null;                                              // reused by lyrics on a combined stems+lyrics job
    if (tasks.includes('stems')) { Object.assign(result, await doStems(songId, mp3, work, dedup)); localVocals = join(work, `vocals.${stemExt()}`); }
    if (tasks.includes('lyrics')) result.lyrics = await doLyrics(songId, work, { dedup, localVocals });
    if (tasks.includes('analysis')) result.analysis = await doAnalysis(songId, mp3, work);
    result.workerSeconds = Math.round((Date.now() - t0) / 1000);
    return result;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

// Receive ONE job from SQS (visibility timeout = atomic claim), process it, post the result, delete
// the job. Failures are left un-deleted → redelivered → DLQ after the queue's maxReceiveCount.
// Set by poll() when the receive or the job itself FAILED (as opposed to the queue simply being
// empty). serve() must treat that as activity: returning [] for both cases let a run of failing
// jobs read as idleness, so the worker retired holding its SQS claims and the jobs sat inflight
// until the visibility timeout expired (observed live: two jobs stranded 24+ minutes).
let pollFailed = false;
async function poll() {
  pollFailed = false;
  let out;
  try {
    out = aws('sqs', 'receive-message', '--queue-url', CFG.jobsQueue, '--max-number-of-messages', '1',
      '--wait-time-seconds', '20', '--visibility-timeout', String(CFG.visibility), '--output', 'json');
  } catch { pollFailed = true; return []; }
  const msg = ((JSON.parse(out || '{}').Messages) || [])[0];
  if (!msg) return [];
  let body = {};
  try { body = JSON.parse(msg.Body); } catch { /* malformed */ }
  const songId = body.songId;
  const tasks = Array.isArray(body.tasks) && body.tasks.length ? body.tasks : ['stems'];
  if (!songId) {
    try { aws('sqs', 'delete-message', '--queue-url', CFG.jobsQueue, '--receipt-handle', msg.ReceiptHandle); } catch { /* ignore */ }
    return [];
  }
  try {
    const r = await processJob(songId, body.srcKey, tasks, body.dedup);
    execFileSync('aws', ['sqs', 'send-message', '--queue-url', CFG.resultsQueue,
      '--message-body', JSON.stringify(r), '--region', CFG.region], { stdio: 'ignore' });
    aws('sqs', 'delete-message', '--queue-url', CFG.jobsQueue, '--receipt-handle', msg.ReceiptHandle);
    log(`[poll] ${songId} [${tasks.join('+')}] done in ${r.workerSeconds}s`);
    return [r];
  } catch (e) {
    log(`[poll] ${songId} FAILED: ${e.message} — leaving for retry/DLQ`);
    pollFailed = true;                 // a FAILURE is not idleness — see serve()
    return [];
  }
}

async function serve() {
  let lastActivity = Date.now();
  let total = 0;
  let errors = 0;
  log(`[serve] SQS consumer on ${CFG.jobsQueue.split('/').pop()}; idle-exit after ${CFG.idleSeconds}s`);
  for (;;) {
    let done = [];
    try { done = await poll(); } catch (e) { pollFailed = true; log('[serve] poll error:', e.message); }
    if (done.length) { total += done.length; errors = 0; lastActivity = Date.now(); continue; }
    if (pollFailed) {
      // Errors are ACTIVITY, not idleness — retiring here dropped the SQS claims of jobs that
      // were merely failing. But the streak MUST be bounded both ways: a worker that can never
      // reach SQS would otherwise never retire and would bill until someone noticed, and a
      // fast-failing receive skips the 20 s long poll, so it would also spin hot.
      errors += 1;
      lastActivity = Date.now();
      if (errors >= CFG.maxErrors) { log(`[serve] ${errors} consecutive errors — retiring after ${total} job(s)`); break; }
      await new Promise((r) => setTimeout(r, Math.min(30_000, 1000 * errors)));
      continue;
    }
    errors = 0;
    if ((Date.now() - lastActivity) / 1000 >= CFG.idleSeconds) { log(`[serve] idle ${CFG.idleSeconds}s — retiring after ${total} job(s)`); break; }
  }
  return total;
}

async function main() {
  const arg = process.argv[2];
  if (!arg) { log('usage: stem-worker.mjs <songId> | --serve | --poll'); process.exit(2); }
  if (arg === '--serve') { console.log(JSON.stringify({ ok: true, served: await serve() })); return; }
  if (arg === '--poll') { const d = await poll(); console.log(JSON.stringify({ ok: true, processed: d.length })); return; }
  console.log(JSON.stringify(await processJob(arg, undefined, ['stems'])));
}

main().catch((e) => { log('FATAL', e.message); console.log(JSON.stringify({ ok: false, error: e.message })); process.exit(1); });
