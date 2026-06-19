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
import { spawn, execFile } from 'node:child_process';
import { readFileSync, existsSync, mkdirSync, writeFileSync, statSync, rmSync, readdirSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { homedir, hostname } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

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
  useAgent: process.env.RIP_AGENT === '1', // Phase 2: run the rip skill via a headless Claude agent (adaptive)
  sources: (process.env.RIP_SOURCES || `${REPO}/public/current-index.json,${REPO}/public/apple-music-index.json`)
    .split(',').map((s) => s.trim()).filter(Boolean),
  tmp: join(homedir(), '.pocketdj', 'rips'),
};
const PUBLIC_BASE = `https://${CFG.bucket}.s3.${CFG.region}.amazonaws.com`;
const publicUrl = (key) => `${PUBLIC_BASE}/${key}`;
mkdirSync(join(CFG.tmp, 'jobs'), { recursive: true });
const QUEUE_DIR = join(CFG.tmp, 'queue');
mkdirSync(QUEUE_DIR, { recursive: true });

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

function setPhase(job, phase, extra = {}) {
  Object.assign(job, { phase, ...extra, updatedAt: Date.now() });
  try { writeFileSync(join(CFG.tmp, 'jobs', `${job.jobId}.json`), JSON.stringify(job)); } catch { /* ignore */ }
}
function jobView(job) {
  if (!job) return null;
  const v = { jobId: job.jobId, songId: job.songId, phase: job.phase, message: job.message || null, url: job.url || null, error: job.error || null };
  if (job.phase === 'ripping' && job.realtime && job.ripStartedAt && job.totalMs) {
    const elapsedMs = Math.min(Date.now() - job.ripStartedAt, job.totalMs);
    v.progress = { elapsedMs, totalMs: job.totalMs, pct: Math.round((elapsedMs / job.totalMs) * 100) };
  } else if (job.phase === 'ripping') {
    v.progress = { indeterminate: true };
  }
  return v;
}
function fail(job, error) { job.error = error; setPhase(job, 'error'); if (job.resourceKey) inflight.delete(job.resourceKey); }

// ---- durable queue: a pending rip request survives a restart ----
// One file per songId; written on accept, deleted when the job finishes (ready/error).
// On startup any leftover files are re-enqueued (idempotent — skipped if already ripped).
const queueFile = (songId) => join(QUEUE_DIR, `${songId}.json`);
function persistQueue(job) {
  try { writeFileSync(queueFile(job.songId), JSON.stringify({ songId: job.songId, jobId: job.jobId, resourceKey: job.resourceKey, createdAt: job.createdAt })); } catch { /* ignore */ }
}
function clearQueue(songId) { try { rmSync(queueFile(songId)); } catch { /* not present */ } }

function enqueue(job) { queue.push(job); pump(); }
async function pump() {
  if (working) return;
  const job = queue.shift();
  if (!job) return;
  working = true;
  try { await runJob(job); } catch (e) { fail(job, e.message); }
  clearQueue(job.songId); // terminal (ready or error) → drop the durable request
  working = false;
  pump();
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
    const resourceKey = song.sourceType === 'analog' ? song.albumId : songId;
    if (inflight.has(resourceKey)) continue;
    const job = { jobId: randomUUID(), songId, resourceKey, phase: 'queued', createdAt: rec.createdAt || Date.now() };
    jobs.set(job.jobId, job);
    inflight.set(resourceKey, job.jobId);
    setPhase(job, 'queued');
    enqueue(job);
    resumed++;
  }
  if (resumed) console.error(`  resumed ${resumed} pending rip(s) from the queue`);
}

const jobFile = (jobId) => join(CFG.tmp, 'jobs', `${jobId}.json`);

