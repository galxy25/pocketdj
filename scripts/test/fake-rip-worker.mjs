#!/usr/bin/env node
// Test fixture: a stand-in for rip-one.mjs (the digital capture worker) that
// simulates a real-time Apple Music rip WITHOUT Audio Hijack / Music / S3. It produces
// a live HLS stream (ffmpeg, a sine tone at native rate) under <tmp>/live/<songId>/ and
// publishes the same status contract (streamReady, phase `streaming`) the rip server
// serves, so the live `/hls` path can be tested end-to-end. It intentionally does NOT
// report `uploaded` — the server then fails the job cleanly with no S3 writes.
// Selected via RIP_WORKER=scripts/test/fake-rip-worker.mjs.
import { spawn } from 'node:child_process';
import { writeFileSync, existsSync, readFileSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const a = {};
for (let i = 2; i < process.argv.length; i++) { const k = process.argv[i]; if (k.startsWith('--')) a[k.slice(2)] = process.argv[++i]; }
const SONG = a['song-id'];
const STATUS = a.status;
const TMP = (a.tmp || join(homedir(), '.pocketdj', 'rips')).replace(/^~/, homedir());
const DUR = parseInt(process.env.FAKE_HLS_SECONDS || '6', 10);
mkdirSync(TMP, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function status(phase, extra = {}) {
  if (!STATUS) return;
  const prev = existsSync(STATUS) ? JSON.parse(readFileSync(STATUS, 'utf8')) : {};
  writeFileSync(STATUS, JSON.stringify({ ...prev, songId: SONG, phase, ...extra, updatedAt: Date.now() }));
}

const hlsDir = join(TMP, 'live', SONG);
try { rmSync(hlsDir, { recursive: true, force: true }); } catch { /* ignore */ }
mkdirSync(hlsDir, { recursive: true });

status('ripping', { realtime: true, ripStartedAt: Date.now(), totalMs: DUR * 1000, message: 'fake capture + segmenting' });

// -re = feed the synthetic input at native rate so segments appear over ~DUR seconds (live-like)
const ff = spawn('ffmpeg', [
  '-hide_banner', '-loglevel', 'error', '-re',
  '-f', 'lavfi', '-i', `sine=frequency=440:duration=${DUR}`,
  '-c:a', 'aac', '-b:a', '128k', '-ar', '44100',
  '-hls_time', '2', '-hls_playlist_type', 'event', '-hls_flags', 'independent_segments',
  '-hls_segment_filename', join(hlsDir, 'seg_%05d.ts'), join(hlsDir, 'index.m3u8'),
]);
ff.stderr.on('data', (d) => process.stderr.write(d));

let ready = false;
const watch = setInterval(() => {
  if (!ready && existsSync(join(hlsDir, 'seg_00000.ts'))) { ready = true; status('streaming', { streamReady: true, hls: true, message: 'streaming live (fake hls)' }); }
}, 150);

await new Promise((res) => ff.on('close', res));
clearInterval(watch);
status('done-fake', { message: 'fake stream complete' });
await sleep(50);
console.log('RESULT ' + JSON.stringify({ ok: false, error: 'fake worker — hls streaming verified, no upload' }));
