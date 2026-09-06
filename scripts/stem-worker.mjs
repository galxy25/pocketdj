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
//   node stem-worker.mjs --serve         long-running SQS consumer; idle-exit → self-terminate;
//                                        watches IMDS for a SPOT reclaim notice (see below)
//   node stem-worker.mjs --poll          process at most one SQS message, then exit
//
// Env: POCKETDJ_RIPS_BUCKET, AWS_REGION, POCKETDJ_STEM_JOBS_QUEUE, POCKETDJ_STEM_RESULTS_QUEUE,
//   POCKETDJ_DEMUCS_MODEL, POCKETDJ_STEM_DEVICE(cpu|cuda|mps), POCKETDJ_STEM_FORMAT/_BITRATE,
//   POCKETDJ_STEM_VENV, POCKETDJ_STEM_PY, POCKETDJ_ANALYZE_PY, POCKETDJ_BEATGRID_PY,
//   POCKETDJ_TRANSCRIBE_PY, POCKETDJ_LYRICS_MODEL(small), POCKETDJ_LYRICS_DEVICE(cpu),
//   POCKETDJ_LYRICS_COMPUTE(int8), POCKETDJ_STEM_VISIBILITY, POCKETDJ_STEM_IDLE_SECONDS,
//   POCKETDJ_STEM_SPOT_POLL_MS(5000), POCKETDJ_STEM_SPOT_MAX_REQUEUES(3),
//   POCKETDJ_STEM_SPOT_ARM_TRIES(3).
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
  spotPollMs: Number(process.env.POCKETDJ_STEM_SPOT_POLL_MS || 5000),        // IMDS reclaim-notice poll
  spotMaxRequeues: Number(process.env.POCKETDJ_STEM_SPOT_MAX_REQUEUES || 3), // bound the re-send (see releasePlan)
  spotArmTries: Number(process.env.POCKETDJ_STEM_SPOT_ARM_TRIES || 3),       // IMDS tries before standing down
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

