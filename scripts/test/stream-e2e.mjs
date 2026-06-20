#!/usr/bin/env node
// Synthetic end-to-end test of the live HLS path (Phase 5b) — no Audio Hijack, no
// Music, no S3. Boots the real rip-server with a one-song temp catalog and the fake
// capture worker (which produces a live HLS stream with ffmpeg), then exercises:
// POST /rip → poll /jobs (expect `streaming` + an /hls streamUrl) → GET the m3u8
// (assert it's an EVENT playlist whose segment URIs carry ?token=) → GET a segment
// (assert mp2t bytes). Also checks ?token= auth.
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
  FAKE_HLS_SECONDS: '6',
  HOME: join(work, 'home'), // isolate ~/.pocketdj
};

console.log('booting rip-server (fake HLS worker)…');
const srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });
const auth = { Authorization: `Bearer ${TOKEN}` };

try {
  let up = false;
  for (let i = 0; i < 50; i++) { try { const r = await fetch(`${base}/health`, { headers: auth }); if (r.ok) { up = true; break; } } catch { /* not yet */ } await sleep(200); }
  ok(up, 'server is up (/health)');

  const rr = await fetch(`${base}/rip`, { method: 'POST', headers: { 'content-type': 'application/json', ...auth }, body: JSON.stringify({ songId: SONG }) });
  const job = await rr.json();
  ok(rr.ok && job.jobId, `POST /rip accepted (job ${job.jobId})`);

  // poll /jobs until the HLS playlist is ready
  let view = job, gotStream = false;
  for (let i = 0; i < 80; i++) {
    const jr = await fetch(`${base}/jobs/${job.jobId}`, { headers: auth });
    view = await jr.json();
    if (view.streamUrl) { gotStream = true; break; }
    if (view.phase === 'error') break;
    await sleep(200);
  }
  ok(gotStream, `job reached streaming + streamUrl (${view.streamUrl || view.phase})`);
  ok(view.streamUrl === `/hls/${SONG}/index.m3u8`, `streamUrl is the HLS playlist (${view.streamUrl})`);

  // unauthorized is rejected
  const noauth = await fetch(`${base}/hls/${SONG}/index.m3u8`);
  ok(noauth.status === 401, `/hls without token → 401 (got ${noauth.status})`);

  // GET the playlist (what a native <audio> / hls.js loads)
  const pr = await fetch(`${base}/hls/${SONG}/index.m3u8?token=${TOKEN}`);
  ok(pr.ok, `GET m3u8?token → ${pr.status}`);
  ok((pr.headers.get('content-type') || '').includes('mpegurl'), 'm3u8 content-type is mpegurl');
  const m3u8 = await pr.text();
  ok(m3u8.includes('#EXTM3U'), 'playlist is a valid m3u8 (#EXTM3U)');
  ok(m3u8.includes('EXT-X-PLAYLIST-TYPE:EVENT'), 'playlist is an EVENT (live) playlist');
  const segLine = m3u8.split('\n').find((l) => l.startsWith('seg_'));
  ok(!!segLine, `playlist lists at least one segment (${segLine || 'none'})`);
  ok(!!segLine && segLine.includes(`?token=${TOKEN}`), 'segment URIs carry ?token= (rewritten)');

  // GET the first segment
  const segName = (segLine || '').split('?')[0];
  const sr = await fetch(`${base}/hls/${SONG}/${segName}?token=${TOKEN}`);
  ok(sr.ok, `GET ${segName}?token → ${sr.status}`);
  ok((sr.headers.get('content-type') || '').includes('mp2t'), 'segment content-type is video/mp2t');
  const seg = new Uint8Array(await sr.arrayBuffer());
  ok(seg.length > 1000, `segment has bytes (${seg.length})`);

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all live-HLS checks passed'}`);
} finally {
  srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
