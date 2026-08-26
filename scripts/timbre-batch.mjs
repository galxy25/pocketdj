#!/usr/bin/env node
// timbre-batch — WARM-BATCH timbre backfill over every song that already has decodable audio.
//
//   node scripts/timbre-batch.mjs [--shards 6] [--max N] [--until HH:MM] [--sample N]
//        [--manifest s3|<path>] [--state-dir ~/.pocketdj/timbre-batch] [--dry-run] [--verbose]
//   node scripts/timbre-batch.mjs --tasks <file.json> [--shards 8] [--state-dir <dir>]
//
// ── --tasks MODE (the CLOUD lane; scripts/timbre-worker.mjs drives it) ─────────────────────────
// `--tasks <file.json>` supplies the work list DIRECTLY as a JSON array of task objects
// ([{id,kind:'s3-song'|'s3-cut',key}, …]) instead of deriving it from the manifest + analog
// catalog. In that mode the driver never reads the manifest, public/current-index.json or
// POCKETDJ_ANALOG_BASE — none of which exist on an EC2 worker. EVERYTHING downstream is the
// same code: the same ranged GET, the same warm docker shards, the same
// {id,v,src,atMs,ms,ok,f,durationSec} result row. That is the parity argument: the cloud runs
// the driver that measured the existing corpus, not a re-implementation of it.
//
// WHY THIS EXISTS: the nightly rec-audio job runs ONE `docker run` per song, and F10 measured
// 93% of its ~14 s/song timbre cost as per-process warm-up (python start + librosa import +
// numba JIT). This driver keeps ONE long-lived worker per shard (scripts/timbre-warm-worker.py
// inside the SAME pocketdj-audio image — same librosa the lo/hi calibration was measured on),
// pays the warm-up once per shard, and streams tasks through it. The engine itself is still
// .claude/skills/analog-indexer/audio/analyze-timbre.py, exec()d per file by the worker, so the
// numbers are identical to the per-song path by construction.
//
// ── WHAT COUNTS AS "HAS AUDIO", AND WHICH BYTES WE ANALYSE ─────────────────────────────────────
// Three source classes, deduped one-task-per-song (order = precedence):
//   1. s3-song   — a per-song rip in the manifest (source 'digital', key rips/<id>.mp3): the
//                  cleanest capture of the recording. RANGED download (first RANGE_BYTES).
//   2. vinyl-cut — an analog-catalog song with its OWN segment boundaries (pointer.startMs +
//                  length/endMs) whose raw album file is on POCKETDJ_ANALOG_BASE: ffmpeg
//                  stream-copies the song's OWN window out of the shared album file, on the
//                  host, into the shard's staging dir. EVERY track on a side shares one file —
//                  the per-song cut is what keeps them from sharing one vector (the cutKey
//                  lesson; rec-audio-nightly's sourceKeyFor follows the same rule).
//   3. s3-cut    — an analog manifest entry whose per-song cut already lives on S3 (cutKey)
//                  when the raw album file is not available locally. RANGED download.
// A song with none of these is skipped WITH A REASON (state.json skips) — never fabricated.
// Segment identity is the SONG'S OWN pointer.startMs. trackNumber is never consulted
// (f2b427c5: wiki-tracklist position is not the rip's segment ordinal).
//
// ── THE 90-SECOND WINDOW: WHY A RANGED/TRUNCATED READ IS EXACT, NOT APPROXIMATE ────────────────
// The engine analyses a 90 s window starting at off = min(5% of file length, 5 s). So:
//   · any file ≥ 100 s long gets off = 5 s → the window ends by 95 s;
//   · any file < 100 s is shorter than our truncation anyway and is read whole.
// Therefore reading only the first CUT_WINDOW_SEC (130 s) of audio — or the first RANGE_BYTES
// (5 MB ≈ 156 s at the rip pipeline's 256 kbps; ≥ 125 s even at 320 kbps, with slack for ID3
// headers) — yields BIT-IDENTICAL windows to a full-file read for every song: files the
// truncation touches are ≥ 100 s, where off is already clamped to 5 s. That is why we pull the
// window and not the full file: ~3× less S3 transfer and less mp3 to decode, at zero accuracy
// cost. (A song shorter than the range downloads whole — S3 serves a partial range as-is.)
//
// ── RESUMABLE / STOPPABLE ──────────────────────────────────────────────────────────────────────
// Results append to <state-dir>/results/shard-N.ndjson, one JSON line per song, written as each
// song finishes. On start the driver reads ALL result files and skips anything already done at
// the current TIMBRE_VERSION — a reboot, Ctrl-C, or `kill $(cat <state-dir>/pid)` loses at most
// the songs in flight. Engine-level failures ("too-short", undecodable) are recorded as done
// (empty) so they never wedge the queue — the rec-audio-nightly drain rule. Staging failures
// (S3 hiccup, ffmpeg error) are NOT recorded as done and retry on the next run.
// STOP: Ctrl-C or `kill $(cat ~/.pocketdj/timbre-batch/pid)` — finishes the in-flight song per
// shard, flushes results, removes containers. This never touches the rip server or its queue,
// so the app's collection-RIP Stop is unaffected.
//
// ── OUTPUT / FOLD ──────────────────────────────────────────────────────────────────────────────
// This driver only PRODUCES the corpus. `node scripts/fold-timbre.mjs` folds the results (+ the
// id-alias map) into public/timbre.json, and build-rec-features.mjs attaches the vectors to
// rec-features.json rows — the existing catalog build/deploy path ships both.
//
// ── RUNBOOK (measured on the iMac, 2026-08-11, 200-song proving run) ───────────────────────────
//   FULL RUN (one command, safe to re-fire any time — done songs skip):
//     node scripts/timbre-batch.mjs --shards 6
//   Measured warm rate: 5,679 songs/h (avg 3.7 s/song/shard, 6 shards; the old per-song docker
//   path was ~14 s serial ≈ 257/h — a ~22× improvement). Work list today: 12,022 audio-bearing
//   songs → remaining ~11.8k ≈ 2.1 h wall-clock. As lane 1's rips land in the manifest, simply
//   re-run the same command — new captures join the work list, everything done skips.
//   STOP:    Ctrl-C, or  kill $(cat ~/.pocketdj/timbre-batch/pid)     (in-flight songs finish,
//            containers remove themselves; the rip server and its Stop are untouched)
//   RESUME:  the same command — results/*.ndjson are the state; reboot-safe.
//   RESET:   rm -rf ~/.pocketdj/timbre-batch                          (full recompute)
//   THEN FOLD (idempotent, deterministic):
//     node scripts/build-timbre-aliases.mjs        # refresh id-aliases (reads lane 1 state if present)
//     node scripts/fold-timbre.mjs                 # results (+aliases) -> public/timbre.json
//     node scripts/build-rec-features.mjs          # attaches `t` vectors -> public/rec-features.json
//   and commit/deploy via the normal catalog path (deploy.sh rebuilds rec-features itself).
import { spawn, execFile as execFileCb } from 'node:child_process';
import { readFileSync, writeFileSync, appendFileSync, mkdirSync, existsSync, rmSync, copyFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { promisify } from 'node:util';
import { TIMBRE_VERSION } from './lib/audio-analyze.mjs';

const execFile = promisify(execFileCb);
const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const ENGINE_PY = join(REPO, '.claude/skills/analog-indexer/audio/analyze-timbre.py');
const WORKER_PY = join(REPO, 'scripts/timbre-warm-worker.py');

// Window constants — see the header proof for why these are exact, not approximate.
/// The engine's OWN contract rejections — the only failures that are permanent. Everything else
/// (a decode error, an IO error, a worker hiccup) is the environment and must stay retryable, or
/// the corpus acquires holes that no re-run can fill. Mirrors analyze-timbre.py's `fail()` reasons.
export const PERMANENT_ERRORS = new Set(['too-short', 'silent', 'degenerate-axes', 'non-finite-axis']);
/// 50× the ~3.5 s median. Only a desynchronised stream reaches it — see the id guard in startShard.
export const WORKER_TIMEOUT_MS = 180000;
export const CUT_WINDOW_SEC = 130;
export const RANGE_BYTES = 5 * 1024 * 1024;

// ── the two decisions the shard loop makes, as pure functions ──────────────────────────────────
// Both used to be inline one-liners inside a docker-spawning closure, which is to say untested.
// They are the two places this driver can silently corrupt or silently abandon the corpus, so
// they are seams now: tests/unit/timbre-batch.test.mjs drives them directly.

/// Does this worker line answer the task actually in flight? `pending` is the in-flight task
/// ({ id }) or null. Returns 'resolve' | 'unmatched' | 'mismatched'.
export function routeWorkerResponse(pending, msg) {
  if (!pending) return 'unmatched';
  if (msg?.id && msg.id !== pending.id) return 'mismatched';
  return 'resolve';
}

/// What did the engine actually say? 'ok' | 'permanent' | 'transient'. The distinction is the
/// difference between a row that must never be retried and one that must always be.
export function classifyResult(r) {
  if (r?.ok && r.f) return 'ok';
  return PERMANENT_ERRORS.has(String(r?.error || '').trim()) ? 'permanent' : 'transient';
}

// ── pure: per-song segment (the song's OWN identity — never trackNumber) ────────────────────────
export function segmentForSong(song, album) {
  const file = album?.pointer?.originalFilename || null;
  const startMs = song?.pointer?.startMs ?? null;
  let durMs = song?.length ?? null;
  if (durMs == null && startMs != null && song?.pointer?.endMs != null) {
    durMs = song.pointer.endMs - startMs;
  }
  if (file == null || startMs == null || durMs == null || durMs <= 0) return null;
  return { file, startMs, durMs };
}

// ── pure: the work list ─────────────────────────────────────────────────────────────────────────
/// manifest: the rip manifest object. analogIndex: parsed current-index.json. exists(absPath):
/// injectable fs probe (tests). Returns { tasks, skipped } — every audio-bearing song exactly
/// once, and every candidate that could NOT be given audio listed with a reason.
export function buildWorkList({ manifest, analogIndex, analogBase, exists }) {
  const tasks = new Map();          // id -> task (first insert wins; insertion order = precedence)
  const skipped = {};               // id -> reason
  const albums = new Map((analogIndex?.albums || []).map((a) => [a.id, a]));
  const analogSongById = new Map((analogIndex?.songs || []).map((s) => [s.id, s]));

  // 1. Per-song rips (source 'digital'): the song's own captured file, cleanest audio.
  for (const [id, e] of Object.entries(manifest || {})) {
    if (e?.source === 'digital' && e.key) tasks.set(id, { id, kind: 's3-song', key: e.key });
  }

  // 2. Vinyl: the song's OWN segment cut out of the shared raw album file.
  for (const s of analogIndex?.songs || []) {
    if (tasks.has(s.id)) continue;                       // per-song rip wins
    const seg = segmentForSong(s, albums.get(s.albumId));
    if (!seg) { skipped[s.id] = 'no-segment'; continue; }
    const abs = join(analogBase, seg.file);
    if (!exists(abs)) { skipped[s.id] = 'raw-missing'; continue; }
    delete skipped[s.id];
    tasks.set(s.id, { id: s.id, kind: 'vinyl-cut', file: abs, startMs: seg.startMs, durMs: seg.durMs });
  }

  // 3. Analog manifest entries not coverable locally: use the S3 per-song cut if one exists.
  for (const [id, e] of Object.entries(manifest || {})) {
    if (e?.source !== 'analog' || tasks.has(id)) continue;
    if (e.cutKey) { delete skipped[id]; tasks.set(id, { id, kind: 's3-cut', key: e.cutKey }); }
    else if (!skipped[id]) skipped[id] = 'analog-no-cut';
  }

  return { tasks: [...tasks.values()], skipped };
}

/// Pure: validate + normalize a --tasks file's contents into driver tasks. Accepts either a bare
/// array or {tasks:[…]}. Every entry needs an id and an S3 key; a `kind` defaults to 's3-song'
/// (the row's `src`, which is provenance only). Throws on a shape the driver could not stage —
/// a silently-dropped task would look like a completed song that never got a vector.
export function parseTasksFile(raw) {
  const arr = Array.isArray(raw) ? raw : (Array.isArray(raw?.tasks) ? raw.tasks : null);
  if (!arr) throw new Error('tasks file: expected an array or {tasks:[…]}');
  const seen = new Set();
  const out = [];
  for (const t of arr) {
    if (!t || typeof t.id !== 'string' || !t.id) throw new Error('tasks file: entry with no id');
    if (typeof t.key !== 'string' || !t.key) throw new Error(`tasks file: ${t.id} has no S3 key`);
    if (seen.has(t.id)) continue;                       // one task per song, first wins
    seen.add(t.id);
    out.push({ id: t.id, kind: t.kind === 's3-cut' ? 's3-cut' : 's3-song', key: t.key });
  }
  return out;
}

// ── args / config ───────────────────────────────────────────────────────────────────────────────
const a = {};
for (let i = 2; i < process.argv.length; i++) {
  const k = process.argv[i];
  if (k === '--dry-run') a.dryRun = true;
  else if (k === '--verbose') a.verbose = true;
  else if (k.startsWith('--')) a[k.slice(2)] = process.argv[++i];
}
const CFG = {
  dryRun: !!a.dryRun,
  shards: Math.max(1, Number(a.shards) || 6),
  max: a.max ? Number(a.max) : Infinity,
  sample: a.sample ? Number(a.sample) : 0,   // N per source class, for the proving run
  until: a.until || null,
  bucket: a.bucket || process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623',
  region: a.region || process.env.AWS_REGION || 'us-west-2',
  // '-' = NO --profile flag at all: the cloud lane runs on an EC2 instance role, where a named
  // profile does not exist and `--profile levi` fails every S3 call. Local runs keep the default.
  profile: a.profile || process.env.AWS_PROFILE || 'levi',
  image: a.image || process.env.AUDIO_IMAGE || 'pocketdj-audio:latest',
  analogBase: (a['analog-base'] || process.env.POCKETDJ_ANALOG_BASE || '/Volumes/RipBurnMix').replace(/^~/, homedir()),
  stateDir: (a['state-dir'] || join(homedir(), '.pocketdj', 'timbre-batch')).replace(/^~/, homedir()),
  manifest: a.manifest || null,
  tasks: a.tasks || null,            // --tasks <file.json>: cloud lane; see the header
};
const log = (...m) => console.error(`[timbre-batch ${new Date().toISOString()}]`, ...m);
const profileArgs = () => (CFG.profile && CFG.profile !== '-' ? ['--profile', CFG.profile] : []);

function deadlineMs(hhmm, now = new Date()) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(hhmm || '').trim());
  if (!m) return null;
  const d = new Date(now);
  d.setHours(Number(m[1]), Number(m[2]), 0, 0);
  if (d.getTime() <= now.getTime()) d.setDate(d.getDate() + 1);
  return d.getTime();
}