async function runJob(job) {
  setPhase(job, 'searching');
  const song = songById.get(job.songId);
  if (!song) return fail(job, 'unknown songId');
  if (song.sourceType !== 'analog') return runDigitalJob(job, song);
  const album = albumById.get(song.albumId);
  if (!album?.pointer?.originalFilename) return fail(job, 'no analog file reference for this album');
  const src = join(CFG.analogBase, album.pointer.originalFilename);
  if (!existsSync(src)) return fail(job, `analog file not found: ${src}`);

  // transcode the WHOLE album to mp3 256 (user seeks; startMs recorded for auto-seek)
  setPhase(job, 'ripping', { realtime: false, message: 'transcoding album' });
  const out = join(CFG.tmp, `${album.id}.mp3`);
  await new Promise((res, rej) => {
    const ff = spawn('ffmpeg', ['-y', '-i', src, '-map', '0:a:0', '-codec:a', 'libmp3lame', '-b:a', '256k', out]);
    let err = '';
    ff.stderr.on('data', (d) => { err += d; });
    ff.on('close', (code) => (code === 0 ? res() : rej(new Error('ffmpeg failed: ' + err.slice(-300)))));
  });

  setPhase(job, 'uploading', { message: 'uploading to S3' });
  const key = `rips/${album.id}.mp3`;
  await aws(['s3', 'cp', out, `s3://${CFG.bucket}/${key}`, '--content-type', 'audio/mpeg']);
  const bytes = statSync(out).size;

  // register EVERY song of the album (one upload makes the whole album playable)
  const rippedAt = Date.now();
  for (const s of songsByAlbum.get(album.id) || []) {
    manifest[s.id] = {
      key, ext: 'mp3', bytes, source: 'analog', albumId: album.id,
      startMs: s.pointer?.startMs ?? null, durationMs: s.length ?? null, rippedAt,
    };
  }
  await saveManifest();

  job.url = publicUrl(key);
  setPhase(job, 'ready', { message: `album ${album.name} ready` });
  inflight.delete(job.resourceKey);
}

const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

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
  ];
  await new Promise((res) => {
    let p;
    if (CFG.useAgent) {
      const cmd = 'node scripts/rip-one.mjs ' + args.map(shq).join(' ');
      const prompt =
        `Rip one Apple Music song for PocketDJ. Run this command exactly:\n\n${cmd}\n\n` +
        `When it prints a line starting with RESULT {"ok":true …} you are done — stop. ` +
        `If it fails because the track isn't in the Apple Music library, add "${song.artist} — ${song.name}" ` +
        `to the library (search Music.app), then re-run the command once. Do nothing else.`;
      p = spawn('claude', ['-p', prompt, '--dangerously-skip-permissions'], { cwd: REPO });
    } else {
      p = spawn('node', [join(REPO, 'scripts/rip-one.mjs'), ...args], { cwd: REPO });
    }
    p.stdout.on('data', (d) => process.stderr.write(d));
    p.stderr.on('data', (d) => process.stderr.write(d));
    p.on('close', () => res());
  });
  // the worker wrote phases to the status file; read its final state
  let st = {};
  try { st = JSON.parse(readFileSync(sf, 'utf8')); } catch { /* ignore */ }
  if (st.phase === 'uploaded' && st.key) {
    manifest[song.id] = {
      key: st.key, ext: 'mp3', bytes: st.bytes || 0, source: 'digital',
      albumId: song.albumId, startMs: null, durationMs: song.length ?? null, rippedAt: Date.now(),
    };
    await saveManifest();
    job.url = publicUrl(st.key);
    setPhase(job, 'ready', { message: `${song.name} ready` });
  } else {
    fail(job, st.error || 'rip failed');
  }
  inflight.delete(job.resourceKey);
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
    return send(res, 200, { ok: true, host: hostname(), version: 1, analogBase: CFG.analogBase, bucket: CFG.bucket,
      catalog: { songs: songById.size, albums: albumById.size }, cached: Object.keys(manifest).length, auth: !!CFG.token });
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
  // POST /rip {songId}
  if (path === '/rip' && req.method === 'POST') {
    const { songId } = await readJson(req);
    const song = songId && songById.get(songId);
    if (!song) return send(res, 404, { error: 'unknown songId' });
    if (manifest[songId]) return send(res, 200, { jobId: null, songId, phase: 'ready', url: publicUrl(manifest[songId].key) });
    const resourceKey = song.sourceType === 'analog' ? song.albumId : songId;
    const existingId = inflight.get(resourceKey);
    if (existingId && jobs.has(existingId)) return send(res, 200, jobView(jobs.get(existingId)));
    const job = { jobId: randomUUID(), songId, resourceKey, phase: 'queued', createdAt: Date.now() };
    jobs.set(job.jobId, job);
    inflight.set(resourceKey, job.jobId);
    persistQueue(job); // durable: survives a restart
    setPhase(job, 'queued');
    enqueue(job);
    return send(res, 200, jobView(job));
  }
  return send(res, 404, { error: 'not found' });
});

console.error('PocketDJ rip-server starting…');
loadCatalog();
await loadManifest();
resumePending(); // re-enqueue any rip requests left pending by a previous run
server.listen(CFG.port, () => {
  console.error(`✓ listening on http://localhost:${CFG.port}  (analogBase=${CFG.analogBase}, bucket=${CFG.bucket}, auth=${CFG.token ? 'on' : 'off'})`);
});
