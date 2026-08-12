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
import { readdirSync, statSync, writeFileSync, mkdirSync, existsSync, readFileSync, rmSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const a = {};
for (let i = 2; i < process.argv.length; i++) { const k = process.argv[i]; if (k.startsWith('--')) a[k.slice(2)] = process.argv[++i]; }
const SONG = a['song-id'], ARTIST = a.artist || '', TITLE = a.title || '', ALBUM = a.album || '';
const LENGTH_MS = parseInt(a['length-ms'] || '0', 10) || null;
// Variant rip: require a specific EDITION ('clean' | 'explicit'). Threaded through to the
// rip skill as --require-explicitness, which disables its live-search fallback for the
// track — a variant key must never hold wrong-edition audio.
const EXPL = a.explicitness === 'clean' || a.explicitness === 'explicit' ? a.explicitness : null;
const LIBRARY_XML = (a['library-xml'] || join(homedir(), 'Downloads', 'Library.xml')).replace(/^~/, homedir());
const BUCKET = a.bucket || 'pocketdj-rips-011183829623';
const REGION = a.region || 'us-west-2';
const PROFILE = a.profile || 'levi';
const STATUS = a.status;
const TMP = (a.tmp || join(homedir(), '.pocketdj', 'rips')).replace(/^~/, homedir());
const AH_REC_DIR = (a['ah-recordings-dir'] || join(homedir(), 'Music', 'Audio Hijack')).replace(/^~/, homedir());
const PREROLL = parseInt(process.env.RIP_STREAM_PREROLL_BYTES || '65536', 10); // bytes before live play (the rip server tails this file)
if (!SONG) { console.error('--song-id required'); process.exit(2); }
// Optional per-knob timing overrides passed through to the rip skill (tests only).
const RIP_TEST_TIMINGS = [
  ['RIP_TEST_SETTLE_MS', '--settle-ms'], ['RIP_TEST_TAIL_MS', '--tail-ms'],
  ['RIP_TEST_PLAY_START_MS', '--play-start-timeout-ms'], ['RIP_TEST_AH_FILE_MS', '--ah-file-timeout-ms'],
  ['RIP_TEST_MAX_SECONDS', '--max-seconds'],
].flatMap(([env, flag]) => (process.env[env] ? [flag, process.env[env]] : []));
mkdirSync(TMP, { recursive: true });

function status(phase, extra = {}) {
  if (!STATUS) return;
  try {
    const prev = existsSync(STATUS) ? JSON.parse(readFileSync(STATUS, 'utf8')) : {};
    writeFileSync(STATUS, JSON.stringify({ ...prev, songId: SONG, phase, ...extra, updatedAt: Date.now() }));
  } catch { /* ignore */ }
}
// reason: 'no-match' (track absent from the library → no audio captured) vs 'system'
// (rip skill / ffmpeg / aws failed). The rip server falls back to analog for BOTH on a
// preferCloud analog job, but logs a WARN for 'system' so a broken capture rig is visible.
const fail = (msg, reason) => { status('error', { error: msg, ...(reason ? { reason } : {}) }); console.log('RESULT ' + JSON.stringify({ ok: false, error: msg, ...(reason ? { reason } : {}) })); process.exit(1); };

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

  // Live HLS watcher: Audio Hijack writes a growing MP3 into AH_REC_DIR as it records.
  // Detect that new file, then `tail -f` it into ffmpeg to produce a live HLS playlist
  // (2s AAC segments, EVENT type) under <tmp>/live/<songId>/. iOS Safari plays HLS
  // natively (a plain progressive MP3 stream does not), so the rip server serves these
  // segments. We flip to `streaming` once the first segment lands.
  const before = new Set(existsSync(AH_REC_DIR) ? readdirSync(AH_REC_DIR) : []);
  const hlsDir = join(TMP, 'live', SONG);
  try { rmSync(hlsDir, { recursive: true, force: true }); } catch { /* ignore */ }
  mkdirSync(hlsDir, { recursive: true });
  let streamFile = null;
  let streamReady = false;
  let tailP = null;
  let ff = null;
  const startHls = (file) => {
    tailP = spawn('tail', ['-c', '+1', '-f', file]);
    ff = spawn('ffmpeg', [
      '-hide_banner', '-loglevel', 'error', '-i', 'pipe:0',
      '-c:a', 'aac', '-b:a', '128k', '-ar', '44100',
      '-hls_time', '2', '-hls_playlist_type', 'event', '-hls_flags', 'independent_segments',
      '-hls_segment_filename', join(hlsDir, 'seg_%05d.ts'), join(hlsDir, 'index.m3u8'),
    ]);
    tailP.stdout.pipe(ff.stdin);
    tailP.on('error', () => {}); ff.on('error', () => {});
    ff.stdin.on('error', () => {}); // EPIPE when ffmpeg exits first
    ff.stderr.on('data', (d) => process.stderr.write(d));
  };
  const stopHls = async () => {
    try { if (tailP && !tailP.killed) tailP.kill('SIGTERM'); } catch { /* ignore */ }
    if (ff) await new Promise((res) => {
      const to = setTimeout(() => { try { ff.kill('SIGKILL'); } catch { /* ignore */ } res(); }, 5000);
      ff.on('close', () => { clearTimeout(to); res(); }); // ffmpeg finalizes index.m3u8 (+ENDLIST) on stdin EOF
    });
  };
  const watch = setInterval(() => {
    try {
      if (!streamFile) {
        const fresh = readdirSync(AH_REC_DIR)
          .filter((f) => !before.has(f) && !f.startsWith('.') && /\.mp3$/i.test(f))
          .map((f) => join(AH_REC_DIR, f))
          .sort((x, y) => statSync(y).mtimeMs - statSync(x).mtimeMs);
        if (fresh.length) { streamFile = fresh[0]; status('ripping', { streamFile, message: 'capturing + segmenting' }); startHls(streamFile); }
      }
      if (streamFile && !streamReady && existsSync(join(hlsDir, 'seg_00000.ts'))) {
        streamReady = true;
        status('streaming', { streamFile, streamReady: true, hls: true, message: 'streaming live (hls)' });
      }
    } catch { /* dir/file not ready yet */ }
  }, 300);

  let ripExit = 0;
  let ripErr = '';
  await new Promise((res) => {
    const p = spawn('node', [
      join(REPO, '.claude/skills/rip/rip.mjs'),
      '--setlist', csvFile, '--index', idxFile, '--library-xml', LIBRARY_XML,
      '--out-base', outBase, '--limit', '1', '--ah-recordings-dir', AH_REC_DIR,
      // single-track digital capture: if the song isn't in the frozen library export yet
      // (freshly added on another device, still iCloud-syncing), play it via a live search.
      // (--require-explicitness overrides the fallback inside the skill: an edition-
      // constrained capture must never live-search-play an unverifiable edition.)
      '--search-fallback',
      ...(EXPL ? ['--require-explicitness', EXPL] : []),
      // Test seam (mirrors the rip server's RIP_TEST_* overrides): shrink the capture timings
      // so an e2e can drive the wedge/heal path in seconds against a fake rig. Unset in
      // production, where the skill's own safe defaults apply.
      ...RIP_TEST_TIMINGS,
    ], { cwd: REPO });
    p.stderr.on('data', (d) => { ripErr += d; });
    p.stdout.on('data', (d) => process.stderr.write(d)); // surface rip log to our stderr
    // A non-zero exit is NOT handled here any more. The rip skill writes a precise per-track
    // diagnosis (play-not-started / ah-not-recording / no-recording / play-failed) into
    // rip-manifest.json before it exits; rejecting on the exit code discarded that and
    // reported a generic 'system' failure instead. Read the manifest first, THEN decide.
    p.on('error', (e) => { ripErr += `spawn failed: ${e.message}\n`; });
    // null code = killed by a signal / never spawned → -1, NEVER 0: a signal death must not
    // read as a clean exit (that would demote a killed capture to a plain 'no-match').
    p.on('close', (code) => { ripExit = code == null ? -1 : code; res(); });
  });
  clearInterval(watch);
  await stopHls(); // capture done → stop tail so ffmpeg finalizes the HLS playlist

  // find the captured audio file — and the skill's own verdict — in the newest *_ripped folder
  let ripped = null;
  let ripTrack = null;
  try {
    const dirs = readdirSync(outBase).map((d) => join(outBase, d)).filter((d) => statSync(d).isDirectory() && d.endsWith('_ripped'));
    dirs.sort((x, y) => statSync(y).mtimeMs - statSync(x).mtimeMs);
    const files = dirs.length ? readdirSync(dirs[0]).filter((f) => /\.(m4a|aac|aiff|wav|mp3|caf|alac)$/i.test(f)) : [];
    if (files.length) ripped = join(dirs[0], files.sort()[0]);
    if (dirs.length) {
      const mf = JSON.parse(readFileSync(join(dirs[0], 'rip-manifest.json'), 'utf8'));
      ripTrack = (mf.tracks || [])[0] || null;
    }
  } catch { /* no manifest (skill crashed before writing one) — handled below */ }
  if (!ripped) {
    // Edition-required capture with nothing produced ⇒ the required edition isn't
    // (verifiably) in the library — a TERMINAL, expected outcome for a variant rip
    // (deliberately no automatic library-adds; see the rip-server variant docs).
    if (EXPL) fail(`required ${EXPL} edition not in the library — nothing captured`, 'no-matching-edition');
    // PROPAGATE THE SKILL'S DIAGNOSIS. 'play-not-started' is the wedged-Music.app signature
    // (2026-08-12): the rip server heals on exactly this reason, so collapsing it into the
    // generic 'no-match' below would leave the remedy unreachable — which is what it did for
    // 38 hours. 'ah-not-recording' is the opposite cause with the identical symptom.
    if (ripTrack?.status === 'play-not-started') fail(ripTrack.err || 'Music never started playing', 'play-not-started');
    if (ripTrack?.status === 'ah-not-recording') fail(ripTrack.err || 'Audio Hijack recorded nothing', 'ah-not-recording');
    // Skill died before it could judge anything (crash/spawn failure) → a rig problem.
    if (ripExit !== 0 && !ripTrack) fail('rip skill failed: ' + (ripErr.slice(-300) || `exit ${ripExit}`), 'system');
    fail('no audio captured — is the track in the library and audio routed to system output?', 'no-match');
  }

  // transcode to mp3 256 and upload
  status('uploading', { message: 'transcoding + uploading' });
  const mp3 = join(TMP, `${SONG}.mp3`);
  try {
    execFileSync('ffmpeg', ['-y', '-i', ripped, '-map', '0:a:0', '-codec:a', 'libmp3lame', '-b:a', '256k', mp3], { stdio: 'ignore' });
  } catch (e) { fail('ffmpeg transcode failed: ' + e.message, 'system'); }
  const key = `rips/${SONG}.mp3`;
  try {
    execFileSync('aws', ['s3', 'cp', mp3, `s3://${BUCKET}/${key}`, '--content-type', 'audio/mpeg', '--profile', PROFILE, '--region', REGION], { stdio: 'ignore' });
  } catch (e) { fail('s3 upload failed: ' + e.message, 'system'); }
  const bytes = statSync(mp3).size;

  status('uploaded', { message: 'done', key, bytes });
  console.log('RESULT ' + JSON.stringify({ ok: true, key, bytes, durationMs: LENGTH_MS }));
}
main().catch((e) => fail(e.message, 'system'));