/// --manifest <path> reads a local file; --manifest s3 (or no local cache) pulls fresh from the
/// authoritative S3 copy. Default prefers the rip server's local cache — same seam as
/// fold-cloud-analysis and rec-audio-nightly.
async function loadManifestAsync() {
  if (CFG.manifest && CFG.manifest !== 's3') return JSON.parse(readFileSync(CFG.manifest, 'utf8'));
  const cache = join(homedir(), '.pocketdj', 'rips', 'manifest.json');
  if (CFG.manifest !== 's3' && existsSync(cache)) return JSON.parse(readFileSync(cache, 'utf8'));
  const out = await execFile('aws', ['s3', 'cp', `s3://${CFG.bucket}/rips/manifest.json`, '-',
    ...profileArgs(), '--region', CFG.region], { maxBuffer: 256 * 1024 * 1024 });
  return JSON.parse(out.stdout || '{}');
}

// ── done-state: the result files ARE the state ──────────────────────────────────────────────────
function loadDone(resultsDir) {
  const done = new Map();
  if (!existsSync(resultsDir)) return done;
  for (const f of readdirSync(resultsDir)) {
    if (!f.endsWith('.ndjson')) continue;
    for (const line of readFileSync(join(resultsDir, f), 'utf8').split('\n')) {
      if (!line.trim()) continue;
      try {
        const r = JSON.parse(line);
        if (r.id && r.v === TIMBRE_VERSION && (r.ok || r.permanent)) done.set(r.id, r);
      } catch { /* torn tail line from a crash — ignored, song simply re-runs */ }
    }
  }
  return done;
}

