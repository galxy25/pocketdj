#!/usr/bin/env node
// Bridge the `rip` skill's output into the app: take a setlist's `*_ripped/` folder
// (or one file), transcode each capture to mp3 256, upload it to the public rips
// cache (rips/<songId>.mp3), run audio analysis (BPM/key + waveform), and register
// it with the rip server (POST /analysis) — so skill-ripped songs become playable
// AND get the same bpm/key/waveform as API-ripped ones.
//
//   node scripts/analyze-rip.mjs --dir "<unix>_<setlist>_ripped"
//   node scripts/analyze-rip.mjs --file capture.m4a --song-id sng_… [--no-upload]
// Env/flags: --server http://localhost:8787  --bucket  --region  --profile levi
import { analyzeAudio } from './lib/audio-analyze.mjs';
import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync, mkdirSync, rmSync } from 'node:fs';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';

const a = {};
for (let i = 2; i < process.argv.length; i++) { const k = process.argv[i]; if (k === '--no-upload') a.noUpload = true; else if (k.startsWith('--')) a[k.slice(2)] = process.argv[++i]; }
const SERVER = (a.server || process.env.RIP_SERVER || 'http://localhost:8787').replace(/\/$/, '');
const BUCKET = a.bucket || 'pocketdj-rips-011183829623';
const REGION = a.region || 'us-west-2';
const PROFILE = a.profile || process.env.AWS_PROFILE || 'levi';
const TOKEN = a.token || process.env.RIP_TOKEN || '';
const TMP = join(homedir(), '.pocketdj', 'rips');
mkdirSync(TMP, { recursive: true });

function transcodeToMp3(src, songId) {
  const out = join(TMP, `${songId}.up.mp3`);
  execFileSync('ffmpeg', ['-y', '-i', src, '-map', '0:a:0', '-codec:a', 'libmp3lame', '-b:a', '256k', out], { stdio: 'ignore' });
  return out;
}
function upload(file, key, type) {
  execFileSync('aws', ['s3', 'cp', file, `s3://${BUCKET}/${key}`, '--content-type', type, '--profile', PROFILE, '--region', REGION], { stdio: 'ignore' });
}
async function submit(rec) {
  const r = await fetch(`${SERVER}/analysis`, { method: 'POST', headers: { 'content-type': 'application/json', ...(TOKEN ? { authorization: `Bearer ${TOKEN}` } : {}) }, body: JSON.stringify(rec) });
  if (!r.ok) throw new Error(`/analysis ${r.status}: ${(await r.text()).slice(0, 160)}`);
}

async function processOne({ songId, file, durationSec }) {
  if (!songId || !existsSync(file)) { console.error(`  skip ${songId}: missing file`); return false; }
  const mp3 = transcodeToMp3(file, songId);
  const key = `rips/${songId}.mp3`;
  if (!a.noUpload) upload(mp3, key, 'audio/mpeg');
  const an = await analyzeAudio({ file: mp3, songId, bucket: BUCKET, region: REGION, profile: PROFILE, tmp: TMP, withKey: true });
  try { rmSync(mp3); } catch { /* ignore */ }
  await submit({
    songId, key, source: 'digital',
    bpm: an.bpm, musicalKey: an.musicalKey, camelot: an.camelot, waveform: an.waveform,
    durationMs: an.durationSec ? Math.round(an.durationSec * 1000) : (durationSec ? Math.round(durationSec * 1000) : undefined),
  });
  console.error(`  ✓ ${songId}: bpm=${an.bpm} key=${an.musicalKey} wave=${!!an.waveform}`);
  return true;
}

async function main() {
  let items = [];
  if (a.dir) {
    const man = JSON.parse(readFileSync(join(a.dir, 'rip-manifest.json'), 'utf8'));
    items = (man.tracks || []).filter((t) => t.status === 'ok' && t.songId && t.file).map((t) => ({ songId: t.songId, file: join(a.dir, t.file), durationSec: t.durationSec }));
  } else if (a.file && a['song-id']) {
    items = [{ songId: a['song-id'], file: a.file }];
  } else {
    console.error('Usage: --dir <_ripped folder>  |  --file <audio> --song-id <sng_…>');
    process.exit(1);
  }
  console.error(`Processing ${items.length} ripped song(s) → ${BUCKET} + ${SERVER}/analysis`);
  let ok = 0;
  for (const it of items) { try { if (await processOne(it)) ok++; } catch (e) { console.error(`  ✗ ${it.songId}: ${e.message}`); } }
  console.error(`Done: ${ok}/${items.length}`);
}
main().catch((e) => { console.error(e); process.exit(1); });
