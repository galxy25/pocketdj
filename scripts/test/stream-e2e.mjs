#!/usr/bin/env node
// Synthetic end-to-end test of the live progressive-stream path (Phase 5a) — no Audio
// Hijack, no Music, no S3. Boots the real rip-server with a one-song temp catalog and
// the fake capture worker, then exercises: POST /rip → poll /jobs (expect `streaming`
// + streamUrl) → GET /stream/<id>.mp3 and assert the tailed bytes flow with pre-roll
// and the response ends cleanly. Also checks ?token= auth on /stream.
//
//   node scripts/test/stream-e2e.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8799;
const TOKEN = 'test-secret';
const PREROLL = 32768;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://localhost:${PORT}`;
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-stream-'));
const SONG = 'sng_testlive01';
const catalog = join(work, 'catalog.json');
writeFileSync(catalog, JSON.stringify({
  manifest: { sourceType: 'digital', sourceName: 'Test' },
  albums: [{ id: 'alb_t', artist: 'Tester', name: 'Album', trackList: [SONG] }],
  songs: [{ id: SONG, albumId: 'alb_t', artist: 'Tester', name: 'Live Song', length: 6000 }],
}));

const env = {
  ...process.env,
  RIP_PORT: String(PORT),
  RIP_TOKEN: TOKEN,
  RIP_BUCKET: 'pocketdj-test-nonexistent-bucket-xyz', // loadManifest fails → empty manifest, no real S3 writes
  RIP_SOURCES: catalog,
  RIP_WORKER: join(REPO, 'scripts/test/fake-rip-worker.mjs'),
  RIP_STREAM_PREROLL_BYTES: String(PREROLL),
  FAKE_CHUNKS: '40',
  FAKE_STEP_MS: '120',
  POCKETDJ_AH_REC_DIR: join(work, 'ah'),
};
const tmpHome = join(work, 'home'); // keep ~/.pocketdj test state isolated
env.HOME = tmpHome;

console.log('booting rip-server (fake worker)…');
const srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });
const auth = { Authorization: `Bearer ${TOKEN}` };

try {
  // wait for health
  let up = false;
  for (let i = 0; i < 50; i++) { try { const r = await fetch(`${base}/health`, { headers: auth }); if (r.ok) { up = true; break; } } catch { /* not yet */ } await sleep(200); }
  ok(up, 'server is up (/health)');

  // POST /rip
  const rr = await fetch(`${base}/rip`, { method: 'POST', headers: { 'content-type': 'application/json', ...auth }, body: JSON.stringify({ songId: SONG }) });
  const job = await rr.json();
  ok(rr.ok && job.jobId, `POST /rip accepted (job ${job.jobId})`);

  // poll /jobs until streamUrl appears
  let view = job, gotStream = false;
  for (let i = 0; i < 60; i++) {
    const jr = await fetch(`${base}/jobs/${job.jobId}`, { headers: auth });
    view = await jr.json();
    if (view.streamUrl) { gotStream = true; break; }
    if (view.phase === 'error') break;
    await sleep(200);
  }
  ok(gotStream, `job reached streaming + streamUrl (${view.streamUrl || view.phase})`);
  ok(view.phase === 'streaming', `phase is "streaming" (got "${view.phase}")`);

  // unauthorized /stream is rejected
  const noauth = await fetch(`${base}/stream/${SONG}.mp3`);
  ok(noauth.status === 401, `/stream without token → 401 (got ${noauth.status})`);

  // GET /stream with ?token= (what a native <audio> uses) — read the live body
  const t0 = Date.now();
  const sr = await fetch(`${base}/stream/${SONG}.mp3?token=${TOKEN}`);
  ok(sr.ok, `GET /stream?token → ${sr.status}`);
  ok((sr.headers.get('content-type') || '').includes('audio/mpeg'), 'content-type audio/mpeg');
  ok(!sr.headers.get('content-length'), 'no Content-Length (chunked live stream)');
  const body = new Uint8Array(await sr.arrayBuffer());
  const elapsed = Date.now() - t0;
  ok(body.length >= PREROLL, `received ${body.length} bytes (≥ pre-roll ${PREROLL})`);
  ok(body.length >= 40 * 8 * 1024 * 0.8, `received ~full simulated capture (${body.length} bytes)`);
  ok(elapsed >= 200, `stream followed the capture in real time (${elapsed}ms, not instant)`);
  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all live-stream checks passed'}`);
} finally {
  srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