// ── staging ─────────────────────────────────────────────────────────────────────────────────────
async function stage(task, dest) {
  if (task.kind === 'vinyl-cut') {
    const startSec = task.startMs / 1000;
    const durSec = Math.min(task.durMs / 1000, CUT_WINDOW_SEC);
    // Stream copy (no re-encode): frame-granular (~26 ms) which the 90 s window is indifferent
    // to, and ~100× faster than a libmp3lame pass — the difference between cutting 10k songs
    // in minutes and in hours.
    // The COPY must land in a container that accepts the source codec: 416 raws are AIFF
    // (pcm_s16be), and copying PCM into the .mp3-named dest fails ffmpeg outright
    // ("Could not write header"). Match the source's own extension for non-mp3 raws —
    // librosa reads aiff/wav fine, and the worker is handed the real staged path.
    const srcExt = (task.file.match(/\.(aiff|aif|wav|flac|m4a)$/i) || [])[1];
    const realDest = srcExt ? dest.replace(/\.mp3$/, `.${srcExt.toLowerCase()}`) : dest;
    await execFile('ffmpeg', ['-y', '-ss', String(startSec), '-t', String(durSec),
      '-i', task.file, '-map', '0:a:0', '-c:a', 'copy', realDest], { timeout: 120000 });
    return realDest;
  }
  // s3-song / s3-cut: ranged GET of the analysis window (see header proof).
  await execFile('aws', ['s3api', 'get-object', '--bucket', CFG.bucket, '--key', task.key,
    '--range', `bytes=0-${RANGE_BYTES - 1}`, dest,
    ...profileArgs(), '--region', CFG.region], { timeout: 300000, maxBuffer: 1024 * 1024 });
}

