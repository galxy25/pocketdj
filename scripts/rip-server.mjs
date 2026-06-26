#!/usr/bin/env node
// PocketDJ rip-on-demand API (runs on the iMac). The PWA calls this over the LAN /
// Tailscale to rip a song/album that isn't yet in the public S3 rips cache.
//
// Phase 1: ANALOG fast path only — resolve the album's recording at
// $POCKETDJ_ANALOG_BASE/<originalFilename>, ffmpeg-transcode the WHOLE album to
// mp3 256k, upload to s3://<bucket>/rips/<albumId>.mp3, and register every song of
// that album in rips/manifest.json (each with its startMs for later auto-seek).
// Apple Music (real-time capture via the rip skill / Claude agent) is Phase 2.
//
// Poll model: POST /rip → {jobId}; GET /jobs/:id → {phase,progress,url,error};
// phases queued→searching→ripping→uploading→ready (or error). Single-flight per
// album/song, concurrency 1.
//
// Dependency-free: node:http + shells to `ffmpeg` and `aws` (profile levi).
//
//   POCKETDJ_ANALOG_BASE=~/Downloads RIP_TOKEN=secret node scripts/rip-server.mjs
//   curl localhost:8787/health
import http from 'node:http';
import { spawn, execFile, execFileSync } from 'node:child_process';
import { readFileSync, existsSync, mkdirSync, writeFileSync, statSync, rmSync, readdirSync, openSync, fstatSync, readSync, closeSync, renameSync, copyFileSync } from 'node:fs';
import { randomUUID, createHash } from 'node:crypto';
import { homedir, hostname } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeAudio } from './lib/audio-analyze.mjs';
import { findInLibrary, loadLibraryXML, loadLibraryTSV, indexLibrary } from './lib/am-match.mjs';
import { foldCloudReindex } from './lib/cloud-reindex-fold.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, '..');

const CFG = {
  port: parseInt(process.env.RIP_PORT || '8787', 10),
  token: process.env.RIP_TOKEN || '', // bearer; empty = no auth (local dev)
  profile: process.env.AWS_PROFILE || 'levi',
  region: process.env.AWS_REGION || 'us-west-2',
  bucket: process.env.RIP_BUCKET || 'pocketdj-rips-011183829623',
  analogBase: (process.env.POCKETDJ_ANALOG_BASE || join(homedir(), 'Downloads')).replace(/^~/, homedir()),
  libraryXml: (process.env.POCKETDJ_LIBRARY_XML || join(homedir(), 'Downloads', 'Library.xml')).replace(/^~/, homedir()),
  // ---- AM-sync (daily 04:00 + on-demand /am-sync): keep "Apple Music (Local)" in step ----
  // Read the AUTO-MAINTAINED shared Library.xml (Music ▸ Settings ▸ Advanced ▸ "Share Library
  // XML…" writes ~/Music/Music/Library.xml as the library changes — always fresh, plain file
  // read, no removable-volume TCC). Distinct from CFG.libraryXml (the ~/Downloads/Library.xml
  // that feeds the cloud-rip probe + the rip skill). Falls back to CFG.libraryXml at runtime
  // if this file doesn't exist (warned). The change-set OUTPUT goes to downloadsDir (overridable
  // to a temp dir for tests); the machine-local DETECTION cursor lives in amSyncStateDir (never
  // in the repo — the cron-agent owns a SEPARATE ship cursor in index-out/apple-music/state.json).
  amLibraryXml: (process.env.POCKETDJ_AM_LIBRARY_XML
    || join(homedir(), 'Music', 'Music', 'Library.xml')).replace(/^~/, homedir()),
  downloadsDir: (process.env.POCKETDJ_DOWNLOADS_DIR
    || join(homedir(), 'Downloads')).replace(/^~/, homedir()),
  amSyncStateDir: (process.env.POCKETDJ_AM_STATE_DIR
    || join(homedir(), '.pocketdj', 'am-sync')).replace(/^~/, homedir()),
  ahRecDir: (process.env.POCKETDJ_AH_REC_DIR || join(homedir(), 'Music', 'Audio Hijack')).replace(/^~/, homedir()),
  useAgent: process.env.RIP_AGENT === '1', // Phase 2: run the rip skill via a headless Claude agent (adaptive)
  worker: process.env.RIP_WORKER || join(REPO, 'scripts/rip-one.mjs'), // digital capture worker (swappable for tests)
  sources: (process.env.RIP_SOURCES || `${REPO}/public/current-index.json,${REPO}/public/apple-music-index.json`)
    .split(',').map((s) => s.trim()).filter(Boolean),
  tmp: join(homedir(), '.pocketdj', 'rips'),
  // ITEM 10 (CRITIC-H): in-process cloud-analog -> public/current-index.json fold. The
  // ANALOG catalog file we fold INTO (cloud bpm/key/length precedence). Disable with
  // RIP_PUBLIC_FOLD=0. Defaults to the analog source in RIP_SOURCES (current-index.json).
  publicIndex: (process.env.RIP_PUBLIC_INDEX || `${REPO}/public/current-index.json`).replace(/^~/, homedir()),
  publicFold: process.env.RIP_PUBLIC_FOLD !== '0',
};
const PUBLIC_BASE = `https://${CFG.bucket}.s3.${CFG.region}.amazonaws.com`;
const publicUrl = (key) => `${PUBLIC_BASE}/${key}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------- self-healing: per-job watchdog + transient retry/backoff ----------------
// A capture that hangs (Music.app / Audio Hijack stuck) would otherwise leave `working`
// true forever and freeze the WHOLE queue. pump() races runJob against a DURATION-AWARE
// deadline; on the deadline we group-kill the active worker (the SAME kill /rip-cancel
// uses) and reject so the job fail()s and the queue advances. A transient failure (drive
// unmounted, network blip, watchdog timeout, spawn error) is REQUEUED with capped
// exponential backoff so a remount / blip self-heals; a permanent failure (unknown song,
// no analog reference, explicit cancel) is NOT retried.
// The test-override env vars (RIP_TEST_*) let the e2e shrink the timeouts/backoff so a
// hang/retry cycle runs in seconds; production uses the safe defaults.
const numEnv = (k, d) => (process.env[k] ? parseInt(process.env[k], 10) : d);
const SELFHEAL = {
  // digital/cloud real-time capture: (song length || default) * mult + buffer, floored/ceiled.
  digitalMult: 1.5,
  digitalBufferMs: numEnv('RIP_TEST_DIGITAL_BUFFER_MS', 90_000), // +90s for spawn/seek/upload slack
  digitalDefaultLenMs: 6 * 60_000, // unknown length → assume a 6-min song
  digitalFloorMs: numEnv('RIP_TEST_DIGITAL_FLOOR_MS', 90_000), // never kill a legit capture before this
  digitalCeilMs: 30 * 60_000,     // hard ceiling (a single track can't legitimately run 30 min)
  // analog ffmpeg transcode of a whole album + per-song cuts: a generous fixed cap (transcode
  // is fast; the cut pass adds a few ffmpeg+upload passes per song).
  analogCapMs: numEnv('RIP_TEST_ANALOG_CAP_MS', 20 * 60_000),
  // capped exponential backoff requeue for TRANSIENT failures.
  maxAttempts: numEnv('RIP_TEST_MAX_ATTEMPTS', 5), // total tries (attempt 1 = the original run)
  backoffMs: process.env.RIP_TEST_BACKOFF_MS
    ? process.env.RIP_TEST_BACKOFF_MS.split(',').map((s) => parseInt(s, 10))
    : [30_000, 120_000, 480_000, 480_000], // ~30s, 2m, 8m, 8m between retries (index by attempt-1)
};
function jobDeadlineMs(job, song) {
  const analog = song && song.sourceType === 'analog' && !job.preferCloud;
  if (analog) return SELFHEAL.analogCapMs;
  const lenMs = (song && song.length) || SELFHEAL.digitalDefaultLenMs;
  const d = lenMs * SELFHEAL.digitalMult + SELFHEAL.digitalBufferMs;
  return Math.min(SELFHEAL.digitalCeilMs, Math.max(SELFHEAL.digitalFloorMs, d));
}
// Permanent (never retry): not in catalog, no analog file reference, explicit cancel.
// Everything else (transient): drive/source missing, aws/s3/network, watchdog timeout,
// generic capture/ffmpeg spawn/exit errors → retry with backoff.
const TIMEOUT_MARK = 'watchdog timeout';
function isTransient(job, msg) {
  if (job.canceled || msg === 'canceled') return false;
  const m = String(msg || '');
  if (/unknown songId/.test(m)) return false;
  if (/no analog file reference/.test(m)) return false;
  return true; // analog source missing, s3/network, timeout, spawn/exit, generic capture failure
}

// Bump when the server gains capabilities the app must detect. The app warns (banner)
// when a reachable server reports an older protocol than it needs.
//   1 = original rip-on-demand   ·   2 = live HLS streaming (/hls)
const RIP_PROTOCOL = 2;
mkdirSync(join(CFG.tmp, 'jobs'), { recursive: true });
const QUEUE_DIR = join(CFG.tmp, 'queue');
mkdirSync(QUEUE_DIR, { recursive: true });
const SYNC_JOBS_DIR = join(CFG.tmp, 'sync-jobs'); // AM-sync job state (survives a mid-poll restart)
mkdirSync(SYNC_JOBS_DIR, { recursive: true });

// ---------------- catalog (songId/albumId → metadata) ----------------
const songById = new Map();
const albumById = new Map();
const songsByAlbum = new Map();
function loadCatalog() {
  for (const f of CFG.sources) {
    if (!existsSync(f)) { console.warn('  source missing:', f); continue; }
    const idx = JSON.parse(readFileSync(f, 'utf8'));
    const sourceType = idx.manifest?.sourceType || 'analog';
    const sourceName = idx.manifest?.sourceName || idx.manifest?.source || 'unknown';
    for (const a of idx.albums || []) albumById.set(a.id, { ...a, sourceType, sourceName });
    for (const s of idx.songs || []) {
      const rec = { ...s, sourceType, sourceName };
      songById.set(s.id, rec);
      if (s.albumId) {
        if (!songsByAlbum.has(s.albumId)) songsByAlbum.set(s.albumId, []);
        songsByAlbum.get(s.albumId).push(rec);
      }
    }
    console.error(`  loaded ${f} (${(idx.albums || []).length} albums, ${(idx.songs || []).length} songs)`);
  }
}

// ---------------- Apple Music library index (cloud-rip accept-time probe) ----------------
// When ripFromCloud is on, an ANALOG song that EXACT-matches a library entry is captured
// from Apple Music instead of the vinyl file. The 161MB library plist is parsed once and
// cached OFF the request path (warmLibIndex runs on a setImmediate at startup); if a cloud
// rip arrives before the index is warm, hasExactAMMatch returns false → analog (benign,
// the next request after warm goes cloud). EXACT-only by design: a loose subset match can
// capture the WRONG track, and a cloud rip is indistinguishable from a real rip, so vinyl
// (always the correct cut) wins for loose matches.
let libIndex = null, libIndexLoading = false;
function warmLibIndex() {
  if (libIndex || libIndexLoading) return;
  libIndexLoading = true;
  setImmediate(() => {
    try {
      const xml = CFG.libraryXml;
      let entries = [];
      if (existsSync(xml)) entries = loadLibraryXML(xml);
      else { const tsv = xml.replace(/\.xml$/, '.tsv'); if (existsSync(tsv)) entries = loadLibraryTSV(tsv); }
      libIndex = indexLibrary(entries);
      console.error(`  library index: ${libIndex.count} tracks`);
    } catch (e) { console.error('  library index failed', e.message); libIndex = indexLibrary([]); }
    finally { libIndexLoading = false; }
  });
}
function hasExactAMMatch(song) {
  if (!libIndex) return false;
  try { return findInLibrary(libIndex, song.artist || '', song.name || '').match === 'exact'; }
  catch { return false; }
}

// ---------------- manifest (in-memory mirror of s3://.../rips/manifest.json) ----------------
let manifest = {};
function aws(args) {
  return new Promise((res, rej) => {
    execFile('aws', [...args, '--profile', CFG.profile, '--region', CFG.region], { maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) rej(new Error(stderr || err.message)); else res(stdout);
    });
  });
}
async function loadManifest() {
  try {
    const out = await aws(['s3', 'cp', `s3://${CFG.bucket}/rips/manifest.json`, '-']);
    manifest = JSON.parse(out || '{}');
  } catch { manifest = {}; }
  console.error(`  manifest: ${Object.keys(manifest).length} songs cached`);
}
async function saveManifest() {
  const tmp = join(CFG.tmp, 'manifest.json');
  writeFileSync(tmp, JSON.stringify(manifest));
  await aws(['s3', 'cp', tmp, `s3://${CFG.bucket}/rips/manifest.json`, '--content-type', 'application/json']);
}

