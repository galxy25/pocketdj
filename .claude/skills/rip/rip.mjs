#!/usr/bin/env node
// rip — record a PocketDJ setlist out of Apple Music by playing each song in Music.app
// and capturing its output with Audio Hijack, one audio file per song.
//
// Flow per setlist row:
//   1. Resolve the row's PocketDJ Song ID -> canonical artist/title (via the index).
//   2. Find the matching Apple Music track via the exported library XML -> Persistent ID.
//      (fallback: drive a search in Music with AppleScript `whose name/artist contains`.)
//   3. Start the Audio Hijack recording session, `play` the track in Music (AppleScript),
//      wait for it to finish, stop the session, and move the produced recording into the
//      output folder as "NN - Artist - Title.<ext>".
//
// Output folder: "<unixSeconds>_<setlist name>_ripped" under --out-base (default: cwd).
//
// Permissions (Automation only — NOT Accessibility):
//   • Music         — already granted (play/query).
//   • Audio Hijack  — new Automation prompt the first time (approve it).
// The AppleScript `play` path needs no Accessibility. The optional UI-automation fallback
// WOULD need Accessibility; this script never does that silently — it stops and tells you.
//
// Prerequisites:
//   • Library XML exported by scripts/dump-apple-music-library.mjs.
//   • An Audio Hijack session whose source is the Music app + a Recorder block. Pass its
//     name with --ah-session (run `node rip.mjs --probe` once to list session names).
//
// Usage:
//   node .claude/skills/rip/rip.mjs --setlist "<csv>" --ah-session "<name>" [options]
//   node .claude/skills/rip/rip.mjs --probe                 # list Audio Hijack sessions
//   node .claude/skills/rip/rip.mjs --setlist "<csv>" --dry-run   # resolve matches only
//   --require-explicitness clean|explicit   # variant rips: the library match must carry
//       that Explicit flag; absent edition ⇒ the track FAILS (never --search-fallback'd)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { loadLibraryXML, loadLibraryTSV, indexLibrary, findInLibrary } from '../../../scripts/lib/am-match.mjs';
import { waitUntilPlaying, parsePlayerProbe, PROBE_SCRIPT } from '../../../scripts/lib/music-health.mjs';

// ---------------- args ----------------
function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]; if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    if (['dry-run', 'probe', 'search-fallback'].includes(key)) { out[key] = true; continue; }
    out[key] = argv[++i];
  }
  return out;
}
const args = parseArgs(process.argv.slice(2));
const die = (m) => { console.error(`\n✗ ${m}\n`); process.exit(1); };

const HOME = os.homedir();
const SETLIST = args.setlist;
const INDEX = args.index || 'public/current-index.json';
const LIB_XML = args['library-xml'] || 'index-out/apple-music-library.xml';
const LIB_TSV = args['library-tsv'] || 'index-out/apple-music-library.tsv';
const OUT_BASE = args['out-base'] || process.cwd();
const AH_SESSION = args['ah-session'] || 'Application Audio';
const AH_START_SHORTCUT = args['ah-start-shortcut'] || 'Rip Start';
const AH_STOP_SHORTCUT = args['ah-stop-shortcut'] || 'Rip Stop';
const AH_REC_DIR = args['ah-recordings-dir'] || path.join(HOME, 'Music', 'Audio Hijack');
const SETTLE_MS = parseInt(args['settle-ms'] || '1500', 10); // pause between start-rec and play / after stop
// Include tracks absent from the STATIC library export and play them via a LIVE Music.app
// search instead. Used by ad-hoc / freshly-added rips (e.g. recognizer add-to-library), where
// the song reaches the live library via iCloud sync but isn't in the frozen XML yet.
const SEARCH_FALLBACK = !!args['search-fallback'];
// Require a specific EDITION ('clean' | 'explicit') of every track — variant rips
// ("<songId>_clean|_explicit" keys). The library match must carry the matching Explicit
// flag; when the required edition is absent the track FAILS (it is NEVER rescued by
// --search-fallback): a variant key must never hold wrong-edition audio.
const REQUIRE_EXPL = args['require-explicitness'] === 'clean' || args['require-explicitness'] === 'explicit'
  ? args['require-explicitness'] : null;