// ── one shard: a long-lived docker worker + a stage-ahead queue ────────────────────────────────
function startShard(i, workDir) {
  mkdirSync(join(workDir, 'stage'), { recursive: true });
  copyFileSync(ENGINE_PY, join(workDir, 'analyze-timbre.py'));
  copyFileSync(WORKER_PY, join(workDir, 'timbre-warm-worker.py'));
  const name = `pdj-timbre-${process.pid}-${i}`;
  const child = spawn('docker', ['run', '--rm', '-i', '--name', name,
    '-v', `${workDir}:/work`, '--entrypoint', 'python', CFG.image,
    '/work/timbre-warm-worker.py', '/work/analyze-timbre.py'], { stdio: ['pipe', 'pipe', 'pipe'] });
  const shard = { i, name, child, buf: '', pending: null, ready: null, warmupMs: null };
  shard.readyPromise = new Promise((res) => { shard.ready = res; });
  child.stdout.on('data', (d) => {
    shard.buf += d;
    let nl;
    while ((nl = shard.buf.indexOf('\n')) >= 0) {
      const line = shard.buf.slice(0, nl).trim();
      shard.buf = shard.buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.ready) { shard.warmupMs = msg.warmupMs; shard.ready(); continue; }
      // THE RESPONSE MUST NAME THE SONG IT ANSWERS. The worker echoes the task id back and this
      // driver used to ignore it, resolving whatever was in flight with whatever arrived — so a
      // single stray or late line desynchronised the stream and every subsequent result was
      // written under the PREVIOUS song's id. That is not a lost song, it is a POISONED corpus:
      // a vector attributed to audio it did not come from, indistinguishable from a real one
      // downstream, and the cloud lane runs this same driver on EC2 at scale. Four rows of a
      // 223-song proving run came back in 2 ms (a 3.5 s workload) this way. An unmatched line is
      // dropped and logged; the in-flight task then times out and the next run retries it,
      // because a missing vector is recoverable and a WRONG one is not.
      const route = routeWorkerResponse(shard.pending, msg);
      if (route === 'unmatched') { log(`  ! [${i}] unmatched worker response for ${msg.id || '?'} — dropped`); continue; }
      if (route === 'mismatched') {
        log(`  ! [${i}] worker answered ${msg.id} while ${shard.pending.id} was in flight — dropped`);
        continue;
      }
      const p = shard.pending; shard.pending = null; p.resolve(msg);
    }
  });
  child.stderr.on('data', (d) => { if (a.verbose) process.stderr.write(`[shard ${i}] ${d}`); });
  child.on('close', (code) => {
    if (shard.pending) { const p = shard.pending; shard.pending = null; p.reject(new Error(`worker exited ${code}`)); }
    shard.exited = true;
  });
  shard.analyze = (task, containerPath) => new Promise((resolveP, rejectP) => {
    shard.pending = { id: task.id, resolve: resolveP, reject: rejectP };
    child.stdin.write(JSON.stringify({ id: task.id, path: containerPath }) + '\n');
  });
  return shard;
}