// ---------------- jobs ----------------
const jobs = new Map();         // jobId -> job
const inflight = new Map();      // resourceKey -> jobId
const queue = [];
let working = false;
// Cancellation support (POST /rip-cancel). activeJobId is set the INSTANT a job leaves
// the queue in pump() (BEFORE spawn) so a cancel landing in the shift→spawn gap is seen
// as "running" and short-circuits via the pre-spawn job.canceled guard. activeChild.p is
// the in-flight CAPTURE child (rip-one.mjs / ffmpeg) — the ONLY process /rip-cancel ever
// kills (never the aws s3 cp upload or saveManifest, which are idempotent and must finish).
const activeChild = { p: null };
let activeJobId = null;

// ---------------- AM-sync jobs (POST /am-sync → jobId · GET /am-sync/<id> → result set) ----------------
// A DEDICATED lightweight registry, NOT the capture `queue`/`pump`: jobView() strips
// everything except rip fields, so it can't carry the added/changed/removed result set the
// app + cron-agent consume. The sync job mirrors the SHAPE of a rip job (immediate jobId,
// poll-by-id) but owns its own map + on-disk mirror. Phases: queued → scanning → diffing →
// ready | error. Single-flight via amCheckRunning (mirrors backfillRunning).
const syncJobs = new Map();   // syncJobId -> { jobId, phase, message, error, result, createdAt, updatedAt }
let amCheckRunning = false;
const syncJobFile = (id) => join(SYNC_JOBS_DIR, `${id}.json`);
function setSyncPhase(job, phase, extra = {}) {
  Object.assign(job, { phase, ...extra, updatedAt: Date.now() });
  try { writeFileSync(syncJobFile(job.jobId), JSON.stringify(job)); } catch { /* ignore */ }
}
function readSyncJobFile(id) {
  try { return JSON.parse(readFileSync(syncJobFile(id), 'utf8')); } catch { return null; }
}
function newSyncJob() {
  const job = { jobId: randomUUID(), phase: 'queued', createdAt: Date.now(), message: null, error: null, result: null };
  syncJobs.set(job.jobId, job);
  setSyncPhase(job, 'queued');
  return job;
}

// Thin promise wrapper over spawn('node', …) resolving on a clean (code 0) exit — the house
// style for shelling to a node sub-script (mirrors runDigitalJob's detached spawn). Rejects
// with the tail of stderr on a non-zero exit so a diff failure surfaces in the sync job.
function spawnNode(args, opts = {}) {
  return new Promise((res, rej) => {
    const p = spawn('node', args, { cwd: REPO, ...opts });
    let err = '';
    p.stderr?.on('data', (d) => { err += d; if (err.length > 4000) err = err.slice(-4000); });
    p.stdout?.on('data', (d) => process.stderr.write(d)); // surface the indexer's progress
    p.on('error', rej);
    p.on('close', (code) => (code === 0 ? res() : rej(new Error(`node ${args[0]} exited ${code}: ${err.slice(-400)}`))));
  });
}

// Build the ~/Downloads change-set record (schema pocketdj-am-changeset/1). Self-sufficient:
// carries the EXACT library snapshot path + its sha256 so the cron-agent's full rebuild is
// deterministic + decoupled from Music's live state at cron time. Written only when added>0.
function buildChangeset(ms, snapshotPath, delta, added, counts, since) {
  let snapSha = null;
  try { snapSha = createHash('sha256').update(readFileSync(snapshotPath)).digest('hex'); } catch { /* best-effort */ }
  const albumNameById = new Map((delta.albums || []).map((a) => [a.id, a]));
  const addedFull = (delta.songs || []).map((s) => ({
    songId: s.id, albumId: s.albumId, title: s.name, artist: s.artist,
    album: albumNameById.get(s.albumId)?.name || null,
    trackNumber: s.trackNumber ?? null, appleMusicId: s.appleMusicId ?? null,
  }));
  return {
    schema: 'pocketdj-am-changeset/1',
    generatedAt: new Date(ms).toISOString(),
    ts: ms,
    source: { type: 'digital', sourceName: 'Apple Music (Local)' },
    librarySnapshot: snapshotPath,
    librarySnapshotSha256: snapSha,
    since: since || null,
    counts: { ...counts, albumsTouched: (delta.albums || []).length, playlists: (delta.playlists || []).length },
    added: addedFull,
    changed: [],
    removed: [],
  };
}

