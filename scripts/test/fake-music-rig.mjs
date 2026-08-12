#!/usr/bin/env node
// A fake Music.app + Audio Hijack rig: stands in for BOTH `osascript` and `shortcuts` on PATH
// so the rip skill can be driven end-to-end without touching the real GUI. (The rip daemon is
// live and owns the real Music.app + Audio Hijack — a test that drove them would collide with a
// capture in progress.)
//
// Dispatch is by argv[0]-ish shape: `-e <script>` = osascript, `list`/`run` = shortcuts.
//
// env:
//   PDJ_FAKE_MODE=wedged   `play` is ACCEPTED and `duration of t` answers, but player state is
//                          pinned at "stopped|missing value" forever — the 2026-08-12 incident.
//   PDJ_FAKE_MODE=healthy  the player reaches `playing` and its position advances.
//   PDJ_FAKE_MODE=wedged-then-healthy   wedged until PDJ_FAKE_HEAL_FLAG exists (written when
//                          Music is "relaunched"), healthy after — i.e. the restart fixes it.
//   PDJ_FAKE_LOG           file every invocation is appended to (the test asserts the shim was
//                          REALLY used — if PATH interception ever failed, the test must fail
//                          rather than silently drive the user's Music.app).
//   PDJ_FAKE_AH_DIR        recordings dir; "Rip Start" drops a file here unless PDJ_FAKE_AH_DEAD.
//   PDJ_FAKE_AH_DEAD=1     the Audio Hijack shortcut exits 0 but records nothing (the innocent
//                          twin of the wedge: identical symptom, opposite cause).
//   PDJ_FAKE_LAUNCH_DELAY_MS   how long `launch` blocks before Music is back. The real relaunch
//                          takes SECONDS, and a caller that runs it synchronously is off the air
//                          for all of them — so a fake that returns instantly cannot expose the
//                          bug. Blocking here (in this child process) is the point.
import { appendFileSync, writeFileSync, existsSync, readFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const MODE = process.env.PDJ_FAKE_MODE || 'wedged';
const LOG = process.env.PDJ_FAKE_LOG || '';
const AH_DIR = process.env.PDJ_FAKE_AH_DIR || '';
const HEAL_FLAG = process.env.PDJ_FAKE_HEAL_FLAG || '';
const LAUNCH_DELAY_MS = parseInt(process.env.PDJ_FAKE_LAUNCH_DELAY_MS || '0', 10);
const COUNTER = process.env.PDJ_FAKE_COUNTER || join(process.env.TMPDIR || '/tmp', 'pdj-fake-counter');
// The single track this fake library contains (drives the live-search fallback's NONE answer).
const TITLE = process.env.PDJ_FAKE_TITLE || 'Fake Song';
const ARTIST = process.env.PDJ_FAKE_ARTIST || 'Fake Artist';

const note = (kind, detail) => { if (LOG) { try { appendFileSync(LOG, `${kind}\t${String(detail).replace(/\s+/g, ' ').slice(0, 300)}\n`); } catch { /* ignore */ } } };
const bump = () => { let n = 0; try { n = parseInt(readFileSync(COUNTER, 'utf8'), 10) || 0; } catch { /* first */ } writeFileSync(COUNTER, String(n + 1)); return n; };
const healed = () => !!(HEAL_FLAG && existsSync(HEAL_FLAG));
const playing = () => MODE === 'healthy' || (MODE === 'wedged-then-healthy' && healed());

if (argv[0] === '-e') {                          // ---- osascript ----
  const script = argv[1] || '';
  note('osascript', script);
  if (/is running/.test(script)) { console.log(healed() ? 'yes' : 'no'); process.exit(0); }
  if (/to quit/.test(script)) { note('music-quit', ''); process.exit(0); }
  if (/to launch/.test(script)) {                // the relaunch is what "fixes" the wedge
    note('music-launch', '');
    // Note FIRST, then block: a watcher tailing the log can tell exactly when the relaunch is
    // in flight, which is the window the blast-radius tests measure the server's health in.
    if (LAUNCH_DELAY_MS > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, LAUNCH_DELAY_MS);
    if (HEAL_FLAG) writeFileSync(HEAL_FLAG, '1');
    process.exit(0);
  }
  if (/library playlist 1/.test(script) && /name of/.test(script)) { console.log('Library'); process.exit(0); }
  if (/player state/.test(script)) {
    // THE POINT: a wedged Music answers this — with "stopped" and a `missing value` position —
    // forever, while accepting every play command without error.
    if (!playing()) { console.log('stopped|missing value'); process.exit(0); }
    console.log(`playing|${(bump() * 0.5).toFixed(1)}`);
    process.exit(0);
  }
  // The live-search fallback (`every track … whose name contains …`). The fake library holds
  // exactly one track; anything else answers NONE, like the real one.
  if (/every track/.test(script)) {
    const hit = script.includes(JSON.stringify(TITLE)) && script.includes(JSON.stringify(ARTIST));
    if (!hit) { note('search-none', ''); console.log('NONE'); process.exit(0); }
    note('play-accepted', 'search');
    console.log('180');
    process.exit(0);
  }
  if (/\bplay t\b|\bplay\b/.test(script) && /library playlist 1/.test(script)) {
    note('play-accepted', '');                   // accepted without error in BOTH modes…
    console.log('180');                          // …and duration answers from METADATA regardless
    process.exit(0);
  }
  console.log('');
  process.exit(0);
}

// ---- shortcuts ----
note('shortcuts', argv.join(' '));
if (argv[0] === 'list') { console.log('Rip Start\nRip Stop'); process.exit(0); }
if (argv[0] === 'run') {
  const name = argv[1] || '';
  // Exits 0 whether or not anything is actually recorded — exactly like the real thing.
  if (/start/i.test(name) && AH_DIR && !process.env.PDJ_FAKE_AH_DEAD) {
    mkdirSync(AH_DIR, { recursive: true });
    writeFileSync(join(AH_DIR, `Application Audio-${Date.now()}.mp3`), 'fake-audio');
  }
  process.exit(0);
}
process.exit(0);
