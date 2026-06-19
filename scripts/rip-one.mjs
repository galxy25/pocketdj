#!/usr/bin/env node
// rip-one — capture ONE Apple Music song to mp3 256 and upload it to the public S3
// rips bucket. The deterministic worker behind the rip server's digital (Phase 2)
// path. Drives the `rip` skill (real-time Audio Hijack capture), then transcodes +
// uploads. Writes phase updates to a status file the rip server polls.
//
//   node scripts/rip-one.mjs --song-id sng_… --artist "…" --title "…" \
//     --length-ms 225000 --album "…" --status <jobfile.json> \
//     [--library-xml ~/Downloads/Library.xml] [--bucket …] [--region …] [--profile levi]
//
// Prints a final line: RESULT {"ok":true,"key":"rips/sng_….mp3","bytes":…}
import { spawn, execFileSync } from 'node:child_process';
import { readdirSync, statSync, writeFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const a = {};
for (let i = 2; i < process.argv.length; i++) { const k = process.argv[i]; if (k.startsWith('--')) a[k.slice(2)] = process.argv[++i]; }
const SONG = a['song-id'], ARTIST = a.artist || '', TITLE = a.title || '', ALBUM = a.album || '';
const LENGTH_MS = parseInt(a['length-ms'] || '0', 10) || null;
const LIBRARY_XML = (a['library-xml'] || join(homedir(), 'Downloads', 'Library.xml')).replace(/^~/, homedir());
const BUCKET = a.bucket || 'pocketdj-rips-011183829623';
const REGION = a.region || 'us-west-2';
const PROFILE = a.profile || 'levi';
const STATUS = a.status;
const TMP = (a.tmp || join(homedir(), '.pocketdj', 'rips')).replace(/^~/, homedir());
if (!SONG) { console.error('--song-id required'); process.exit(2); }
mkdirSync(TMP, { recursive: true });

function status(phase, extra = {}) {
  if (!STATUS) return;
  try {
    const prev = existsSync(STATUS) ? JSON.parse(readFileSync(STATUS, 'utf8')) : {};
    writeFileSync(STATUS, JSON.stringify({ ...prev, songId: SONG, phase, ...extra, updatedAt: Date.now() }));
  } catch { /* ignore */ }
}
const fail = (msg) => { status('error', { error: msg }); console.log('RESULT ' + JSON.stringify({ ok: false, error: msg })); process.exit(1); };

async function main() {
  status('searching', { message: 'locating track in Apple Music' });
  // minimal index + 1-row setlist so the rip skill resolves songId → artist/title
  const idxFile = join(TMP, `${SONG}.index.json`);
  const csvFile = join(TMP, `${SONG}.csv`);
  writeFileSync(idxFile, JSON.stringify({
    manifest: { sourceType: 'digital' },
    albums: [{ id: 'alb_x', artist: ARTIST, name: ALBUM, trackList: [SONG] }],
    songs: [{ id: SONG, albumId: 'alb_x', artist: ARTIST, name: TITLE }],
  }));
  writeFileSync(csvFile, `Song ID\n${SONG}\n`);

  const outBase = join(TMP, `out-${SONG}`);
  mkdirSync(outBase, { recursive: true });

  // real-time capture via the rip skill (drives Audio Hijack + Music)
  status('ripping', { realtime: true, ripStartedAt: Date.now(), totalMs: LENGTH_MS, message: 'recording from Apple Music' });
  await new Promise((res, rej) => {
    const p = spawn('node', [
      join(REPO, '.claude/skills/rip/rip.mjs'),
      '--setlist', csvFile, '--index', idxFile, '--library-xml', LIBRARY_XML,
      '--out-base', outBase, '--limit', '1',
    ], { cwd: REPO });
    let err = '';
    p.stderr.on('data', (d) => { err += d; });
    p.stdout.on('data', (d) => process.stderr.write(d)); // surface rip log to our stderr
    p.on('close', (code) => (code === 0 ? res() : rej(new Error('rip skill failed: ' + err.slice(-300)))));
  }).catch((e) => fail(e.message));

  // find the captured audio file in the newest *_ripped folder
  let ripped = null;
  try {
    const dirs = readdirSync(outBase).map((d) => join(outBase, d)).filter((d) => statSync(d).isDirectory() && d.endsWith('_ripped'));
    dirs.sort((x, y) => statSync(y).mtimeMs - statSync(x).mtimeMs);
    const files = dirs.length ? readdirSync(dirs[0]).filter((f) => /\.(m4a|aac|aiff|wav|mp3|caf|alac)$/i.test(f)) : [];
    if (files.length) ripped = join(dirs[0], files.sort()[0]);
  } catch { /* ignore */ }
  if (!ripped) fail('no audio captured — is the track in the library and audio routed to system output?');

  // transcode to mp3 256 and upload
  status('uploading', { message: 'transcoding + uploading' });
  const mp3 = join(TMP, `${SONG}.mp3`);
  try {
    execFileSync('ffmpeg', ['-y', '-i', ripped, '-map', '0:a:0', '-codec:a', 'libmp3lame', '-b:a', '256k', mp3], { stdio: 'ignore' });
  } catch (e) { fail('ffmpeg transcode failed: ' + e.message); }
  const key = `rips/${SONG}.mp3`;
  try {
    execFileSync('aws', ['s3', 'cp', mp3, `s3://${BUCKET}/${key}`, '--content-type', 'audio/mpeg', '--profile', PROFILE, '--region', REGION], { stdio: 'ignore' });
  } catch (e) { fail('s3 upload failed: ' + e.message); }
  const bytes = statSync(mp3).size;

  status('uploaded', { message: 'done', key, bytes });
  console.log('RESULT ' + JSON.stringify({ ok: true, key, bytes, durationMs: LENGTH_MS }));
}
main().catch((e) => fail(e.message));