// The AM-check: read the (fresh) Library.xml, diff via the existing incremental indexer to a
// temp delta, harvest the ADDED set, and (when non-empty) write a change-set + an exact library
// snapshot to downloadsDir. Shared by the 04:00 timer and POST /am-sync. Single-flight.
//
// Cursor atomicity: run the indexer to a TEMP state file, and only rename(tmpState → stateFile)
// AFTER the change-set is durably written — so "change-set written" and "detection cursor
// advanced" are atomic. A crash before the rename re-detects the same set on the next call
// (no lost changeset); a crash after leaves a written changeset whose cursor already advanced.
async function runAmCheck(job) {
  // Single-flight: a check is a whole-library read + diff + cursor advance — two concurrent
  // runs would write duplicate change-sets for the same added set and race the renameSync of
  // the detection cursor. Early-out (the flag is cleared in finally ONLY for the run that owns
  // it — this throw happens BEFORE the try, so the in-flight run keeps the flag).
  if (amCheckRunning) {
    setSyncPhase(job, 'error', { error: 'another Apple Music check is already running' });
    throw new Error('a check is already running');
  }
  amCheckRunning = true;
  try {
    setSyncPhase(job, 'scanning');
    const haveShared = existsSync(CFG.amLibraryXml);
    const xml = haveShared ? CFG.amLibraryXml : CFG.libraryXml;
    if (!haveShared) console.error(`  am-sync: ${CFG.amLibraryXml} not found — falling back to ${CFG.libraryXml}`);
    if (!existsSync(xml)) throw new Error(`no Library.xml to read (looked at ${CFG.amLibraryXml} and ${CFG.libraryXml})`);
    mkdirSync(CFG.amSyncStateDir, { recursive: true });
    mkdirSync(CFG.downloadsDir, { recursive: true });
    const stateFile = join(CFG.amSyncStateDir, 'state.json');
    const tmpState = join(CFG.amSyncStateDir, `state.next-${Date.now()}.json`);
    const firstRun = !existsSync(stateFile);
    // The indexer's `Date Added` boundary is INCLUSIVE (it emits tracks with added >= since, and
    // writes back lastDateAdded = maxDateAdded). Reusing the raw cursor as `since` would re-detect
    // the single track sitting exactly at the cursor on EVERY run — writing a spurious change-set
    // (and copying the whole ~160MB library snapshot into Downloads) daily even with no new music.
    // So we pass an EXCLUSIVE since = cursor + 1ms: the boundary track is skipped, genuinely newer
    // tracks still emit, and a no-change day is a true zero. (A track added in the SAME millisecond
    // as the previous max but only present in a later export is the sole edge it can miss — and the
    // cron-agent's FULL rebuild indexes the whole snapshot anyway, so the live catalog still gets it.)
    let cursorIso = null;
    if (!firstRun) { try { cursorIso = JSON.parse(readFileSync(stateFile, 'utf8')).lastDateAdded || null; } catch { /* ignore */ } }
    let sinceIso;
    if (firstRun) {
      // SEED the cursor to "now" so the first run does NOT emit the whole (~93k-track) library
      // as "added" — only genuinely new tracks from the next run forward are detected.
      sinceIso = new Date().toISOString();
    } else if (cursorIso) {
      const t = Date.parse(cursorIso);
      sinceIso = Number.isFinite(t) ? new Date(t + 1).toISOString() : cursorIso;
    } else {
      sinceIso = new Date().toISOString();
    }
    const tmpDelta = join(CFG.tmp, `am-delta-${Date.now()}.json`);

    setSyncPhase(job, 'diffing');
    const args = [join(REPO, 'scripts/index-apple-music.mjs'), '--xml', xml, '--out', tmpDelta,
                  '--state', tmpState, '--since', sinceIso];
    await spawnNode(args);

    const delta = JSON.parse(readFileSync(tmpDelta, 'utf8'));
    rmSync(tmpDelta, { force: true });
    const added = (delta.songs || []).map((s) => ({
      songId: s.id, albumId: s.albumId, title: s.name, artist: s.artist, change: 'added',
    }));
    const counts = { added: added.length, changed: 0, removed: 0 };

    let changeSetPath = null;
    if (added.length > 0) {
      const ms = Date.now();
      const snap = join(CFG.downloadsDir, `pocketdj-am-library-${ms}.xml`);
      copyFileSync(xml, snap); // the EXACT snapshot the cron-agent rebuilds from
      changeSetPath = join(CFG.downloadsDir, `pocketdj-am-changeset-${ms}.json`);
      const cs = buildChangeset(ms, snap, delta, added, counts, sinceIso);
      writeFileSync(changeSetPath, JSON.stringify(cs, null, 2));
      console.error(`  am-sync: ${added.length} added → ${changeSetPath}`);
    } else {
      console.error('  am-sync: no new tracks (cursor advanced, no change-set written)');
    }
    // Advance the detection cursor ATOMICALLY only after the change-set is durable.
    renameSync(tmpState, stateFile);

    job.result = { added, changed: [], removed: [], counts, changeSetPath };
    setSyncPhase(job, 'ready');
    return job.result;
  } catch (e) {
    job.error = String(e?.message || e);
    setSyncPhase(job, 'error');
    throw e;
  } finally {
    amCheckRunning = false;
  }
}

function setPhase(job, phase, extra = {}) {
  Object.assign(job, { phase, ...extra, updatedAt: Date.now() });
  try { writeFileSync(join(CFG.tmp, 'jobs', `${job.jobId}.json`), JSON.stringify(job)); } catch { /* ignore */ }
}
function jobView(job) {
  if (!job) return null;
  const v = { jobId: job.jobId, songId: job.songId, phase: job.phase, message: job.message || null, url: job.url || null, error: job.error || null };
  const live = job.phase === 'ripping' || job.phase === 'streaming';
  if (live && job.realtime && job.ripStartedAt && job.totalMs) {
    const elapsedMs = Math.min(Date.now() - job.ripStartedAt, job.totalMs);
    v.progress = { elapsedMs, totalMs: job.totalMs, pct: Math.round((elapsedMs / job.totalMs) * 100) };
  } else if (live) {
    v.progress = { indeterminate: true };
  }
  // a live HLS playlist is available once the capture has produced its first segment
  if (job.streamReady && job.songId) v.streamUrl = `/hls/${encodeURIComponent(job.songId)}/index.m3u8`;
  return v;
}
function fail(job, error) { job.error = error; setPhase(job, 'error'); if (job.resourceKey) inflight.delete(job.resourceKey); }

// ---- shared rip-accept logic (single-flight, idempotent, durable) ----
// Factored out of POST /rip so the batch endpoint (POST /rip-collection) reuses the
// EXACT accept path: manifest-cached skip, single-flight inflight join by resourceKey
// (albumId for analog, songId for digital), else create job + persistQueue + enqueue.
// Returns { job, status, url } — POST /rip translates this back to its existing
// jobView/ready response so its contract stays byte-identical.
//   status: 'unknown' (not in catalog) | 'ready' (already ripped) | 'inflight'
//           (joined an in-progress job, no new enqueue) | 'queued' (newly enqueued)
function acceptRip(songId, ripFromCloud = false) {
  const song = songId && songById.get(songId);
  if (!song) return { job: null, status: 'unknown', url: null };
  if (manifest[songId]) return { job: null, status: 'ready', url: publicUrl(manifest[songId].key) };
  // Probe the library ONCE, here. wantCloud is the RESOLVED preference (post-probe), not
  // the raw request flag — it is what we persist + route on so persist/resume can never
  // disagree (a track later deleted from the library doesn't flip the resourceKey; it just
  // resumes as a cloud job that Tier-2-falls-back at capture). Per-SONG single-flight for a
  // cloud rip (rips/<songId>.mp3), per-ALBUM for the analog vinyl path (rips/<albumId>.mp3).
  const wantCloud = !!ripFromCloud && song.sourceType === 'analog' && hasExactAMMatch(song);
  const perSong = wantCloud || song.sourceType !== 'analog';
  const resourceKey = perSong ? songId : song.albumId;
  const existingId = inflight.get(resourceKey);
  if (existingId && jobs.has(existingId)) {
    const job = jobs.get(existingId);
    return { job, status: 'inflight', url: job.url || null };
  }
  const job = { jobId: randomUUID(), songId, resourceKey, preferCloud: wantCloud, phase: 'queued', createdAt: Date.now(), attempt: 1 };
  jobs.set(job.jobId, job);
  inflight.set(resourceKey, job.jobId);
  persistQueue(job); // durable: survives a restart (retry budget included)
  setPhase(job, 'queued');
  enqueue(job);
  return { job, status: 'queued', url: null };
}

// ---- cancel one song's rip (POST /rip-cancel) ----
// Idempotent. Returns 'alreadyDone' (already in the manifest), 'canceled' (a queued or
// running job for this song's resource was removed/killed), or 'notFound' (nothing to do).
// Mirrors acceptRip's single-flight key resolution: a job is keyed by songId (digital, or
// an analog cloud rip) OR by albumId (the analog vinyl path covers the whole album), so we
// probe inflight by BOTH candidate keys. canceledAlbums collects albumIds we canceled this
// request so /rip-cancel can fill 'canceled' for batch siblings of an analog album.
function cancelOne(songId, canceledAlbums) {
  const song = songId && songById.get(songId);
  if (!song) return 'notFound';
  if (manifest[songId]) return 'alreadyDone'; // already ripped (mirrors acceptRip 171)
  // digital/cloud uses songId; analog vinyl uses albumId — try both.
  const keys = song.albumId ? [songId, song.albumId] : [songId];
  let jobId = null;
  for (const k of keys) { const id = inflight.get(k); if (id && jobs.has(id)) { jobId = id; break; } }
  if (!jobId) return 'notFound';
  const job = jobs.get(jobId);

  // remember the album so batch siblings of an analog album also report canceled.
  if (job.resourceKey === song.albumId && song.albumId) canceledAlbums.add(song.albumId);

  // (A) the CURRENTLY-RUNNING job for this resource.
  if (activeJobId === jobId) {
    job.canceled = true;
    if (job.phase === 'uploading') {
      // Refuse the hard kill mid-upload: the aws s3 cp + saveManifest are idempotent and
      // must finish; the terminal canceled-guard then cleans up (fail → inflight.delete).
    } else if (activeChild.p) {
      // Group-kill (detached) to reap the worker's grandchildren (rip skill, tail, HLS
      // ffmpeg). Same kill the watchdog uses. Best-effort.
      killActiveChild();
    }
    // working stays true until runJob returns; pump() then drains the queue and the
    // terminal canceled-guard calls fail() → inflight.delete + clearQueue.
    return 'canceled';
  }

  // (B) a QUEUED job (not yet running) OR a job WAITING in a transient-retry backoff window
  // (inflight points at it, phase 'queued', but not yet in the run queue). Both cases: mark
  // canceled, drop any queue entry, release inflight + durable file. The backoff timer's
  // re-enqueue guards on job.canceled / the inflight pointer, so it becomes a no-op.
  const qi = queue.findIndex((q) => q.jobId === jobId);
  if (qi >= 0 || job.phase === 'queued') {
    job.canceled = true;
    if (qi >= 0) queue.splice(qi, 1);
    if (job.resourceKey) inflight.delete(job.resourceKey);
    clearQueue(job.songId);
    setPhase(job, 'error', { error: 'canceled' });
    return 'canceled';
  }
  // inflight points at a job that is neither active nor queued/pending (e.g. a finished/
  // errored job whose inflight entry lingers) → nothing to cancel.
  return 'notFound';
}