const TAIL_MS = parseInt(args['tail-ms'] || '1200', 10);     // record a moment past track end
// How long to wait for Music to actually REACH state=playing after `play` is accepted. A healthy
// player starts in well under a second; anything past a few seconds is a wedged playback engine
// (2026-08-12), not a slow one. Kept short so a wedge fails in ~20s instead of burning a whole
// song length before reporting a file that never existed.
const PLAY_START_TIMEOUT_MS = parseInt(args['play-start-timeout-ms'] || '20000', 10);
// How long after playback is CONFIRMED to wait for Audio Hijack's recording file to appear.
// AH creates the file when the session starts recording (which happened before `play`), so this
// only has to cover filesystem latency. 0 disables the check.
const AH_FILE_TIMEOUT_MS = parseInt(args['ah-file-timeout-ms'] || '15000', 10);
const MAX_SECONDS = args['max-seconds'] ? parseInt(args['max-seconds'], 10) : 0; // cap per-song record (0 = full track; for quick test samples)
const LIMIT = args.limit ? parseInt(args.limit, 10) : Infinity;
const DRY = !!args['dry-run'];

// ---------------- AppleScript helper ----------------
function osa(script, timeoutMs = 60000) {
  const r = spawnSync('osascript', ['-e', script], { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 32 * 1024 * 1024 });
  return { ok: !r.error && r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || r.error?.message || '').trim() };
}

// ---------------- Audio Hijack control (via macOS Shortcuts) ----------------
// External `.ahcommand` files CANNOT control sessions — AH only exposes session control
// (event.session / app.sessions) to in-app Script-Library scripts. The supported external
// path is a macOS Shortcut using AH's "Run/Stop Session" action, triggered with the
// `shortcuts` CLI. Create two shortcuts (see SKILL.md / --probe):
//   • <start>: Run/Stop Session = Run,  Session = "Application Audio"
//   • <stop>:  Run/Stop Session = Stop, Session = "Application Audio"
// AH records to its Recorder's configured folder (--ah-recordings-dir); we move + tag the
// newest file into the output folder afterwards.
function runShortcut(name) {
  const r = spawnSync('shortcuts', ['run', name], { encoding: 'utf8', timeout: 25000 });
  return { ok: !r.error && r.status === 0, err: (r.stderr || r.error?.message || '').trim() };
}
function shortcutExists(name) {
  const list = (spawnSync('shortcuts', ['list'], { encoding: 'utf8' }).stdout || '').split('\n').map(s => s.trim());
  return list.includes(name);
}
const AH = {
  start: () => runShortcut(AH_START_SHORTCUT),
  stop: () => runShortcut(AH_STOP_SHORTCUT),
};

// ---------------- CSV ----------------
function parseCSV(text) {
  const rows = []; let row = [], field = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; } else field += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (c === '\r') { /* skip */ }
    else field += c;
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  return rows.filter(r => r.length > 1 || (r.length === 1 && r[0] !== ''));
}

// ---------------- normalization / matching · library load / indexing ----------------
// (stripD/normTitle/normArtist/subsetEither/unesc/loadLibraryXML/loadLibraryTSV/
//  indexLibrary/findInLibrary now live in scripts/lib/am-match.mjs — the single matcher
//  shared with the rip server's cloud-rip accept-time probe.)

