#!/usr/bin/env node
// Test fixture: a stand-in for rip-one.mjs (the digital capture worker) that
// simulates a real-time Apple Music rip WITHOUT Audio Hijack / Music / S3. It writes
// a growing MP3 and publishes the same status contract (streamFile + streamReady,
// phase `streaming`) the rip server tails, so the live `/stream` path can be tested
// end-to-end. It intentionally does NOT report `uploaded` — the server then fails the
// job cleanly with no S3 writes. Selected via RIP_WORKER=scripts/test/fake-rip-worker.mjs.
import { writeFileSync, existsSync, readFileSync, mkdirSync, appendFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const a = {};
for (let i = 2; i < process.argv.length; i++) { const k = process.argv[i]; if (k.startsWith('--')) a[k.slice(2)] = process.argv[++i]; }
const SONG = a['song-id'];
const STATUS = a.status;
const TMP = (a.tmp || join(homedir(), '.pocketdj', 'rips')).replace(/^~/, homedir());
const PREROLL = parseInt(process.env.RIP_STREAM_PREROLL_BYTES || '65536', 10);
const CHUNK = 8 * 1024;
const CHUNKS = parseInt(process.env.FAKE_CHUNKS || '40', 10); // ~320KB total
const STEP_MS = parseInt(process.env.FAKE_STEP_MS || '120', 10);
mkdirSync(TMP, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function status(phase, extra = {}) {
  if (!STATUS) return;
  const prev = existsSync(STATUS) ? JSON.parse(readFileSync(STATUS, 'utf8')) : {};
  writeFileSync(STATUS, JSON.stringify({ ...prev, songId: SONG, phase, ...extra, updatedAt: Date.now() }));
}

const file = join(TMP, `${SONG}.live.mp3`);
writeFileSync(file, Buffer.alloc(0));
status('ripping', { realtime: true, ripStartedAt: Date.now(), totalMs: CHUNKS * STEP_MS, message: 'fake recording', streamFile: file });

let ready = false;
for (let i = 0; i < CHUNKS; i++) {
  appendFileSync(file, Buffer.alloc(CHUNK, i & 0xff)); // deterministic bytes
  if (!ready && statSync(file).size >= PREROLL) { ready = true; status('streaming', { streamFile: file, streamReady: true, message: 'streaming live (fake)' }); }
  await sleep(STEP_MS);
}
// capture done — exit WITHOUT `uploaded` so the server fails the job (no S3 side effects)
status('done-fake', { bytes: statSync(file).size });
console.log('RESULT ' + JSON.stringify({ ok: false, error: 'fake worker — streaming verified, no upload' }));