// ---- durable queue: a pending rip request survives a restart ----
// One file per songId; written on accept, deleted when the job finishes (ready/error).
// On startup any leftover files are re-enqueued (idempotent — skipped if already ripped).
const queueFile = (songId) => join(QUEUE_DIR, `${songId}.json`);
function persistQueue(job) {
  try { writeFileSync(queueFile(job.songId), JSON.stringify({ songId: job.songId, jobId: job.jobId, resourceKey: job.resourceKey, preferCloud: !!job.preferCloud, createdAt: job.createdAt, attempt: job.attempt || 1 })); } catch { /* ignore */ }
}
function clearQueue(songId) { try { rmSync(queueFile(songId)); } catch { /* not present */ } }

function enqueue(job) { queue.push(job); pump(); }

// Group-kill the in-flight capture child — the SAME kill /rip-cancel uses (reaps the
// worker's grandchildren: rip skill, tail, HLS ffmpeg). Best-effort.
function killActiveChild() {
  const p = activeChild.p;
  if (!p) return;
  try { process.kill(-p.pid, 'SIGKILL'); }
  catch { try { p.kill('SIGKILL'); } catch { /* already gone */ } }
}

// Schedule a TRANSIENT-failure retry of the same job WITHOUT holding the worker: the job
// is re-enqueued by a timer after the backoff so the next queued song runs meanwhile. The
// durable queue record carries the bumped attempt so a restart preserves the retry budget.
// A canceled job is never rescheduled (the caller already excludes it).
function scheduleRetry(job, prevMsg) {
  const next = (job.attempt || 1) + 1;
  const delay = SELFHEAL.backoffMs[Math.min(job.attempt - 1, SELFHEAL.backoffMs.length - 1)];
  console.error(`  retry-scheduled ${job.songId} attempt ${next}/${SELFHEAL.maxAttempts} in ${Math.round(delay / 1000)}s (was: ${prevMsg})`);
  const retry = {
    jobId: randomUUID(), songId: job.songId, resourceKey: job.resourceKey,
    preferCloud: !!job.preferCloud, phase: 'queued', createdAt: job.createdAt || Date.now(), attempt: next,
  };
  jobs.set(retry.jobId, retry);
  // keep single-flight: this resource stays inflight (pointing at the retry job) across the gap.
  inflight.set(retry.resourceKey, retry.jobId);
  persistQueue(retry); // durable: survives a restart with the bumped attempt
  setPhase(retry, 'queued', { message: `retry ${next}/${SELFHEAL.maxAttempts} after ${prevMsg}` });
  setTimeout(() => {
    if (retry.canceled) return; // canceled during the backoff window
    if (!inflight.has(retry.resourceKey) || inflight.get(retry.resourceKey) !== retry.jobId) return; // superseded/canceled
    enqueue(retry);
  }, delay).unref?.();
}

async function pump() {
  if (working) return;
  const job = queue.shift();
  if (!job) return;
  working = true;
  activeJobId = job.jobId; // mark running the instant it leaves the queue (closes the cancel race)
  let timedOut = false;
  try {
    const song = songById.get(job.songId);
    const deadline = jobDeadlineMs(job, song);
    let timer;
    const watchdog = new Promise((_, rej) => {
      timer = setTimeout(() => {
        timedOut = true;
        console.error(`  timeout-killed ${job.songId} after ${Math.round(deadline / 1000)}s (job ${job.jobId})`);
        killActiveChild(); // reuse the /rip-cancel group-kill so runJob's worker promise resolves
        rej(new Error(TIMEOUT_MARK));
      }, deadline);
      timer.unref?.();
    });
    try { await Promise.race([runJob(job), watchdog]); }
    finally { clearTimeout(timer); }
    // runJob set the terminal phase itself (ready/error). A watchdog win rejects → caught below.
    if (timedOut && job.phase !== 'error') fail(job, TIMEOUT_MARK);
  } catch (e) {
    // any throw (incl. the watchdog) → ensure the job is failed once and inflight is consistent.
    if (job.phase !== 'error') fail(job, e.message || String(e));
  } finally {
    // Decide retry vs terminal from the job's terminal error. A TRANSIENT failure (and not a
    // cancel) within the attempt cap → schedule a backoff retry (which re-holds inflight);
    // otherwise this is terminal and we drop the durable request + release inflight.
    const errMsg = job.error || (timedOut ? TIMEOUT_MARK : '');
    const retryable = job.phase === 'error' && !job.canceled
      && isTransient(job, errMsg) && (job.attempt || 1) < SELFHEAL.maxAttempts;
    if (retryable) {
      scheduleRetry(job, errMsg); // re-holds inflight for this resource (single-flight preserved)
      clearQueue(job.songId);     // the retry job re-persisted its own durable record
    } else {
      if (job.phase === 'error' && !job.canceled && isTransient(job, errMsg)) {
        console.error(`  gave-up ${job.songId} after ${job.attempt || 1}/${SELFHEAL.maxAttempts} attempts (${errMsg})`);
      }
      clearQueue(job.songId); // terminal (ready or give-up) → drop the durable request
    }
    // ALWAYS release the worker so the queue advances, even on an unexpected throw above.
    working = false;
    activeJobId = null;
    activeChild.p = null;
    pump();
  }
}

// Re-enqueue requests left in the queue dir by a previous run (crash/restart safe).
function resumePending() {
  let resumed = 0;
  let files = [];
  try { files = readdirSync(QUEUE_DIR).filter((f) => f.endsWith('.json')); } catch { return; }
  for (const f of files) {
    let rec; try { rec = JSON.parse(readFileSync(join(QUEUE_DIR, f), 'utf8')); } catch { continue; }
    const songId = rec?.songId;
    const song = songId && songById.get(songId);
    if (!song) { clearQueue(songId || f.replace('.json', '')); continue; }
    if (manifest[songId]) { clearQueue(songId); continue; } // already ripped while we were down
    // Reconstruct from the persisted RESOLVED preferCloud — do NOT re-probe the library
    // (re-probing could flip resourceKey between persist and resume if the library was
    // re-exported / the track deleted, mis-keying single-flight).
    const preferCloud = !!rec.preferCloud;
    const perSong = preferCloud || song.sourceType !== 'analog';
    const resourceKey = perSong ? songId : song.albumId;
    if (inflight.has(resourceKey)) continue;
    const job = { jobId: randomUUID(), songId, resourceKey, preferCloud, phase: 'queued', createdAt: rec.createdAt || Date.now(), attempt: rec.attempt || 1 };
    jobs.set(job.jobId, job);
    inflight.set(resourceKey, job.jobId);
    setPhase(job, 'queued');
    enqueue(job);
    resumed++;
  }
  if (resumed) console.error(`  resumed ${resumed} pending rip(s) from the queue`);
}

const jobFile = (jobId) => join(CFG.tmp, 'jobs', `${jobId}.json`);

// (Removed: legacy live progressive-MP3 streaming — activeJobForSong/streamStatus,
// the streamLive tailer, and the /stream/<id>.mp3 route. The client only streams via
// live HLS now: the job view emits streamUrl=/hls/<id>/index.m3u8, and the worker
// still publishes streamFile/streamReady to drive the HLS pipeline below.)