/// Pure: read an `aws s3 ls rips/stems/<id>/` listing into the dedup answer — all 4 current stems
/// with their keys + total bytes, else null.
///
/// ALL-OR-NOTHING IS THE SPOT SAFETY PROPERTY. doStems uploads the 4 stems one `s3 cp` at a time,
/// so a reclaimed instance can leave 1–3 of them on S3. This gate is what stops that half-set from
/// reading as a finished job: a missing name returns null, the redelivered job re-runs Demucs and
/// overwrites. (A single stem cannot be TRUNCATED either — under the multipart threshold `s3 cp` is
/// one atomic PutObject, and above it the object only materialises at CompleteMultipartUpload. A
/// zero-byte object would be falsy here and read as missing, which is also the answer we want.)
export function stemsFromListing(out, songId, ext = 'mp3') {
  const sizes = {};
  for (const line of String(out || '').split('\n')) {
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

// Are all 4 current stems already on S3? Returns their keys + total bytes, else null. This is the
// worker-level song-id DEDUP: a duplicate job (the same song enqueued N times) skips Demucs and
// just re-posts a result reconstructed from the existing stems.
function existingStems(songId) {
  const ext = CFG.format === 'flac' ? 'flac' : 'mp3';
  let out;
  try { out = aws('s3', 'ls', `s3://${CFG.bucket}/rips/stems/${songId}/`); } catch { return null; }
  return stemsFromListing(out, songId, ext);
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

// ---------------------------------------------------------------------------------------------
// SPOT INTERRUPTION. The fleet runs on spot instances, so EC2 can reclaim the box under us: it
// publishes a ~2-minute notice at IMDS /latest/meta-data/spot/instance-action, then kills it.
// Unwatched, the message this worker is holding stays INVISIBLE for the remainder of its
// visibility timeout before anyone can retry it — a job stalls for up to 30 minutes AND has
// already spent one of its 3 deliveries toward the DLQ. Watching costs one curl every 5s and
// hands the job back in seconds.
//
// INERT EVERYWHERE ELSE. An on-demand instance answers 404 forever (the fallback worker runs this
// same code and never notices), and a laptop has no IMDS at all, so the watch never arms — a local
// one-shot run neither hangs nor forks curl on a timer.
const IMDS = 'http://169.254.169.254';

/// Pure: read the IMDS spot/instance-action body. NOT-INTERRUPTED is the hot path — a long-running
/// worker asks thousands of times per lifetime and gets a 404 every time — so a 404 page, an empty
/// read, or a token fetch that failed (undefined) all land there, quietly. It must never THROW:
/// this runs on a timer while an SQS claim is held, and an exception would kill the worker still
/// holding that claim, which is precisely the stall the watch exists to prevent.
export function parseSpotInterruption(body) {
  const none = { interrupted: false, action: null, time: null, atMs: null };
  if (typeof body !== 'string') return none;
  const text = body.trim();
  if (!text || text[0] !== '{') return none;              // 404 HTML page / empty read = healthy
  let j = null;
  try { j = JSON.parse(text); } catch { return none; }
  if (!j || typeof j !== 'object' || typeof j.action !== 'string' || !j.action) return none;
  const time = typeof j.time === 'string' && j.time ? j.time : null;
  const ms = time ? Date.parse(time) : NaN;
  return { interrupted: true, action: j.action, time, atMs: Number.isFinite(ms) ? ms : null };
}

// IMDSv2 needs a PUT token first (the launch template requires it) — the whoAmI() pattern from
// timbre-worker.mjs. Bounded hard on every hop: off EC2 the link-local address is a black hole and
// nothing in --serve may block on it. The token is cached and re-minted well inside its TTL.
let imdsTok = null;
let imdsTokAt = 0;
function imdsToken() {
  if (imdsTok && Date.now() - imdsTokAt < 240_000) return imdsTok;
  try {
    imdsTok = execFileSync('curl', ['-sf', '-X', 'PUT', `${IMDS}/latest/api/token`,
      '-H', 'X-aws-ec2-metadata-token-ttl-seconds: 300', '--connect-timeout', '1', '--max-time', '2'],
      { encoding: 'utf8', timeout: 3000 }).trim() || null;
    imdsTokAt = Date.now();
  } catch { imdsTok = null; }
  return imdsTok;
}

// One reclaim check. `curl -s` (no -f) so a 404 comes back as a BODY the pure parser can judge,
// rather than as an exception we would have to guess about; a connection failure still throws and
// reads as healthy.
function spotCheck() {
  const tok = imdsToken();
  if (!tok) return parseSpotInterruption(null);
  let out;
  try {
    out = execFileSync('curl', ['-s', `${IMDS}/latest/meta-data/spot/instance-action`,
      '-H', `X-aws-ec2-metadata-token: ${tok}`, '--connect-timeout', '1', '--max-time', '2'],
      { encoding: 'utf8', timeout: 3000 });
  } catch { return parseSpotInterruption(null); }
  return parseSpotInterruption(out);
}

/// Pure: what to do with the in-flight SQS message when EC2 reclaims the box.
///
/// THE DELIVERY-ATTEMPT PROBLEM. ChangeMessageVisibility(0) hands the job back instantly, but the
/// receive it already consumed is gone — SQS exposes no way to decrement ApproximateReceiveCount,
/// and there is no "return unread" call. With maxReceiveCount=3, a song unlucky enough to be
/// reclaimed three times would be dead-lettered with nothing whatsoever wrong with it. So the
/// release RE-SENDS the job as a NEW message — a fresh receive count is the only reset SQS
/// actually offers — and deletes the old one. Send BEFORE delete at the call site: a failed delete
/// costs a duplicate (existingStems/existingLyrics dedup it, and folding a duplicate result is
/// idempotent), while a failed send after a delete would LOSE the job outright.
///
/// The hop count rides in the body and is BOUNDED. Re-sending forever would hide a message that
/// keeps getting released from the DLQ, so past the cap we fall back to visibility-0: the job still
/// comes back at once, but its receive count resumes climbing and the DLQ stays reachable.
///
/// A job whose RESULT was already posted is simply deleted — it is finished, and requeueing it
/// would buy a pointless duplicate separation.
export function releasePlan({ body, resultPosted } = {}, { maxRequeues = 3 } = {}) {
  if (resultPosted) return { action: 'delete', reason: 'result already posted' };
  let parsed = null;
  try { parsed = JSON.parse(body); } catch { /* malformed — nothing to re-send */ }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return { action: 'release', reason: 'unparseable body' };
  // A body with no songId would spread into a NEW queue message that poll() just deletes on
  // receipt — self-cleaning, but there is no sense minting a junk job to find that out.
  if (!parsed.songId || typeof parsed.songId !== 'string') return { action: 'release', reason: 'no songId to re-send' };
  const prior = parsed.spotRequeues === undefined ? 0 : Number(parsed.spotRequeues);
  if (!Number.isFinite(prior) || prior < 0) return { action: 'release', reason: 'unreadable hop counter' };
  const hops = prior + 1;
  if (hops > maxRequeues) return { action: 'release', reason: `spot-requeue cap ${maxRequeues}` };
  return { action: 'requeue', requeues: hops, reason: 'fresh delivery attempts',
    body: JSON.stringify({ ...parsed, spotRequeues: hops }) };
}

// The message this worker currently holds. Set SYNCHRONOUSLY the instant SQS hands it over: the
// watcher fires from a timer, so a claim recorded after an await could be missed by a notice that
// lands in between, and the whole point is that no claim is ever left holding.
let inflight = null;
let spotNotice = null;                       // the reclaim action once EC2 has told us; null = healthy

function releaseInflight() {
  const m = inflight;
  if (!m) return 'nothing in flight';
  inflight = null;
  const plan = releasePlan(m, { maxRequeues: CFG.spotMaxRequeues });
  const del = () => aws('sqs', 'delete-message', '--queue-url', CFG.jobsQueue, '--receipt-handle', m.handle);
  const hand = () => aws('sqs', 'change-message-visibility', '--queue-url', CFG.jobsQueue,
    '--receipt-handle', m.handle, '--visibility-timeout', '0');
  try {
    if (plan.action === 'delete') { del(); return `${m.songId} deleted (${plan.reason})`; }
    if (plan.action === 'requeue') {
      aws('sqs', 'send-message', '--queue-url', CFG.jobsQueue, '--message-body', plan.body);   // send FIRST
      del();                                                                                  // then drop the old one
      return `${m.songId} requeued with a fresh delivery count (spot hop ${plan.requeues}/${CFG.spotMaxRequeues})`;
    }
    hand();
    return `${m.songId} released via visibility-0 (${plan.reason})`;
  } catch (e) {
    // Whatever failed, the job must not sit invisible for the rest of the visibility timeout.
    // After a successful send this makes the original visible too — a duplicate, which dedup eats.
    try { hand(); return `${m.songId} released via visibility-0 after ${plan.action} failed: ${e.message}`; }
    catch (e2) { return `${m.songId} STRANDED (${e2.message}) — redelivers after the ${CFG.visibility}s visibility timeout`; }
  }
}

function onSpotTick() {
  if (spotNotice) return;
  const n = spotCheck();
  if (!n.interrupted) return;
  spotNotice = n.action;
  if (spotTimer) clearInterval(spotTimer);   // the answer cannot change back; stop asking
  log(`[spot] EC2 reclaim notice (${n.action}${n.time ? ` at ${n.time}` : ''}) — no new jobs; releasing in-flight work`);
  const held = !!inflight;
  log(`[spot] ${releaseInflight()}`);
  // Two minutes is nowhere near a Demucs run and the box is going away regardless, so when a job
  // was in flight we exit NOW — the awaited python child can't be unwound, and userdata's
  // `shutdown -h now` should start while EC2 is still waiting. The child dies with the instance;
  // its partial output never reached S3, and a partial stem SET can't read as done (stemsFromListing).
  if (held) { log('[spot] retiring'); process.exit(0); }
  // Idle: no claim to lose, so let serve() break out through its normal path and report its count.
}

let spotTimer = null;
// ARM ON A RETRY, NOT ON ONE SHOT. Arming is a once-per-instance decision made in the first second
// of boot, and a single IMDS miss there disabled the entire interruption path for the whole life of
// a real spot worker — logging "not an EC2 instance" on an EC2 instance, which is the shape of bug
// nobody goes looking for. IMDS does rate-limit (503) and cloud-init can beat the network up, and
// the token fetch is bounded at `--connect-timeout 1 --max-time 2`, so a miss is entirely possible.
// Three tries with a second between them cost ~2 s of startup on a laptop (no route: curl fails at
// once) and buy back the difference between a seconds-long handback and a 1800 s stall.
async function armSpotWatch() {
  for (let i = 0; i < CFG.spotArmTries; i += 1) {
    if (imdsToken()) {
      spotTimer = setInterval(onSpotTick, CFG.spotPollMs);
      spotTimer.unref?.();                   // never keeps the process alive on its own
      log(`[serve] spot-interruption watch armed (every ${CFG.spotPollMs}ms; inert on on-demand)`);
      return;
    }
    if (i + 1 < CFG.spotArmTries) await new Promise((r) => setTimeout(r, 1000));
  }
  log(`[serve] no IMDS after ${CFG.spotArmTries} tries — spot watch off (not an EC2 instance?)`);
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
  if (spotNotice) return [];                 // reclaimed: take nothing new (serve() is on its way out)
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
  // Record the claim BEFORE the first await: the spot watcher runs on a timer, and a claim it
  // cannot see is a claim it cannot hand back. Nothing between here and the delete yields.
  const claim = { handle: msg.ReceiptHandle, body: msg.Body, songId, resultPosted: false };
  inflight = claim;
  try {
    const r = await processJob(songId, body.srcKey, tasks, body.dedup);
    execFileSync('aws', ['sqs', 'send-message', '--queue-url', CFG.resultsQueue,
      '--message-body', JSON.stringify(r), '--region', CFG.region], { stdio: 'ignore' });
    claim.resultPosted = true;         // past this point a reclaim deletes rather than requeues
    aws('sqs', 'delete-message', '--queue-url', CFG.jobsQueue, '--receipt-handle', msg.ReceiptHandle);
    log(`[poll] ${songId} [${tasks.join('+')}] done in ${r.workerSeconds}s`);
    return [r];
  } catch (e) {
    log(`[poll] ${songId} FAILED: ${e.message} — leaving for retry/DLQ`);
    pollFailed = true;                 // a FAILURE is not idleness — see serve()
    return [];
  } finally {
    // Drop the claim either way. On the failure path that is deliberate: the job failed on its own
    // merits, so it must keep marching toward the DLQ on its normal receive count — a spot requeue
    // would reset that and let a poison job cycle forever. RESIDUAL: such a job still waits out the
    // full visibility timeout before redelivery, exactly as it did before spot.
    if (inflight === claim) inflight = null;
  }
}

async function serve() {
  let lastActivity = Date.now();
  let total = 0;
  let errors = 0;
  log(`[serve] SQS consumer on ${CFG.jobsQueue.split('/').pop()}; idle-exit after ${CFG.idleSeconds}s`);
  await armSpotWatch();                      // awaited: arming RETRIES, and the loop must not start
                                             // claiming jobs while the watch is still standing up.
  for (;;) {
    // YIELD TO THE TIMERS PHASE, once per pass, before anything else. Without this the idle loop
    // is pure MICROTASKS: poll() returns [] from `if (!msg) return []` without ever awaiting real
    // I/O, so `await poll()` resolves as a microtask, Node drains the microtask queue forever, and
    // the event loop never reaches the timers phase — armSpotWatch's setInterval NEVER FIRES on an
    // idle worker. Measured before this line: 0 IMDS polls in a 20 s idle serve at a 2 s interval,
    // so `spotNotice` stayed null, the guard below never tripped, and poll() kept CLAIMING NEW JOBS
    // through the whole ~2-minute reclaim notice — the one thing the notice exists to stop.
    // A setTimeout (not setImmediate) is deliberate: it is the timers phase itself that must run,
    // and any interval already due fires in that same pass. Once per ~20 s long poll, so free.
    await new Promise((r) => setTimeout(r, 0));
    // The watcher exits the process outright when it releases a job mid-flight; this is the idle
    // case, where there is nothing to hand back and we can retire through the normal door.
    if (spotNotice) { log(`[serve] spot ${spotNotice} notice — retiring after ${total} job(s)`); break; }
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

// Entrypoint guard: parseSpotInterruption / releasePlan / stemsFromListing are imported by tests,
// and an unguarded main() would run the CLI — and exit(2) on the missing arg — the moment a test
// imported this file, taking the runner with it. Same guard, same reason, as stem-autoscaler.mjs.
if (process.argv[1] && /stem-worker\.mjs$/.test(process.argv[1])) {
  main().catch((e) => { log('FATAL', e.message); console.log(JSON.stringify({ ok: false, error: e.message })); process.exit(1); });
}