// ---------------- fs-safe ----------------
const safeName = (s) => String(s).replace(/[\/\\:*?"<>|]/g, '-').replace(/[\x00-\x1f]/g, '').replace(/\s+/g, ' ').replace(/\.+$/, '').trim().slice(0, 120);

// ---------------- probe mode (verify the Shortcuts + recordings dir are ready) ----------------
if (args.probe) {
  const startOk = shortcutExists(AH_START_SHORTCUT);
  const stopOk = shortcutExists(AH_STOP_SHORTCUT);
  console.log('rip controls Audio Hijack through macOS Shortcuts (shortcuts run).\n');
  console.log(`  start shortcut  "${AH_START_SHORTCUT}":  ${startOk ? '✓ found' : '✗ MISSING'}`);
  console.log(`  stop shortcut   "${AH_STOP_SHORTCUT}":  ${stopOk ? '✓ found' : '✗ MISSING'}`);
  console.log(`  recordings dir  ${AH_REC_DIR}:  ${fs.existsSync(AH_REC_DIR) ? '✓ ok' : '✗ MISSING'}`);
  if (!startOk || !stopOk) {
    console.log('\nCreate them in the Shortcuts app (one-time):');
    console.log(`  1. New Shortcut named "${AH_START_SHORTCUT}" → add Audio Hijack action "Run/Stop Session"`);
    console.log(`     → set to Run,  Session = "${AH_SESSION}".`);
    console.log(`  2. New Shortcut named "${AH_STOP_SHORTCUT}"  → "Run/Stop Session" → Stop, Session = "${AH_SESSION}".`);
    console.log('  (Override names with --ah-start-shortcut / --ah-stop-shortcut.)');
  } else {
    console.log('\nReady. Do a test rip:  --setlist "<csv>" --limit 2');
  }
  process.exit(0);
}

// ---------------- main ----------------
if (!SETLIST) die('Missing --setlist <csv>. (Or use --probe to list Audio Hijack sessions.)');
if (!fs.existsSync(SETLIST)) die(`Setlist CSV not found: ${SETLIST}`);

// library
let libEntries = null, libSource = '';
if (fs.existsSync(LIB_XML)) { libEntries = loadLibraryXML(LIB_XML); libSource = LIB_XML; }
else if (fs.existsSync(LIB_TSV)) { libEntries = loadLibraryTSV(LIB_TSV); libSource = LIB_TSV; }
else die(`No Apple Music library export found (${LIB_XML} or ${LIB_TSV}).\n   Run: node scripts/dump-apple-music-library.mjs  (the full first run takes a while).`);
const lib = indexLibrary(libEntries);

// index + setlist
const idx = fs.existsSync(INDEX) ? JSON.parse(fs.readFileSync(INDEX, 'utf8')) : { songs: [] };
const songById = new Map((idx.songs || []).map(s => [s.id, s]));
const rows = parseCSV(fs.readFileSync(SETLIST, 'utf8'));
if (!rows.length) die('Setlist CSV is empty.');
const header = rows[0].map(h => h.trim());
const col = (n) => header.findIndex(h => h.toLowerCase() === n.toLowerCase());
const cId = col('Song ID'); if (cId < 0) die('Setlist has no "Song ID" column.');
const cArtist = col('Artist'), cTitle = col('Title'), cNum = col('#');

// backfill map (songId -> resolved catalog artist/title) bridges the renamed-title gap:
// songs added to the library under a catalog title that differs from the setlist title.
const BACKFILL = args.backfill || (path.basename(SETLIST).replace(/\.[^.]+$/, '') + ' - backfill.json');
const backfillById = new Map();
if (fs.existsSync(BACKFILL)) {
  for (const b of JSON.parse(fs.readFileSync(BACKFILL, 'utf8'))) {
    if (b.songId && b.status === 'found' && b.confidence !== 'poor' && b.catalogTitle)
      backfillById.set(b.songId, { artist: b.catalogArtist, title: b.catalogTitle });
  }
}

const data = rows.slice(1).slice(0, LIMIT);
const pad = String(data.length).length;
const plan = [];
data.forEach((r, i) => {
  const songId = (r[cId] || '').trim();
  const song = songById.get(songId);
  const artist = song?.artist || (cArtist >= 0 ? r[cArtist] : '');
  const title = song?.name || (cTitle >= 0 ? r[cTitle] : '');
  const pos = cNum >= 0 ? (r[cNum] || '').trim() : String(i + 1);
  let { hit, match } = findInLibrary(lib, artist, title, { explicitness: REQUIRE_EXPL });
  if (match === 'none' && backfillById.has(songId)) {        // fallback to the resolved catalog title
    const bf = backfillById.get(songId);
    const r2 = findInLibrary(lib, bf.artist, bf.title, { explicitness: REQUIRE_EXPL });
    if (r2.match !== 'none') { hit = r2.hit; match = 'backfill'; }
  }
  plan.push({ pos, order: String(pos).padStart(pad, '0'), artist, title, songId, hit, match,
    base: safeName(`${String(pos).padStart(pad, '0')} - ${artist} - ${title}`) });
});

// With --search-fallback, keep not-in-static-XML tracks in the plan and play them via a
// live Music.app search (their p.hit is null → ripOne goes straight to searchAndPlay).
// EXCEPT under --require-explicitness: a track whose required edition isn't verifiably in
// the library must NOT be live-search captured — the search can't guarantee the edition,
// and a variant key holding wrong-edition audio is data corruption. Those tracks skip
// (the caller reports no-matching-edition).
const inLib = plan.filter(p => p.match !== 'none' || (SEARCH_FALLBACK && !REQUIRE_EXPL));
const skipped = plan.filter(p => p.match === 'none' && !(SEARCH_FALLBACK && !REQUIRE_EXPL));

// output folder: <unixSeconds>_<setlist name>_ripped
const setName = safeName(path.basename(SETLIST).replace(/\.[^.]+$/, '')) || 'setlist';
const OUT_DIR = path.join(OUT_BASE, `${Math.floor(Date.now() / 1000)}_${setName}_ripped`);

console.log(`\nrip "${setName}"`);
console.log(`  library: ${lib.count} tracks (${path.basename(libSource)})`);
console.log(`  setlist: ${data.length} songs → in library: ${inLib.length}, not found: ${skipped.length}  [scope: library matches only]`);
if (skipped.length) { console.log('  not found (skipped):'); for (const p of skipped) console.log(`     - ${p.pos}. ${p.artist} — ${p.title}`); }

if (DRY) {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(path.join(OUT_DIR, 'rip-manifest.json'), JSON.stringify({
    setlist: setName, createdAt: new Date().toISOString(), dryRun: true, scope: 'library-only',
    library: libSource, total: data.length, toRip: inLib.length,
    tracks: plan.map(p => ({ pos: p.pos, artist: p.artist, title: p.title, songId: p.songId, match: p.match, persistentID: p.hit?.persistentID || null, libraryTitle: p.hit?.title || null })),
  }, null, 2));
  console.log(`\n[DRY RUN] planned ${inLib.length} rips → ${OUT_DIR}\n  (no Music/Audio Hijack control performed)\n`);
  process.exit(0);
}

// ---- live run requires the Audio Hijack control Shortcuts ----
if (!shortcutExists(AH_START_SHORTCUT) || !shortcutExists(AH_STOP_SHORTCUT)) {
  die(`Missing Audio Hijack control shortcut(s): "${AH_START_SHORTCUT}" / "${AH_STOP_SHORTCUT}".\n   Run --probe for one-time setup steps.`);
}
if (!fs.existsSync(AH_REC_DIR)) die(`Audio Hijack recordings dir not found: ${AH_REC_DIR}\n   Pass --ah-recordings-dir to point at the session's Recorder output folder.`);
const HAS_FFMPEG = !spawnSync('ffmpeg', ['-version']).error;

fs.mkdirSync(OUT_DIR, { recursive: true });
console.log(`\nLive rip → ${OUT_DIR}\n  AH session "${AH_SESSION}" via shortcuts: start="${AH_START_SHORTCUT}" stop="${AH_STOP_SHORTCUT}"\n  recordings dir: ${AH_REC_DIR}${HAS_FFMPEG ? '' : '   (ffmpeg not found — files moved without tagging)'}\n`);

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const newestFileSince = (dir, sinceMs) => {
  const files = fs.readdirSync(dir)
    .filter(f => !f.startsWith('.'))
    .map(f => ({ f, p: path.join(dir, f) }))
    .map(x => ({ ...x, st: fs.statSync(x.p) }))
    .filter(x => x.st.isFile() && x.st.mtimeMs >= sinceMs - 2000)
    .sort((a, b) => b.st.mtimeMs - a.st.mtimeMs);
  return files[0]?.p || null;
};

// play a track by Persistent ID; returns {ok, durationSec}
function playByPersistentID(pid) {
  const s = `tell application "Music"
  set t to first track of library playlist 1 whose persistent ID is ${JSON.stringify(pid)}
  set dur to (duration of t)
  play t
  return dur as text
end tell`;
  const r = osa(s, 30000);
  return { ok: r.ok, durationSec: parseFloat(r.out) || 0, err: r.err };
}
function searchAndPlay(artist, title) {
  const s = `tell application "Music"
  set matches to (every track of library playlist 1 whose name contains ${JSON.stringify(title)} and artist contains ${JSON.stringify(artist)})
  if (count of matches) is 0 then return "NONE"
  set t to item 1 of matches
  set dur to (duration of t)
  play t
  return dur as text
end tell`;
  const r = osa(s, 30000);
  if (r.out === 'NONE') return { ok: false, durationSec: 0, err: 'no search match' };
  return { ok: r.ok, durationSec: parseFloat(r.out) || 0, err: r.err };
}
const playerState = () => osa(PROBE_SCRIPT, 15000).out;
const pauseMusic = () => osa('tell application "Music" to pause', 15000);
// A new file in the AH recordings dir that wasn't there when this capture began.
const newAhFile = (before) => fs.readdirSync(AH_REC_DIR).find((f) => !before.has(f) && !f.startsWith('.')) || null;

// move + tag the AH recording into OUT_DIR as base.ext (ffmpeg copy adds tags; else rename)
function finalize(srcPath, base, tags) {
  const ext = path.extname(srcPath) || '.mp3';
  const dest = path.join(OUT_DIR, `${base}${ext}`);
  if (HAS_FFMPEG) {
    const md = [];
    for (const [k, v] of Object.entries(tags)) if (v) md.push('-metadata', `${k}=${v}`);
    const r = spawnSync('ffmpeg', ['-y', '-hide_banner', '-loglevel', 'error', '-i', srcPath, '-map', '0:a:0', '-c', 'copy', ...md, dest]);
    if (!r.error && r.status === 0) { try { fs.rmSync(srcPath); } catch { } return dest; }
  }
  fs.renameSync(srcPath, dest);
  return dest;
}

async function ripOne(p) {
  const startMs = Date.now();
  const before = new Set(fs.readdirSync(AH_REC_DIR));
  const tags = { artist: p.artist, title: p.title, album: p.hit?.album || '', track: String(p.pos), comment: `PocketDJ rip · ${p.songId}` };
  // 1) start recording (AH records to its Recorder folder)
  let r = AH.start();
  if (!r.ok) return { ...p, status: 'ah-start-failed', err: r.err };
  await sleep(SETTLE_MS);
  // 2) play — by Persistent ID when the track is in the static export, else (ad-hoc /
  // freshly-added, p.hit === null) straight to a live Music.app search.
  let pr = p.hit?.persistentID
    ? playByPersistentID(p.hit.persistentID)
    : { ok: false, durationSec: 0, err: 'not in static library export — trying live search' };
  if (!pr.ok || pr.durationSec === 0) {
    const alt = searchAndPlay(p.artist, p.title); // fallback: drive search
    if (alt.ok && alt.durationSec > 0) pr = alt;
    else { AH.stop(); return { ...p, status: 'play-failed', err: pr.err || 'could not play (UI-automation fallback would need Accessibility — not attempted)' }; }
  }
  // 2b) PLAYBACK HEALTH — the check whose absence cost 38 hours on 2026-08-12.
  // `play t` above was ACCEPTED and `duration of t` answered with a real number, yet the
  // player never left state=stopped: Music's playback engine had wedged. Metadata proves
  // nothing about playback, so REQUIRE the player to demonstrably reach state=playing
  // before we believe a capture is happening. Failing here reports the wedge by name in
  // ~20s instead of recording silence for a whole song and then blaming the missing file.
  const health = await waitUntilPlaying({ osa, sleep, now: Date.now, timeoutMs: PLAY_START_TIMEOUT_MS, pollMs: 500 });
  if (!health.started) {
    AH.stop();
    pauseMusic();
    return { ...p, status: 'play-not-started', durationSec: pr.durationSec,
      err: `play accepted but Music never reached state=playing within ${PLAY_START_TIMEOUT_MS}ms `
        + `(last state=${health.lastState}, position=${health.lastPosition == null ? 'missing value' : health.lastPosition}, `
        + `${health.samples} probes) — playback engine wedged; restart Music.app` };
  }
  // 2c) …and the mirror-image failure: playback is real but Audio Hijack never armed (the
  // shortcut exits 0 whether or not the session actually records). Same symptom as the wedge
  // — no file — opposite cause, so it gets its own name rather than the shared 'no-recording'.
  if (AH_FILE_TIMEOUT_MS > 0) {
    const tAh = Date.now();
    while (!newAhFile(before) && Date.now() - tAh < AH_FILE_TIMEOUT_MS) await sleep(500);
    if (!newAhFile(before)) {
      AH.stop();
      pauseMusic();
      return { ...p, status: 'ah-not-recording', durationSec: pr.durationSec,
        err: `Music is playing but Audio Hijack wrote no file within ${AH_FILE_TIMEOUT_MS}ms of playback `
          + `(shortcut "${AH_START_SHORTCUT}" exited 0) — is the session running and its recorder pointed at ${AH_REC_DIR}?` };
    }
  }
  // 3) wait for the track to finish (cap = duration + tail + slack, or --max-seconds for samples)
  let capMs = pr.durationSec * 1000 + TAIL_MS + 8000;
  if (MAX_SECONDS) capMs = Math.min(capMs, MAX_SECONDS * 1000);
  const t0 = Date.now();
  let sawPlaying = health.started; // proven above — a non-playing probe from here IS an ending
  while (Date.now() - t0 < capMs) {
    await sleep(2000);
    if (MAX_SECONDS && Date.now() - t0 >= MAX_SECONDS * 1000) break;
    const probe = parsePlayerProbe(playerState()); // position is null (not 0!) when absent
    if (probe.state === 'playing') sawPlaying = true;
    // "not playing" means ENDED only because we PROVED it started. Without that proof this
    // break is also how "never started" exits after one 2s tick, silently, as if it had
    // finished — the exact ambiguity that hid the wedge.
    else if (sawPlaying) break;                                  // stopped/paused = ended
    else continue;                                               // never started: keep watching
    if (pr.durationSec && probe.position != null && probe.position >= pr.durationSec - 0.4) break; // reached end
  }
  await sleep(TAIL_MS);
  // 4) stop recording + pause Music
  AH.stop();
  pauseMusic();
  await sleep(SETTLE_MS + 1200); // let AH finalize/flush the file
  // 5) find the file AH just produced and move + tag it into OUT_DIR
  let src = fs.readdirSync(AH_REC_DIR).filter(f => !before.has(f) && !f.startsWith('.'))
    .map(f => path.join(AH_REC_DIR, f)).sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0]
    || newestFileSince(AH_REC_DIR, startMs);
  if (!src) return { ...p, status: 'no-recording', durationSec: pr.durationSec, err: 'no new file in recordings dir (check the shortcut runs the session + recorder folder)' };
  const dest = finalize(src, p.base, tags);
  return { ...p, status: 'ok', durationSec: pr.durationSec, file: path.basename(dest) };
}

const results = [];
for (let i = 0; i < inLib.length; i++) {
  const p = inLib[i];
  process.stdout.write(`  [${i + 1}/${inLib.length}] ${p.artist} — ${p.title} … `);
  const res = await ripOne(p);
  results.push(res);
  console.log(res.status === 'ok' ? `ok (${res.file})` : `${res.status}${res.err ? ' — ' + res.err : ''}`);
}

fs.writeFileSync(path.join(OUT_DIR, 'rip-manifest.json'), JSON.stringify({
  setlist: setName, createdAt: new Date().toISOString(), scope: 'library-only', capture: 'audio-hijack', perSong: 'full-track',
  library: libSource, ahSession: AH_SESSION,
  total: data.length, attempted: inLib.length,
  ripped: results.filter(r => r.status === 'ok').length,
  skippedNotInLibrary: skipped.map(p => `${p.artist} — ${p.title}`),
  tracks: results.map(r => ({ pos: r.pos, artist: r.artist, title: r.title, songId: r.songId, match: r.match, persistentID: r.hit?.persistentID || null, status: r.status, file: r.file || null, durationSec: r.durationSec || null, err: r.err || null })),
}, null, 2));

const okN = results.filter(r => r.status === 'ok').length;
console.log(`\nDone: ${okN}/${inLib.length} ripped → ${OUT_DIR}`);
if (okN < inLib.length) console.log(`  ${inLib.length - okN} had issues (see rip-manifest.json).`);
// EXIT CODE: capturing NOTHING is a failure, and for 38 hours this process reported it by
// exiting 0 — so its caller concluded "the rip skill succeeded" and re-derived a generic
// "no audio captured" verdict, throwing away the precise per-track diagnosis it had just
// written. Partial success still exits 0 (a multi-track setlist that ripped most rows is a
// usable result); zero-out-of-N is not. The manifest above is already on disk, so a caller
// that wants the REASON reads rip-manifest.json rather than guessing from this code.
if (inLib.length > 0 && okN === 0) process.exit(1);