// ---- live HLS serving ----
// The worker writes a live HLS playlist + AAC/TS segments to <tmp>/live/<songId>/.
// iOS Safari plays HLS natively (a chunked progressive MP3 does not), so this is the
// live delivery path. The m3u8's segment URIs are rewritten to carry ?token= so the
// player's segment fetches authenticate (a native <audio> can't add an auth header).
const HLS_DIR = join(CFG.tmp, 'live');
function serveHls(res, songId, file) {
  if (!/^index\.m3u8$/.test(file) && !/^seg_\d+\.ts$/.test(file)) return send(res, 404, { error: 'not found' });
  const fp = join(HLS_DIR, songId, file);
  if (!existsSync(fp)) return send(res, 404, { error: 'not found' });
  const cors = { 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-store' };
  if (file.endsWith('.m3u8')) {
    let body = readFileSync(fp, 'utf8');
    if (CFG.token) body = body.replace(/^(seg_\d+\.ts)\s*$/gm, `$1?token=${encodeURIComponent(CFG.token)}`);
    res.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl', ...cors });
    return res.end(body);
  }
  const buf = readFileSync(fp); // a segment is only listed once ffmpeg has finished writing it
  res.writeHead(200, { 'Content-Type': 'video/mp2t', 'Content-Length': buf.length, ...cors });
  return res.end(buf);
}

async function runJob(job) {
  // Pre-spawn cancel guard: a /rip-cancel that landed in the shift→spawn gap (activeJobId
  // set, activeChild.p still null) short-circuits here before any worker starts.
  if (job.canceled) return fail(job, 'canceled');
  setPhase(job, 'searching');
  const song = songById.get(job.songId);
  if (!song) return fail(job, 'unknown songId');
  // Digital songs always capture from Apple Music; an analog song does too when its job
  // resolved to a cloud rip (preferCloud, set at accept time on an exact library match).
  if (song.sourceType !== 'analog' || job.preferCloud) return runDigitalJob(job, song);
  return runAnalogJob(job, song);
}

// ANALOG vinyl path (also the Tier-2 fallback target when a cloud capture fails). Owns its
// own terminal inflight.delete so it can be invoked both from runJob and from
// runDigitalJob's fallback branch.
async function runAnalogJob(job, song) {
  if (job.canceled) return fail(job, 'canceled'); // pre-spawn guard (also the Tier-2 fallback entry)
  const album = albumById.get(song.albumId);
  if (!album?.pointer?.originalFilename) return fail(job, 'no analog file reference for this album');
  const src = join(CFG.analogBase, album.pointer.originalFilename);
  if (!existsSync(src)) return fail(job, `analog file not found: ${src}`);

  // transcode the WHOLE album to mp3 256 (user seeks; startMs recorded for auto-seek)
  setPhase(job, 'ripping', { realtime: false, message: 'transcoding album' });
  const out = join(CFG.tmp, `${album.id}.mp3`);
  await new Promise((res, rej) => {
    // detached → own process group so /rip-cancel can group-kill the transcode child.
    const ff = spawn('ffmpeg', ['-y', '-i', src, '-map', '0:a:0', '-codec:a', 'libmp3lame', '-b:a', '256k', out], { detached: true });
    activeChild.p = ff;
    let err = '';
    ff.stderr.on('data', (d) => { err += d; });
    ff.on('close', (code) => {
      activeChild.p = null;
      if (code === 0) return res();
      // The non-zero close of a KILLED ffmpeg (watchdog timeout or /rip-cancel) would reject
      // an ALREADY-SETTLED runAnalogJob promise (the watchdog won the race in pump()), surfacing
      // as an unhandled rejection. The job already terminated (phase 'error' on timeout) or is
      // canceled, so swallow it (resolve); the canceled-guard below / pump() handle the outcome.
      if (job.phase === 'error' || job.canceled) return res();
      rej(new Error('ffmpeg failed: ' + err.slice(-300)));
    });
  });

  // Orphaned-continuation guard (mirrors runDigitalJob): on a WATCHDOG TIMEOUT pump() already
  // failed the job + scheduled the retry (re-holding inflight); the killed ffmpeg's swallowed
  // close LATER resumes here. Bail without uploading the partial transcode or touching inflight.
  if (job.phase === 'error') return;
  if (job.canceled) return fail(job, 'canceled'); // killed mid-transcode → don't upload
  setPhase(job, 'uploading', { message: 'uploading to S3' });
  const key = `rips/${album.id}.mp3`;
  await aws(['s3', 'cp', out, `s3://${CFG.bucket}/${key}`, '--content-type', 'audio/mpeg']);
  const bytes = statSync(out).size;

  // register EVERY song of the album (one upload makes the whole album playable) — but
  // SKIP any song that already has a per-song cloud rip (source!=='analog', key
  // rips/<songId>.mp3) so a sibling-triggered album re-rip preserves prior cloud entries.
  const rippedAt = Date.now();
  for (const s of songsByAlbum.get(album.id) || []) {
    const ex = manifest[s.id];
    if (ex && ex.source !== 'analog' && ex.key === `rips/${s.id}.mp3`) continue;
    manifest[s.id] = {
      key, ext: 'mp3', bytes, source: 'analog', albumId: album.id,
      startMs: s.pointer?.startMs ?? null, durationMs: s.length ?? null, rippedAt,
    };
  }
  // PER-SONG CUTS (burn-only): cut each song's chunk out of the album mp3 and upload it as
  // cuts/<songId>.mp3, so a Burn can include the individual track (for other DJ software's
  // "full song list" view) ALONGSIDE the whole-album backcase. Playback still uses the album +
  // startMs seek — `cutKey` is consumed only by the burn. A per-song cut failure is NON-FATAL
  // (the album entry alone still works). The album mp3 (`out`) is still in tmp here.
  for (const s of songsByAlbum.get(album.id) || []) {
    if (job.phase === 'error' || job.canceled) break;
    const e = manifest[s.id];
    if (!e || e.source !== 'analog' || e.albumId !== album.id) continue;   // skip cloud-rip songs
    const startMs = s.pointer?.startMs ?? e.startMs;
    const durMs = cutDurationMs(s, e);
    if (startMs == null || !durMs) continue;                               // no cut points → album-only
    const cutOut = join(CFG.tmp, `${s.id}.cut.mp3`);
    try {
      setPhase(job, 'ripping', { realtime: false, message: `cutting ${s.name || s.id}` });
      await new Promise((res, rej) => {
        const ff = spawn('ffmpeg', ['-y', '-ss', String(startMs / 1000), '-i', out,
          '-t', String(durMs / 1000), '-map', '0:a:0', '-codec:a', 'libmp3lame', '-b:a', '256k',
          '-metadata', `title=${s.name || ''}`, '-metadata', `artist=${s.artist || ''}`,
          '-metadata', `album=${album.name || ''}`, '-id3v2_version', '3', cutOut],
          { detached: true });
        activeChild.p = ff;
        let err = '';
        ff.stderr.on('data', (d) => { err += d; });
        ff.on('close', (code) => {
          activeChild.p = null;
          if (code === 0) return res();
          if (job.phase === 'error' || job.canceled) return res();        // killed → swallow
          rej(new Error('cut ffmpeg failed: ' + err.slice(-200)));
        });
      });
      if (job.phase === 'error' || job.canceled) { rmSync(cutOut, { force: true }); break; }
      // Under the PUBLIC `rips/` prefix (the bucket policy only makes rips/* public) and
      // distinct from a per-song cloud rip's `rips/<songId>.mp3` (the `.cut.` infix).
      const cutKey = `rips/${s.id}.cut.mp3`;
      await aws(['s3', 'cp', cutOut, `s3://${CFG.bucket}/${cutKey}`, '--content-type', 'audio/mpeg']);
      e.cutKey = cutKey;
      e.cutBytes = statSync(cutOut).size;
      e.cutRippedAt = Date.now();
      if (e.durationMs == null) e.durationMs = durMs;   // persist the derived length too
    } catch (err) {
      console.error(`  cut failed for ${s.id}: ${err.message}`);
    } finally {
      rmSync(cutOut, { force: true });
    }
  }
  await saveManifest();

  job.url = publicUrl(key);
  setPhase(job, 'ready', { message: `album ${album.name} ready` });
  inflight.delete(job.resourceKey);
  enqueueAnalysis(song.id); // background: album waveform (per-song bpm/key kept from catalog)
}

const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

// The cut duration (ms) for an analog song: the catalog `length`, else the manifest
// `durationMs`, else DERIVED from the segment boundaries (`pointer.endMs - startMs`) — many
// analog tracks carry start/end boundaries but a null `length`. Returns null when there's no
// usable duration (→ that song stays album-only, can't be cut).
function cutDurationMs(s, e) {
  let d = (s && s.length) ?? (e && e.durationMs);
  if (d == null && s?.pointer?.startMs != null && s?.pointer?.endMs != null) {
    d = s.pointer.endMs - s.pointer.startMs;
  }
  return d != null && d > 0 ? d : null;
}

// BACKFILL: slice a per-song cut for every analog manifest entry missing one, straight from the
// raw album source (no whole-album re-transcode), and add `cutKey` to the entry. Lets albums
// ripped before the cut feature gain the per-song burn export retroactively. Single-flight via
// `backfillRunning`. Runs OUTSIDE the job queue (its own ffmpeg passes); shares the in-memory
// `manifest` object so a concurrent rip's saveManifest won't drop these cutKeys.
let backfillRunning = false;
// Cut per-song chunks (MISSING a cut) out of analog album sources, TAGGED with title/artist/
// album ID3 metadata, and upload them. Single-flight via `backfillRunning`; runs OUTSIDE the job
// queue and shares the in-memory `manifest` so a concurrent rip's save won't drop these cutKeys.
async function backfillCuts() {
  const label = 'backfill-cuts';
  let done = 0, failed = 0, skipped = 0;
  const want = (e) => e.source === 'analog' && e.albumId && !e.cutKey;
  const albumIds = new Set();
  for (const e of Object.values(manifest)) if (want(e)) albumIds.add(e.albumId);
  console.error(`  ${label}: scanning ${albumIds.size} albums`);
  for (const albumId of albumIds) {
    const album = albumById.get(albumId);
    if (!album?.pointer?.originalFilename) { skipped++; continue; }
    const src = join(CFG.analogBase, album.pointer.originalFilename);
    if (!existsSync(src)) { console.error(`  ${label} skip ${albumId}: src missing ${src}`); skipped++; continue; }
    for (const s of songsByAlbum.get(albumId) || []) {
      const e = manifest[s.id];
      if (!e || !want(e)) continue;
      const startMs = s.pointer?.startMs ?? e.startMs;
      const durMs = cutDurationMs(s, e);
      if (startMs == null || !durMs) continue;
      const cutOut = join(CFG.tmp, `${s.id}.cut.mp3`);
      try {
        await new Promise((res, rej) => {
          const ff = spawn('ffmpeg', ['-y', '-ss', String(startMs / 1000), '-i', src,
            '-t', String(durMs / 1000), '-map', '0:a:0', '-codec:a', 'libmp3lame', '-b:a', '256k',
            '-metadata', `title=${s.name || ''}`, '-metadata', `artist=${s.artist || ''}`,
            '-metadata', `album=${album.name || ''}`, '-id3v2_version', '3', cutOut]);
          let err = ''; ff.stderr.on('data', (d) => { err += d; });
          ff.on('close', (code) => (code === 0 ? res() : rej(new Error(err.slice(-200)))));
        });
        const cutKey = `rips/${s.id}.cut.mp3`;
        await aws(['s3', 'cp', cutOut, `s3://${CFG.bucket}/${cutKey}`, '--content-type', 'audio/mpeg']);
        e.cutKey = cutKey; e.cutBytes = statSync(cutOut).size; e.cutRippedAt = Date.now();
        if (e.durationMs == null) e.durationMs = durMs;
        done++;
        if (done % 10 === 0) await saveManifest();
      } catch (err) {
        failed++; console.error(`  ${label} failed ${s.id}: ${err.message}`);
      } finally {
        rmSync(cutOut, { force: true });
      }
    }
    await saveManifest();
    console.error(`  ${label}: ${album.name} done (${done} done, ${failed} failed so far)`);
  }
  await saveManifest();
  console.error(`  ${label} DONE: ${done} cuts, ${failed} failed, ${skipped} albums skipped`);
}

// RETAG (tag-only): rewrite title/artist/album ID3 tags on EVERY existing analog cut WITHOUT
// re-cutting — download the cut, remux with `-c copy` (no re-encode, no source/drive needed),
// re-upload. Bumps cutRippedAt so the app's S3-timestamp auto-repull pulls the re-tagged file.
async function retagCuts() {
  let done = 0, failed = 0;
  const entries = Object.entries(manifest).filter(([, e]) => e.source === 'analog' && e.cutKey);
  console.error(`  retag-cuts: ${entries.length} cuts to re-tag`);
  for (const [id, e] of entries) {
    const s = songById.get(id);
    if (!s) continue;
    const album = albumById.get(e.albumId) || albumById.get(s.albumId);
    const inF = join(CFG.tmp, `${id}.in.mp3`);
    const outF = join(CFG.tmp, `${id}.tagged.mp3`);
    try {
      await aws(['s3', 'cp', `s3://${CFG.bucket}/${e.cutKey}`, inF]);
      await new Promise((res, rej) => {
        const ff = spawn('ffmpeg', ['-y', '-i', inF, '-map', '0:a:0', '-c', 'copy',
          '-map_metadata', '-1',
          '-metadata', `title=${s.name || ''}`, '-metadata', `artist=${s.artist || ''}`,
          '-metadata', `album=${album?.name || ''}`, '-id3v2_version', '3', outF]);
        let err = ''; ff.stderr.on('data', (d) => { err += d; });
        ff.on('close', (code) => (code === 0 ? res() : rej(new Error(err.slice(-200)))));
      });
      await aws(['s3', 'cp', outF, `s3://${CFG.bucket}/${e.cutKey}`, '--content-type', 'audio/mpeg']);
      e.cutBytes = statSync(outF).size; e.cutRippedAt = Date.now();
      done++;
      if (done % 10 === 0) await saveManifest();
    } catch (err) {
      failed++; console.error(`  retag failed ${id}: ${err.message}`);
    } finally {
      rmSync(inF, { force: true }); rmSync(outF, { force: true });
    }
  }
  await saveManifest();
  console.error(`  retag-cuts DONE: ${done} re-tagged, ${failed} failed`);
}

// Phase 2: Apple Music real-time capture via the `rip` skill (rip-one.mjs worker).
// Default: run the worker directly (deterministic). RIP_AGENT=1: run it via a headless
// Claude agent that can adaptively add a missing track to the library + retry.
async function runDigitalJob(job, song) {
  const album = albumById.get(song.albumId);
  const sf = jobFile(job.jobId);
  const args = [
    '--song-id', song.id, '--artist', song.artist || '', '--title', song.name || '',
    '--album', album?.name || '', '--length-ms', String(song.length || 0),
    '--status', sf, '--library-xml', CFG.libraryXml,
    '--bucket', CFG.bucket, '--region', CFG.region, '--profile', CFG.profile, '--tmp', CFG.tmp,
    '--ah-recordings-dir', CFG.ahRecDir,
  ];
  if (job.canceled) return fail(job, 'canceled'); // pre-spawn guard
  await new Promise((res) => {
    let p;
    // detached → own process group so /rip-cancel can group-kill the worker AND its
    // grandchildren (rip skill, `tail -f`, the HLS ffmpeg). stdio stays inherited/piped
    // (detached only makes the child a group leader) so the stderr surfacing below works.
    if (CFG.useAgent) {
      const cmd = 'node scripts/rip-one.mjs ' + args.map(shq).join(' ');
      const prompt =
        `Rip one Apple Music song for PocketDJ. Run this command exactly:\n\n${cmd}\n\n` +
        `When it prints a line starting with RESULT {"ok":true …} you are done — stop. ` +
        `If it fails because the track isn't in the Apple Music library, add "${song.artist} — ${song.name}" ` +
        `to the library (search Music.app), then re-run the command once. Do nothing else.`;
      p = spawn('claude', ['-p', prompt, '--dangerously-skip-permissions'], { cwd: REPO, detached: true });
    } else {
      p = spawn('node', [CFG.worker, ...args], { cwd: REPO, detached: true });
    }
    activeChild.p = p;
    p.stdout.on('data', (d) => process.stderr.write(d));
    p.stderr.on('data', (d) => process.stderr.write(d));
    p.on('close', () => { activeChild.p = null; res(); });
  });
  // Orphaned-continuation guard (mirrors the job.canceled guard below): on a WATCHDOG
  // TIMEOUT the race already rejected, pump() called fail(job, TIMEOUT) and scheduleRetry()
  // re-held inflight for the retry job. The killed worker's close event LATER resolves this
  // promise; that orphaned continuation must NOT run the terminal fail()/inflight.delete a
  // second time (it would wipe the retry's inflight.set and silently drop the retry). The
  // job has already terminated (phase 'error'), so bail without touching inflight.
  if (job.phase === 'error') return;
  // the worker wrote phases to the status file; read its final state
  let st = {};
  try { st = JSON.parse(readFileSync(sf, 'utf8')); } catch { /* ignore */ }
  // Terminal section with explicit PER-BRANCH inflight cleanup (NOT a trailing
  // unconditional delete) so Tier-2 fallback works: runAnalogJob owns the inflight.delete
  // when we fall back, and fail() already deletes inflight for a genuine failure.
  // Canceled mid-capture: do NOT fall back to ripping the vinyl (that's not what cancel
  // means) and do NOT register the partial capture. fail() clears inflight.
  if (job.canceled) return fail(job, 'canceled');
  const ok = st.phase === 'uploaded' && st.key;
  if (ok) {
    manifest[song.id] = {
      key: st.key, ext: 'mp3', bytes: st.bytes || 0, source: 'digital',
      albumId: song.albumId, startMs: null, durationMs: song.length ?? null, rippedAt: Date.now(),
    };
    await saveManifest();
    job.url = publicUrl(st.key);
    setPhase(job, 'ready', { message: `${song.name} ready` });
    enqueueAnalysis(song.id); // background: bpm/key/camelot + waveform for this song
    inflight.delete(job.resourceKey);
  } else if (job.preferCloud && song.sourceType === 'analog') {
    // Tier-2 fallback: an exact-match analog cloud rip that didn't capture → vinyl. Fall
    // back for BOTH a no-match (stale library) and a system failure (broken rig) so the
    // user always gets a playable song, but WARN on system so the operator sees it.
    if (st.reason === 'system') console.error(`  WARN cloud capture system failure for ${song.id} (${st.error}); falling back to analog`);
    return runAnalogJob(job, song); // runAnalogJob owns inflight.delete — do NOT touch it here
  } else {
    fail(job, st.error || 'rip failed'); // fail() deletes inflight
  }
}

// ---------------- background audio analysis (bpm/key + waveform) ----------------
// Keyed by the AUDIO FILE (a digital song's mp3, or an album's mp3 shared by its
// songs). Concurrency 1 (the Docker librosa run is heavy). The manifest is the
// durable state: entries without `analyzed` are resumed on startup.
const analysisQ = [];
let analyzing = false;
function enqueueAnalysis(songId) { if (songId && !analysisQ.includes(songId)) analysisQ.push(songId); pumpAnalysis(); }
async function pumpAnalysis() {
  if (analyzing) return;
  const songId = analysisQ.shift();
  if (!songId) return;
  analyzing = true;
  try { await analyzeManifestSong(songId); } catch (e) { console.error('  analysis failed', songId, e.message); }
  analyzing = false;
  pumpAnalysis();
}
async function analyzeManifestSong(songId) {
  const e = manifest[songId];
  if (!e || !e.key) return;
  const audioBase = e.key.replace(/^rips\//, '').replace(/\.mp3$/, ''); // albumId (analog) | songId (digital)
  const withKey = e.source !== 'analog'; // analog plays the whole album → keep the catalog's per-song bpm/key
  const local = join(CFG.tmp, `${audioBase}.dl.mp3`);
  try { await aws(['s3', 'cp', `s3://${CFG.bucket}/${e.key}`, local]); } catch { return; }
  console.error(`  analyzing ${audioBase} (key=${withKey})…`);
  const a = await analyzeAudio({ file: local, songId: audioBase, bucket: CFG.bucket, region: CFG.region, profile: CFG.profile, tmp: CFG.tmp, withKey });
  try { rmSync(local); } catch { /* ignore */ }
  // apply to every manifest entry that shares this audio file
  for (const ent of Object.values(manifest)) {
    if (ent.key !== e.key) continue;
    if (a.waveform) ent.waveform = a.waveform;
    if (withKey) { ent.bpm = a.bpm; ent.musicalKey = a.musicalKey; ent.camelot = a.camelot; if (a.durationSec) ent.durationMs = Math.round(a.durationSec * 1000); }
    ent.analyzed = true;
  }
  await saveManifest();
  console.error(`  ✓ analyzed ${audioBase}: bpm=${a.bpm} key=${a.musicalKey} wave=${!!a.waveform}`);
  // ITEM 10: a cloud (digital) rip just got analyzed → fold its bpm/key/length into the
  // public analog catalog (debounced, in-process, never deploys). Analog rips keep the
  // catalog's per-song values, so they don't trigger a fold.
  if (withKey && isCloudAnalogEntry(songId)) requestPublicFold();
}
function resumeAnalysis() {
  const seen = new Set();
  let n = 0;
  for (const [songId, e] of Object.entries(manifest)) {
    if (e.analyzed || seen.has(e.key)) continue;
    seen.add(e.key); enqueueAnalysis(songId); n++;
  }
  if (n) console.error(`  queued ${n} pending analysis job(s)`);
}

// ---------------- ITEM 10 (CRITIC-H): cloud-analog analysis -> public/current-index.json ----------------
// The runtime manifest overlay covers the row UI, but the SHIPPED analog catalog
// (public/current-index.json) still carries the suspect librosa bpm/key/length for songs
// that have since been cloud-ripped + analyzed (source 'digital', analyzed, EXACT am-match
// to an analog catalog song). When such an entry finishes analysis we fold the cloud
// bpm/key/camelot/length into public/current-index.json — IN-PROCESS (no detached node),
// inside the analysis single-flight, debounced to a single trailing run, atomic write,
// idempotent, cloud-precedence, provenance-stamped. NEVER deploys / invalidates CloudFront
// (logs a publish hint). Guards against clobbering uncommitted NON-reindex working-tree
// changes to the file (a human edit / a different content change is never overwritten).

// Is this a CLOUD-ANALOG entry worth a public fold? A digital+analyzed manifest entry whose
// matched catalog song lives in the ANALOG public index (so its catalog bpm/key is suspect).
// We do NOT require the song's own id to key the manifest — a separately-ripped DIGITAL copy
// of the matched Apple Music track (derived am songId) also qualifies; foldCloudReindex
// resolves both. The cheap gate here is just "an analyzed digital rip exists", which is the
// only kind of entry analysis ever produces for a digital/cloud rip.
function isCloudAnalogEntry(songId) {
  const e = manifest[songId];
  return !!e && e.source === 'digital' && e.analyzed === true;
}

// Structural guard: is the working-tree public index DIRTY with a change that is NOT a prior
// cloud-reindex fold? We compare the committed (HEAD) JSON to the working-tree JSON and
// require every difference to live ONLY in fold-owned fields: per-song length/bpm/key/
// camelot/cloudReindex, and index.manifest.cloudReindex. Any other delta (a re-index of a
// different field, a human edit, an albums change, a song add/remove) => NOT safe to clobber.
const FOLD_SONG_FIELDS = new Set(['length', 'bpm', 'key', 'camelot', 'cloudReindex']);
function headIndexJson(path) {
  // `git show HEAD:<repo-relative path>` — returns null if not tracked / no git.
  try {
    const rel = path.startsWith(REPO + '/') ? path.slice(REPO.length + 1) : path;
    const out = execFileSyncQuiet('git', ['-C', REPO, 'show', `HEAD:${rel}`]);
    return out == null ? null : JSON.parse(out);
  } catch { return null; }
}
function execFileSyncQuiet(cmd, args) {
  // tiny sync exec helper that returns stdout string or null (never throws). Used only for
  // the git working-tree guard, off the hot path (runs once per debounced fold).
  try {
    return execFileSync(cmd, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });
  } catch { return null; }
}
// Returns true iff the only differences between `head` and `work` are fold-owned fields.
function isFoldOnlyDiff(head, work) {
  if (!head || !work) return false;
  // manifest: only cloudReindex may differ.
  const hm = { ...(head.manifest || {}) }; const wm = { ...(work.manifest || {}) };
  delete hm.cloudReindex; delete wm.cloudReindex;
  if (JSON.stringify(hm) !== JSON.stringify(wm)) return false;
  // albums + any other top-level key must be byte-identical.
  for (const k of new Set([...Object.keys(head), ...Object.keys(work)])) {
    if (k === 'songs' || k === 'manifest') continue;
    if (JSON.stringify(head[k]) !== JSON.stringify(work[k])) return false;
  }
  // songs: same count + order; each song may differ ONLY in fold-owned fields.
  const hs = head.songs || []; const ws = work.songs || [];
  if (hs.length !== ws.length) return false;
  for (let i = 0; i < hs.length; i++) {
    const a = hs[i]; const b = ws[i];
    if (a.id !== b.id) return false;
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
      if (FOLD_SONG_FIELDS.has(k)) continue;
      if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) return false;
    }
  }
  return true;
}