// ── main ────────────────────────────────────────────────────────────────────────────────────────
async function main() {
  const startedAt = Date.now();
  const until = CFG.until ? deadlineMs(CFG.until) : null;
  mkdirSync(join(CFG.stateDir, 'results'), { recursive: true });
  writeFileSync(join(CFG.stateDir, 'pid'), String(process.pid));

  let tasks; let skipped;
  if (CFG.tasks) {
    // CLOUD lane: the work list is handed to us. No manifest, no analog catalog, no /Volumes.
    tasks = parseTasksFile(JSON.parse(readFileSync(CFG.tasks, 'utf8')));
    skipped = {};
  } else {
    const manifest = await loadManifestAsync();
    const analogIndex = JSON.parse(readFileSync(join(REPO, 'public/current-index.json'), 'utf8'));
    ({ tasks, skipped } = buildWorkList({
      manifest, analogIndex, analogBase: CFG.analogBase, exists: existsSync,
    }));
  }
  const done = loadDone(join(CFG.stateDir, 'results'));
  let todo = tasks.filter((t) => !done.has(t.id));
  if (CFG.sample > 0) {
    // Proving run: N per source class so all three staging paths get exercised.
    const byKind = { 's3-song': [], 'vinyl-cut': [], 's3-cut': [] };
    for (const t of todo) byKind[t.kind]?.push(t);
    todo = [...byKind['s3-song'].slice(0, CFG.sample),
            ...byKind['vinyl-cut'].slice(0, CFG.sample),
            ...byKind['s3-cut'].slice(0, CFG.sample)];
  }
  if (Number.isFinite(CFG.max)) todo = todo.slice(0, CFG.max);
  writeFileSync(join(CFG.stateDir, 'state.json'), JSON.stringify({
    generatedAt: new Date().toISOString(), timbreVersion: TIMBRE_VERSION,
    total: tasks.length, alreadyDone: done.size, planned: todo.length,
    byKind: todo.reduce((m, t) => ((m[t.kind] = (m[t.kind] || 0) + 1), m), {}),
    skipped,
  }, null, 2));
  log(`work list: ${tasks.length} audio-bearing songs (${Object.keys(skipped).length} skipped-with-reason), `
    + `${done.size} already done at v${TIMBRE_VERSION}, ${todo.length} to run`);
  if (CFG.dryRun || !todo.length) { log(CFG.dryRun ? 'dry-run — stopping before docker' : 'nothing to do'); return; }

  let stopping = false;
  const stop = (sig) => { log(`${sig} — finishing in-flight songs, then stopping`); stopping = true; };
  process.on('SIGINT', () => stop('SIGINT'));
  process.on('SIGTERM', () => stop('SIGTERM'));

  const queue = todo[Symbol.iterator]();
  const counters = { ok: 0, failed: 0, stageFailed: 0 };
  const timings = [];

  const shards = [];
  for (let i = 0; i < CFG.shards; i++) {
    const workDir = join(CFG.stateDir, 'work', `shard-${i}`);
    rmSync(join(workDir, 'stage'), { recursive: true, force: true });
    shards.push(startShard(i, workDir));
  }
  log(`spawned ${shards.length} warm workers (${CFG.image}) — waiting for librosa warm-up`);

  const heartbeat = setInterval(() => {
    const doneN = counters.ok + counters.failed;
    const rate = doneN / ((Date.now() - startedAt) / 3600000);
    log(JSON.stringify({ heartbeat: true, done: doneN, planned: todo.length,
      ok: counters.ok, failed: counters.failed, stageFailed: counters.stageFailed,
      songsPerHour: Math.round(rate),
      etaMin: rate > 0 ? Math.round((todo.length - doneN) / rate * 60) : null }));
  }, 30000);

  async function runShard(shard) {
    await shard.readyPromise;
    log(`shard ${shard.i} warm in ${shard.warmupMs} ms`);
    const workDir = join(CFG.stateDir, 'work', `shard-${shard.i}`);
    const resultsFile = join(CFG.stateDir, 'results', `shard-${shard.i}.ndjson`);
    // Stage-ahead buffer: while the worker analyses song k, song k+1 downloads/cuts. Keeps the
    // python busy instead of alternating IO and compute.
    let ahead = null; // { task, path, err }
    const pull = () => {
      if (stopping || (until && Date.now() >= until)) return null;
      const n = queue.next();
      return n.done ? null : n.value;
    };
    const stageOne = async (task) => {
      const p = join(workDir, 'stage', `${task.id}.mp3`);
      // stage() may retarget the extension to match the source codec (AIFF raws);
      // whatever path it actually wrote is the one the worker must read.
      try { const real = (await stage(task, p)) || p; return { task, path: real }; }
      catch (e) { return { task, err: e.message }; }
    };
    let next = pull();
    if (next) ahead = stageOne(next);
    while (ahead) {
      const cur = await ahead;
      const n2 = pull();
      ahead = n2 ? stageOne(n2) : null;
      if (cur.err) {
        counters.stageFailed += 1;
        log(`  ✗ stage ${cur.task.id} (${cur.task.kind}): ${cur.err}`);
        continue; // NOT recorded as done — retries next run
      }
      const t0 = Date.now();
      try {
        const r = await Promise.race([
          shard.analyze(cur.task, `/work/stage/${basename(cur.path)}`),
          // With the id guard above, a dropped line means the in-flight promise never settles.
          // A shard that waits forever is worse than one that loses a song: bound it, and let the
          // NEXT run retry (no row is recorded, so the task stays in the work list). Abandoning
          // the slot is part of the fix — leave `pending` set and the worker's late answer would
          // arrive while the NEXT task occupies the slot, get dropped as mismatched, and time that
          // one out too, cascading a single hiccup down the rest of the shard.
          new Promise((_, rej) => setTimeout(() => {
            if (shard.pending?.id === cur.task.id) shard.pending = null;
            rej(new Error('worker timeout'));
          }, WORKER_TIMEOUT_MS)),
        ]);
        const ms = Date.now() - t0;
        const row = { id: cur.task.id, v: TIMBRE_VERSION, src: cur.task.kind, atMs: Date.now(), ms };
        if (cur.task.kind === 'vinyl-cut') { row.startMs = cur.task.startMs; row.durMs = cur.task.durMs; }
        const verdict = classifyResult(r);
        if (verdict === 'ok') {
          row.ok = true; row.f = r.f;
          // The RAW block rides along (14 floats). It is what makes a future rail recalibration a
          // RE-NORMALISATION instead of a re-extraction — the shipped corpus was built without it
          // and that is precisely why its rails could not be moved. fold-timbre keeps it out of
          // the published corpus and folds it into data/timbre-raw.json.
          if (r.r && typeof r.r === 'object') row.r = r.r;
          if (Number.isFinite(r.durationSec)) row.durationSec = r.durationSec;
          counters.ok += 1; timings.push(ms);
          if (a.verbose) log(`  ✓ [${shard.i}] ${cur.task.id} ${ms} ms`);
        } else if (verdict === 'permanent') {
          // The engine ran and REJECTED the audio on its own contract. Re-running cannot change
          // it: the cut really is under a second, really is silent, really is degenerate.
          row.ok = false; row.permanent = true; row.error = String(r.error).trim();
          counters.failed += 1;
          log(`  ✗ [${shard.i}] ${cur.task.id} permanent: ${row.error}`);
        } else {
          // ANYTHING ELSE IS THE ENVIRONMENT, NOT THE AUDIO — a decode error on a staged cut that
          // ffmpeg wrote short, an IO hiccup under six-way parallelism. This used to be recorded
          // as `permanent: 'no vector'`, which put the song in the done-set FOREVER: a transient
          // hiccup became a hole in the corpus no re-run could fill, and the only visible trace
          // was a coverage number that would not move. (Every one of the four such rows in a
          // 223-song proving run analysed CLEANLY when re-run by hand.) Dropped WITHOUT a row, so
          // the next run simply tries it again.
          counters.failed += 1;
          log(`  ✗ [${shard.i}] ${cur.task.id} transient (will retry): ${JSON.stringify(r).slice(0, 200)}`);
          continue;
        }
        appendFileSync(resultsFile, JSON.stringify(row) + '\n');
      } catch (e) {
        counters.failed += 1;
        log(`  ✗ [${shard.i}] ${cur.task.id} worker error: ${e.message}`);
        if (shard.exited) break; // container died — this shard is over, others carry on
      } finally {
        rmSync(cur.path, { force: true });
      }
    }
    try { shard.child.stdin.end(); } catch { /* already gone */ }
  }

  await Promise.all(shards.map(runShard));
  clearInterval(heartbeat);
  for (const s of shards) {
    if (!s.exited) { try { await execFile('docker', ['rm', '-f', s.name]); } catch { /* gone */ } }
  }
  rmSync(join(CFG.stateDir, 'pid'), { force: true });

  const mins = (Date.now() - startedAt) / 60000;
  const avg = timings.length ? Math.round(timings.reduce((x, y) => x + y, 0) / timings.length) : 0;
  const rate = counters.ok / (mins / 60);
  log(`done in ${mins.toFixed(1)} min — ok ${counters.ok} (avg ${avg} ms/song/shard, `
    + `${Math.round(rate)} songs/h across ${CFG.shards} shards), `
    + `permanent-failed ${counters.failed}, stage-failed ${counters.stageFailed}`);
  log(`fold with: node scripts/fold-timbre.mjs && node scripts/build-rec-features.mjs`);
}

if (process.argv[1] && process.argv[1].endsWith('timbre-batch.mjs')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