let foldQueued = false;   // a fold is requested (trailing-debounce flag)
let foldRunning = false;  // a fold is executing (single-flight)
let foldTimer = null;
const FOLD_DEBOUNCE_MS = numEnv('RIP_TEST_FOLD_DEBOUNCE_MS', 1500);
// Request a public-index fold. Debounced to a SINGLE trailing run: rapid back-to-back
// analyses (a collection rip) coalesce into one fold. Safe to call from anywhere.
function requestPublicFold() {
  if (!CFG.publicFold) return;
  foldQueued = true;
  if (foldTimer) return;
  foldTimer = setTimeout(() => { foldTimer = null; runPublicFoldOnce(); }, FOLD_DEBOUNCE_MS);
  foldTimer.unref?.();
}
async function runPublicFoldOnce() {
  if (foldRunning) { return; } // a run is in flight; the trailing foldQueued flag re-fires it below
  if (!foldQueued) return;
  foldQueued = false;
  foldRunning = true;
  try { foldPublicIndex(); }
  catch (e) { console.error('  public-fold failed:', e.message); }
  finally {
    foldRunning = false;
    if (foldQueued) requestPublicFold(); // a request arrived mid-run → one more trailing run
  }
}
// The actual fold (synchronous, fast: it's a metadata pass over the in-memory catalog).
function foldPublicIndex() {
  const path = CFG.publicIndex;
  if (!existsSync(path)) { console.error(`  public-fold skipped: index not found ${path}`); return; }
  if (!libIndex) { console.error('  public-fold skipped: library index not warm yet'); return; }
  const index = JSON.parse(readFileSync(path, 'utf8'));
  if ((index.manifest?.sourceType) !== 'analog') {
    console.error(`  public-fold skipped: ${path} sourceType is '${index.manifest?.sourceType}', expected 'analog'`);
    return;
  }
  // Working-tree guard: if the file is DIRTY vs HEAD and the dirt is NOT a prior fold, do
  // NOT clobber it. (A clean file, or one whose only delta is a prior cloudReindex fold, is
  // safe.) If there's no git/HEAD baseline we proceed (nothing to protect).
  const head = headIndexJson(path);
  if (head && !isFoldOnlyDiff(head, index)) {
    console.error(`  public-fold skipped: ${path} has uncommitted NON-reindex changes — refusing to clobber`);
    return;
  }

  const report = foldCloudReindex(index, libIndex, manifest, {});
  if (report.changed === 0) {
    // idempotent no-op: nothing to write (re-run after the values are already folded).
    return;
  }
  // stamp provenance (audit) — wall-clock here is fine (the file is NOT byte-idempotent in
  // the server context; we gate the WRITE on report.changed, not on byte-equality).
  index.manifest = index.manifest || {};
  index.manifest.cloudReindex = {
    generatedAt: new Date().toISOString(),
    source: 'rip-server in-process',
    matched: report.matched,
    lengthUpdated: report.lengthUpdated,
    bpmKeyUpdatedFromCloud: report.bpmKeyUpdatedFromCloud,
    changed: report.changed,
  };
  // ATOMIC write: temp file in the SAME dir + rename (rename is atomic on the same fs).
  const tmp = `${path}.fold-${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(index));
  renameSync(tmp, path);
  console.error(`  ✓ public-fold: ${report.changed} song(s) updated in ${path} (matched=${report.matched}, length=${report.lengthUpdated}, bpm/key=${report.bpmKeyUpdatedFromCloud})`);
  console.error(`  ⚠ public-fold did NOT deploy — run \`bash scripts/deploy.sh dev\` (or prod) to publish the updated catalog.`);
}

// ---------------- HTTP ----------------
function send(res, status, body) {
  const payload = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': typeof body === 'string' ? 'text/plain' : 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization,content-type',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  });
  res.end(payload);
}
function authed(req) {
  if (!CFG.token) return true;
  const h = req.headers['authorization'] || '';
  return h === `Bearer ${CFG.token}`;
}
async function readJson(req) {
  return new Promise((res) => { let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => { try { res(b ? JSON.parse(b) : {}); } catch { res({}); } }); });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const path = url.pathname;
  if (req.method === 'OPTIONS') return send(res, 204, '');

  if (path === '/health') {
    return send(res, 200, { ok: true, host: hostname(), version: RIP_PROTOCOL, hls: true, analogBase: CFG.analogBase, bucket: CFG.bucket,
      catalog: { songs: songById.size, albums: albumById.size }, cached: Object.keys(manifest).length, auth: !!CFG.token });
  }
  // GET /hls/<songId>/<index.m3u8|seg_N.ts> — live HLS (iOS-native). Same ?token= auth.
  const hm = path.match(/^\/hls\/([^/]+)\/([A-Za-z0-9_.-]+)$/);
  if (hm && req.method === 'GET') {
    const qok = !CFG.token || url.searchParams.get('token') === CFG.token;
    if (!authed(req) && !qok) return send(res, 401, { error: 'unauthorized' });
    return serveHls(res, decodeURIComponent(hm[1]), hm[2]);
  }

  if (!authed(req)) return send(res, 401, { error: 'unauthorized' });

  // GET /status/:songId
  let m = path.match(/^\/status\/(.+)$/);
  if (m && req.method === 'GET') {
    const songId = decodeURIComponent(m[1]);
    if (manifest[songId]) return send(res, 200, { ready: true, url: publicUrl(manifest[songId].key), entry: manifest[songId] });
    const active = [...jobs.values()].find((j) => j.songId === songId && j.phase !== 'ready' && j.phase !== 'error');
    return send(res, 200, { ready: false, job: jobView(active) });
  }
  // GET /jobs/:id — prefer the on-disk status file (a digital worker writes its live
  // phases there) merged over the in-memory job (which carries the final url).
  m = path.match(/^\/jobs\/(.+)$/);
  if (m && req.method === 'GET') {
    const id = decodeURIComponent(m[1]);
    const job = jobs.get(id);
    if (!job) return send(res, 404, { error: 'no such job' });
    let st = job;
    try { st = { ...job, ...JSON.parse(readFileSync(jobFile(id), 'utf8')) }; } catch { /* in-memory only */ }
    return send(res, 200, jobView(st));
  }
  // POST /rip {songId} — single-song rip-on-demand (also the F1 stream-through
  // fire-and-forget target: idempotent + durable + non-blocking). Response shape is
  // unchanged: it goes through acceptRip() but translates the result back to the
  // exact jobView/ready/404 contract the app's RipsStore.Job decoder expects.
  if (path === '/rip' && req.method === 'POST') {
    const { songId, ripFromCloud } = await readJson(req);
    const r = acceptRip(songId, ripFromCloud);
    if (r.status === 'unknown') return send(res, 404, { error: 'unknown songId' });
    if (r.status === 'ready') return send(res, 200, { jobId: null, songId, phase: 'ready', url: r.url });
    return send(res, 200, jobView(r.job));
  }
  // POST /rip-collection {songIds:[...]} — Feature 2 RIP. Batch-enqueue every song in
  // a collection to be ripped + uploaded to S3, reusing the EXACT same durable queue,
  // single-flight dedup and concurrency-1 worker as /rip (via acceptRip). Returns a
  // per-song outcome array for partial-success UI. Same auth as /rip (the authed() gate
  // above — public when no token is configured). No length limit: it is async and the
  // durable queue scales out as needed.
  if (path === '/rip-collection' && req.method === 'POST') {
    const { songIds, ripFromCloud } = await readJson(req);
    const ids = Array.isArray(songIds) ? [...new Set(songIds)] : [];
    const results = ids.map((id) => {
      const r = acceptRip(id, ripFromCloud);
      return { songId: id, status: r.status, jobId: r.job ? r.job.jobId : null, url: r.url || (r.job && r.job.url) || null };
    });
    const counts = results.reduce((c, r) => { c[r.status] = (c[r.status] || 0) + 1; c.total++; return c; },
      { ready: 0, queued: 0, inflight: 0, unknown: 0, total: 0 });
    return send(res, 200, { results, counts });
  }
  // POST /backfill-cuts — slice a per-song cut chunk for EVERY analog manifest entry that lacks
  // one (`cutKey`), straight from the raw album source (NO whole-album re-transcode), so albums
  // ripped before the cut feature gain the per-song burn export retroactively. Runs in the
  // BACKGROUND (returns the candidate count immediately); progress + the final tally go to the
  // log. Idempotent + single-flight (a 2nd call while running is a no-op).
  if (path === '/backfill-cuts' && req.method === 'POST') {
    const candidates = Object.values(manifest).filter((e) => e.source === 'analog' && !e.cutKey).length;
    if (!backfillRunning) { backfillRunning = true; backfillCuts().finally(() => { backfillRunning = false; }); }
    return send(res, 200, { ok: true, candidates, running: backfillRunning });
  }
  // POST /retag-cuts — rewrite title/artist/album ID3 tags on every existing analog cut
  // (tag-only, no re-cut) + bump cutRippedAt so the app auto-repulls the re-tagged files.
  if (path === '/retag-cuts' && req.method === 'POST') {
    const cuts = Object.values(manifest).filter((e) => e.source === 'analog' && e.cutKey).length;
    if (!backfillRunning) { backfillRunning = true; retagCuts().finally(() => { backfillRunning = false; }); }
    return send(res, 200, { ok: true, cuts, running: backfillRunning });
  }
  // POST /rip-cancel {songIds:[...]} — Feature 1 STOP RIP. Cancels still-queued matching
  // jobs (splice queue + clear inflight + delete durable file) and KILLS the in-flight
  // capture child when a matching job is the currently-running one. Idempotent; returns a
  // per-song {canceled|notFound|alreadyDone} (same envelope shape as /rip-collection).
  // Resolves cancellations ALBUM-FIRST so every analog-album sibling in the batch reports
  // canceled (a single analog job covers every song of its album; the first sibling's
  // cancel removes the shared inflight entry, so subsequent siblings would otherwise miss).
  if (path === '/rip-cancel' && req.method === 'POST') {
    const { songIds } = await readJson(req);
    const ids = Array.isArray(songIds) ? [...new Set(songIds)] : [];
    const canceledAlbums = new Set(); // albumIds whose analog job we canceled this request
    const status = ids.map((songId) => cancelOne(songId, canceledAlbums));
    const results = ids.map((songId, i) => {
      let s = status[i];
      // Album-first fill: a sibling that missed its own lookup but whose album was canceled
      // in THIS request still reports canceled.
      if (s === 'notFound') {
        const song = songById.get(songId);
        if (song && !manifest[songId] && song.albumId && canceledAlbums.has(song.albumId)) s = 'canceled';
      }
      return { songId, status: s };
    });
    const counts = results.reduce((c, r) => { c[r.status] = (c[r.status] || 0) + 1; c.total++; return c; },
      { canceled: 0, notFound: 0, alreadyDone: 0, total: 0 });
    return send(res, 200, { results, counts });
  }
  // POST /analysis {songId, key?, bpm, musicalKey, camelot, waveform, durationMs?}
  // External analysis submission (the batch tool, for skill-ripped songs). Merges into
  // the manifest (creating the entry if a `key` is supplied for a freshly-uploaded mp3).
  if (path === '/analysis' && req.method === 'POST') {
    const a = await readJson(req);
    if (!a.songId) return send(res, 400, { error: 'songId required' });
    const e = manifest[a.songId] || (a.key ? { key: a.key, ext: 'mp3', source: a.source || 'digital', rippedAt: Date.now() } : null);
    if (!e) return send(res, 404, { error: 'unknown songId and no key to create it' });
    if (a.bpm != null) e.bpm = a.bpm;
    if (a.musicalKey != null) e.musicalKey = a.musicalKey;
    if (a.camelot != null) e.camelot = a.camelot;
    if (a.waveform) e.waveform = a.waveform;
    if (a.durationMs != null) e.durationMs = a.durationMs;
    e.analyzed = true;
    manifest[a.songId] = e;
    await saveManifest();
    // ITEM 10: external analysis of a cloud (digital) rip → fold into the public catalog.
    if (isCloudAnalogEntry(a.songId)) requestPublicFold();
    return send(res, 200, { ok: true, songId: a.songId });
  }
  // POST /am-sync — kick an Apple Music (Local) library check and return IMMEDIATELY with a
  // jobId (mirrors POST /rip's accept-and-poll shape). The check runs fire-and-forget; the
  // app polls GET /am-sync/<id> for the result set. A 404 here ⇒ older server ⇒ the client
  // surfaces "Server too old".
  if (path === '/am-sync' && req.method === 'POST') {
    const job = newSyncJob();
    const phase = job.phase; // snapshot 'queued' BEFORE the kick (runAmCheck's sync prefix mutates it)
    runAmCheck(job).catch((e) => { job.error = String(e?.message || e); setSyncPhase(job, 'error'); });
    return send(res, 200, { jobId: job.jobId, phase });
  }
  // GET /am-sync/<id> — poll the sync job's full result set (the app/agent contract). Falls
  // back to the on-disk mirror so a mid-poll server restart still resolves the job.
  const sm = path.match(/^\/am-sync\/([^/]+)$/);
  if (sm && req.method === 'GET') {
    const id = decodeURIComponent(sm[1]);
    const st = syncJobs.get(id) || readSyncJobFile(id);
    if (!st) return send(res, 404, { error: 'unknown sync job' });
    return send(res, 200, {
      jobId: st.jobId, phase: st.phase, message: st.message || null, error: st.error || null,
      result: st.result || null,
    });
  }
  return send(res, 404, { error: 'not found' });
});

console.error('PocketDJ rip-server starting…');
loadCatalog();
warmLibIndex(); // parse the Apple Music library off the request path (cloud-rip probe)
await loadManifest();
resumePending(); // re-enqueue any rip requests left pending by a previous run
resumeAnalysis(); // analyze any ripped songs that don't have bpm/key/waveform yet
server.listen(CFG.port, () => {
  console.error(`✓ listening on http://localhost:${CFG.port}  (analogBase=${CFG.analogBase}, bucket=${CFG.bucket}, auth=${CFG.token ? 'on' : 'off'})`);
});

// ---------------- daily 04:00 AM-sync scheduler (self-rearming setTimeout) ----------------
// The server is always up (Tailscale-exposed, externally supervised), so an in-process timer
// is the simplest scheduler — no launchd needed, matches house style (unref'd setTimeout).
// SELF-REARMING (recompute ms-to-next-04:00 on each fire) is DST- + missed-run-tolerant; a
// plain setInterval would drift. Idempotent: the amCheckRunning guard prevents overlap with a
// manual POST /am-sync, and re-arming just schedules the following 04:00 after a sleep/miss.
// The change-set it produces is consumed by the app (Settings button) + the cron Claude-agent.
function msUntilNext(hour = 4, now = new Date()) {
  const next = new Date(now);
  next.setHours(hour, 0, 0, 0);
  if (next <= now) next.setDate(next.getDate() + 1);
  return next - now;
}
function scheduleDailyAmCheck() {
  const t = setTimeout(async () => {
    try {
      if (!amCheckRunning) {
        const job = newSyncJob(); // internal (not exposed via an endpoint)
        console.error('  am-sync: 04:00 scheduled check starting…');
        await runAmCheck(job).catch((e) => console.error('  am-sync 04:00 check failed:', e.message));
      }
    } finally {
      scheduleDailyAmCheck(); // re-arm for the NEXT 04:00
    }
  }, msUntilNext(4));
  t.unref?.();
}
// INERT GATE: never arm under tests/offline dry-runs (POCKETDJ_DISABLE_SCHEDULER=1). The user
// activates the daily check simply by NOT setting that env var on the running server.
if (process.env.POCKETDJ_DISABLE_SCHEDULER !== '1') scheduleDailyAmCheck();
