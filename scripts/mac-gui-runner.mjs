#!/usr/bin/env node
// PocketDJ — Mac GUI runner
//
// WHY THIS EXISTS
// ---------------
// Claude connects to this Mac over SSH. An SSH shell lives in a *Background*
// launchd session (`launchctl managername` → "Background") with no attachment to
// the logged-in user's window server. Consequences, all of them silent and all of
// them easy to misread as product bugs:
//
//   • `screencapture -x` → "could not create image from display"
//   • System Events reports 0 windows for every app
//   • macOS XCUITest dies at "Timed out while enabling automation mode"
//   • ioreg's CGSSessionScreenIsLocked reads true even when the user is sitting
//     at an unlocked desk — it describes a session this process cannot see
//
// `launchctl asuser 501 …` would bridge the gap but requires root, and sudo here
// wants a password. So the only way to drive macOS UI from an SSH-side agent is
// for a process that ALREADY lives in the GUI session to do the driving.
//
// That is this server. YOU (a human at the Mac) start it from Terminal.app, so it
// inherits the Aqua session and full window-server + TCC access. Claude then asks
// it to run things and reads the logs off the shared filesystem.
//
// USAGE (from Terminal.app ON the Mac — not over SSH):
//     node scripts/mac-gui-runner.mjs
//     # or: bash apple/scripts/mac-gui-runner-start.sh
//
// It speaks two protocols on 127.0.0.1:8791 (loopback only):
//   • MCP over HTTP at /mcp  — so Claude Code can use it as first-class tools
//   • a plain REST API       — /health, /run, /jobs/:id  for curl and scripts
//
// SAFETY: loopback bind only, and an ALLOWLIST — it will not run arbitrary shell.
// Every job is one of a fixed set of Xcode/test operations against this repo.

import { createServer } from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const APPLE = join(ROOT, 'apple');
const PORT = parseInt(process.env.PDJ_GUI_RUNNER_PORT || '8791', 10);
const LOG_DIR = process.env.PDJ_GUI_RUNNER_LOGS || join(ROOT, 'index-out', 'gui-runner');
mkdirSync(LOG_DIR, { recursive: true });

const jobs = new Map(); // id -> {id, kind, args, status, exitCode, log, started, ended}

// ---------------------------------------------------------------- session check
// What XCUITest actually needs is to be in the user's **Aqua** launchd session.
// `launchctl managername` reports that directly and needs no permissions:
//     Aqua        → GUI session. UI tests can run.
//     Background  → SSH / daemon context. UI tests CANNOT run, at all.
//
// Deliberately NOT using `screencapture` as the gate: it requires the Screen
// Recording TCC permission, which Terminal.app often lacks, so it fails in a
// perfectly good Aqua session. Conflating "no Screen Recording permission" with
// "no GUI session" is exactly the mistake this file exists to prevent — and it is
// a mistake this file made in its first version. Screenshot capability is reported
// separately as a nice-to-have, because XCUITest does not need it.
function run(cmd, args) {
  return new Promise((res) => {
    let out = '';
    const p = spawn(cmd, args);
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { out += d; });
    p.on('close', (code) => res({ code, out: out.trim() }));
    p.on('error', () => res({ code: -1, out: '' }));
  });
}

async function checkGuiAccess() {
  const mgr = await run('launchctl', ['managername']);
  const sessionType = mgr.out || 'unknown';
  const ok = /Aqua/i.test(sessionType);

  // Informational only — never gates anything.
  let screenshotBytes = 0;
  // The one-shot probe is flaky (a capture can transiently produce an empty file
  // even when permission is granted) — retry a few times before declaring blocked.
  for (let attempt = 0; attempt < 3 && screenshotBytes <= 1000; attempt++) {
    if (attempt > 0) await new Promise(r => setTimeout(r, 700));
    const tmp = join(LOG_DIR, `probe-${Date.now()}-${attempt}.png`);
    try { await run('screencapture', ['-x', tmp]); } catch {}
    try { screenshotBytes = existsSync(tmp) ? readFileSync(tmp).length : 0; } catch {}
    try { if (existsSync(tmp)) spawn('rm', ['-f', tmp]); } catch {}
  }

  return {
    ok,
    sessionType,
    screenshotBytes,
    screenRecordingPermission: screenshotBytes > 1000,
    note: ok
      ? (screenshotBytes > 1000
          ? 'Aqua session — macOS UI tests can run, and screenshots work.'
          : 'Aqua session — macOS UI tests CAN run. (screencapture is blocked, which only means Terminal lacks Screen Recording permission; XCUITest does not need it.)')
      : `Session is "${sessionType}", not Aqua — started over SSH or from a daemon. macOS UI tests cannot work here. Start this from Terminal.app ON the Mac.`,
  };
}

// ---------------------------------------------------------------------- jobs
// Allowlisted operations. `kind` picks the command; callers never supply a shell
// string, only structured arguments that we validate.
function buildCommand(kind, args = {}) {
  const onlyTesting = Array.isArray(args.onlyTesting) ? args.onlyTesting : [];
  // -only-testing values are identifiers like PocketDJUITests/FooUITests/testBar
  for (const t of onlyTesting) {
    if (!/^[A-Za-z0-9_./-]+$/.test(t)) throw new Error(`unsafe -only-testing value: ${t}`);
  }
  const derived = args.derivedDataPath && /^[A-Za-z0-9_./-]+$/.test(args.derivedDataPath)
    ? args.derivedDataPath : 'build-mactest';

  switch (kind) {
    case 'macos_tests': {
      // The repo's own script: build-unsigned → ad-hoc/CI-cert sign → test-without-building.
      // A plain `xcodebuild test -destination platform=macOS` cannot be used since the app
      // gained the Push capability — the Mac provisioning profile lacks aps-environment.
      const a = [join(APPLE, 'scripts', 'test-macos.sh'), derived];
      for (const t of onlyTesting) a.push(`-only-testing:${t}`);
      return { cmd: 'bash', args: a, cwd: APPLE };
    }
    case 'macos_build':
      // No dedicated build script in this repo — test-macos.sh's build phase is the
      // supported path, so a "build" is just a scoped test run that compiles everything.
      return { cmd: 'bash', args: [join(APPLE, 'scripts', 'test-macos.sh'), derived,
                                   '-only-testing:PocketDJTests/GenreTests'], cwd: APPLE };
    case 'screenshot': {
      const out = args.path && /^[A-Za-z0-9_./-]+$/.test(args.path)
        ? args.path : join(LOG_DIR, `shot-${Date.now()}.png`);
      return { cmd: 'screencapture', args: ['-x', out], cwd: ROOT, produces: out };
    }
    default:
      throw new Error(`unknown job kind: ${kind}`);
  }
}

// Every display-driving run — here or in any agent — must serialize on ONE lock.
// This bit was broken and cost real time: agents took /tmp/pdj-uitest.lock while this
// runner took nothing at all, so a runner job would happily walk into the middle of a
// lock-abiding agent's suite, `killall PocketDJ`, and destroy both runs. The victim's
// log reads "Failed to activate application" / "is not running", which looks exactly
// like a product regression. Wrap the command so the OS enforces exclusion rather than
// relying on everyone remembering the etiquette.
const UI_LOCK = '/tmp/pdj-uitest.lock';
function withDisplayLock(cmd, cmdArgs) {
  const inner = [cmd, ...cmdArgs].map((s) => `'${String(s).replace(/'/g, `'\\''`)}'`).join(' ');
  const py = `import fcntl,subprocess,sys,time
f=open(${JSON.stringify(UI_LOCK)},"w")
t0=time.time()
try:
    fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:
    print("[gui-runner] display busy — queued behind another UI run…",flush=True)
    fcntl.flock(f,fcntl.LOCK_EX)
    print("[gui-runner] acquired display lock after %ds"%(time.time()-t0),flush=True)
sys.exit(subprocess.call(${JSON.stringify(inner)},shell=True))`;
  return { cmd: '/usr/bin/python3', args: ['-c', py] };
}

// The real console's lock state, readable because THIS process lives in the Aqua
// session (the header's ioreg caveat is about SSH/background sessions, not us).
// IOConsoleLocked on the IORegistry root tracks loginwindow's actual lock.
async function consoleLocked() {
  const r = await run('/usr/sbin/ioreg', ['-n', 'Root', '-d1', '-a']);
  return /<key>IOConsoleLocked<\/key>\s*<true\/>/.test(r.out);
}

// ------------------------------------------------------------ demo recording
// mac_record_demo is the one MULTI-PHASE job: screen-record the display while the
// DemoVideoUITests suite drives the app, then mux the app's own in-app mix capture
// (.m4a) under the video. It cannot be expressed as a single allowlisted command,
// so it gets its own orchestrator — still allowlist-only (every spawned binary and
// argument is fixed here; callers supply only validated paths).
const FFMPEG = '/opt/homebrew/bin/ffmpeg';

// Hold /tmp/pdj-uitest.lock for the WHOLE multi-phase job, not just the test child.
// `withDisplayLock` wraps ONE command; here the screencapture must already be rolling
// when the test starts and must outlive it, so a dedicated holder process takes the
// same flock and keeps it until released. Same lock file, same blocking etiquette,
// same "queued behind another UI run" message — just a longer hold.
function acquireDisplayLock(onQueued) {
  const py = `import fcntl,signal,time
f=open(${JSON.stringify(UI_LOCK)},"w")
t0=time.time()
try:
    fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:
    print("QUEUED",flush=True)
    fcntl.flock(f,fcntl.LOCK_EX)
    print("WAITED %d"%(time.time()-t0),flush=True)
print("LOCKED",flush=True)
signal.pause()`;
  return new Promise((resolveLock, rejectLock) => {
    const p = spawn('/usr/bin/python3', ['-c', py]);
    let buf = '', queued = false, locked = false;
    p.stdout.on('data', (d) => {
      buf += d;
      if (!queued && buf.includes('QUEUED')) { queued = true; onQueued?.(); }
      if (!locked && buf.includes('LOCKED')) {
        locked = true;
        resolveLock({ release: () => { try { p.kill('SIGTERM'); } catch {} } });
      }
    });
    p.on('error', (e) => { if (!locked) rejectLock(e); });
    p.on('close', (code) => { if (!locked) rejectLock(new Error(`display-lock holder exited ${code}`)); });
  });
}

// Spawn a child whose stdout+stderr stream into the job log; `done` resolves with
// the exit code (never rejects — a spawn error resolves -1, matching startJob).
function runLogged(cmd, cmdArgs, opts, append) {
  const child = spawn(cmd, cmdArgs, opts);
  child.stdout.on('data', append);
  child.stderr.on('data', append);
  const done = new Promise((res) => {
    child.on('close', (code) => res(code));
    child.on('error', (e) => { append(`\n# spawn error (${cmd}): ${e.message}\n`); res(-1); });
  });
  return { child, done };
}

// Newest in-app mix recording created after `sinceMs`. MixRecorder (apple/PocketDJ/
// State/MixRecorder.swift + SessionFolders.swift) writes `recording-N.m4a` into
// `<Application Support>/mix-sessions/<mses_…>/`. Two possible roots: the plain
// user-domain Application Support (the ad-hoc/CI-signed test build carries no
// sandbox entitlements) and the sandbox container (an entitled build). NOT covered:
// a user-picked session folder (settings.sessionFolderBookmark) — security-scoped
// bookmarks can't be resolved from Node; if the demo's audio lands there, clear the
// custom folder in Settings ▸ Storage for the recording run.
// Directory listing via a TIMEOUT-BOUNDED child, never readdirSync: opening another
// app's sandbox container consults TCC ("access data from other apps"), and while the
// screen is locked that consult blocks open(2) INDEFINITELY — a bare readdirSync there
// wedged this whole server's event loop once (job 45fafa54: /mcp unresponsive, job
// frozen between phases). A child that hangs is SIGKILLed at 4s and the dir is skipped.
function listDirBounded(dir) {
  const r = spawnSync('/bin/ls', ['-1', dir],
                      { timeout: 4000, killSignal: 'SIGKILL', encoding: 'utf8' });
  if (r.status !== 0 || typeof r.stdout !== 'string') return null;
  return r.stdout.split('\n').filter(Boolean);
}

function newestMixRecording(sinceMs) {
  const home = process.env.HOME || '';
  const roots = [
    join(home, 'Library', 'Application Support', 'mix-sessions'),
    join(home, 'Library', 'Containers', 'com.levi.pocketdj', 'Data', 'Library', 'Application Support', 'mix-sessions'),
  ];
  let best = null;
  for (const root of roots) {
    const sessionDirs = listDirBounded(root);
    if (!sessionDirs) continue;
    for (const name of sessionDirs) {
      if (!name.startsWith('mses_')) continue;   // every real session id is "mses_…"
      const files = listDirBounded(join(root, name));
      if (!files) continue;
      for (const f of files) {
        if (!f.toLowerCase().endsWith('.m4a')) continue;
        const p = join(root, name, f);
        try {
          const st = statSync(p);
          if (st.mtimeMs >= sinceMs && (!best || st.mtimeMs > best.mtimeMs)) best = { path: p, mtimeMs: st.mtimeMs };
        } catch {}
      }
    }
  }
  return best;
}

function startDemoJob(args = {}) {
  // Output base: "<base>.mov" (raw screen video) and "<base>-final.mp4" (muxed).
  const base = args.path && /^[A-Za-z0-9_./-]+$/.test(args.path)
    ? args.path.replace(/\.(mov|mp4)$/i, '')
    : join(LOG_DIR, `demo-${Date.now()}`);
  const video = `${base}.mov`;
  const finalOut = `${base}-final.mp4`;
  const derived = args.derivedDataPath && /^[A-Za-z0-9_./-]+$/.test(args.derivedDataPath)
    ? args.derivedDataPath : 'build-mactest';

  const id = randomUUID().slice(0, 8);
  const log = join(LOG_DIR, `mac_record_demo-${id}.log`);
  writeFileSync(log, `# mac_record_demo ${JSON.stringify(args)}\n# video=${video} final=${finalOut}\n\n`);
  const job = { id, kind: 'mac_record_demo', args, status: 'running', exitCode: null, log,
                produces: finalOut, video, audio: null, final: null, phase: 'starting',
                started: new Date().toISOString(), ended: null };
  jobs.set(id, job);
  const append = (b) => { try { writeFileSync(log, b, { flag: 'a' }); } catch {} };

  (async () => {
    let lock = null;
    let cap = null;
    let caff = null;
    const startedMs = Date.now();
    try {
      // (1) Same Aqua gate as every UI job — PLUS Screen Recording, which (unlike
      // XCUITest) `screencapture -v` genuinely needs. Fail fast with the real reason.
      job.phase = 'checking-gui';
      const gui = await checkGuiAccess();
      if (!gui.ok) throw new Error(gui.note);
      if (!gui.screenRecordingPermission) {
        throw new Error('screencapture is blocked — Terminal lacks the Screen Recording TCC '
          + 'permission. Grant it in System Settings ▸ Privacy & Security ▸ Screen Recording, '
          + 'restart this runner, and retry. (Tests can run without it; a demo VIDEO cannot.)');
      }

      // (1b) The walk needs an UNLOCKED console: on the lock screen the app can never
      // come foreground (XCUITest: "current state: Running Background") and the video
      // is minutes of lock screen — job 45fafa54's exact failure. Gate BEFORE any
      // recording rolls, so a fire-while-away simply starts the moment of unlock.
      job.phase = 'waiting-for-unlock';
      const unlockWaitSecs = Number(args.waitForUnlockSeconds) > 0
        ? Number(args.waitForUnlockSeconds) : 900;
      const unlockDeadline = Date.now() + unlockWaitSecs * 1000;
      let saidLocked = false;
      while (await consoleLocked()) {
        if (!saidLocked) {
          saidLocked = true;
          append(`[gui-runner] screen is LOCKED — waiting up to ${unlockWaitSecs}s for unlock before recording…\n`);
        }
        if (Date.now() > unlockDeadline) {
          throw new Error(`screen stayed locked for ${unlockWaitSecs}s — unlock the Mac and re-fire mac_record_demo`);
        }
        await new Promise((r) => setTimeout(r, 5000));
      }
      if (saidLocked) append('[gui-runner] screen unlocked — proceeding\n');

      // (1c) Hold a display-awake assertion for the whole job: a mid-run display
      // sleep re-locks the console and kills the walk the same way.
      caff = spawn('/usr/bin/caffeinate', ['-dis']);

      job.phase = 'acquiring-display-lock';
      lock = await acquireDisplayLock(() =>
        append('[gui-runner] display busy — queued behind another UI run…\n'));
      append('[gui-runner] display lock held for the whole demo job\n');

      // (2) Roll the screen recording. SIGINT later stops it cleanly and finalizes
      // the .mov. NOTE: test-macos.sh's build-for-testing phase happens ON CAMERA —
      // pre-warm the build (any mac_run_tests with the same derivedDataPath) so this
      // lead-in is seconds of cache-hit, not minutes of compiling.
      job.phase = 'recording';
      append(`[gui-runner] screencapture -v -x → ${video}\n`);
      cap = runLogged('screencapture', ['-v', '-x', video], {}, append);

      // (3) The demo suite, run EXACTLY like macos_tests (same script, same cwd,
      // same lock etiquette) but pinned to DemoVideoUITests. Env convention per
      // apple/Tests/UI/XCUIHelpers.swift: test-macos.sh forwards its environment
      // untouched to xcodebuild, and xcodebuild strips the `TEST_RUNNER_` prefix
      // and injects the rest into the test-runner process — so the suite sees
      // PDJ_DEMO_VIDEO=1.
      job.phase = 'testing';
      const testArgs = [join(APPLE, 'scripts', 'test-macos.sh'), derived,
                        '-only-testing:PocketDJUITests/DemoVideoUITests'];
      append(`[gui-runner] TEST_RUNNER_PDJ_DEMO_VIDEO=1 bash ${testArgs.join(' ')}\n`);
      const test = runLogged('bash', testArgs, {
        cwd: APPLE,
        env: { ...process.env,
               DEVELOPER_DIR: process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer',
               TEST_RUNNER_PDJ_DEMO_VIDEO: '1',
               // Preferred library collection for the walk's menu type-ahead (see
               // DemoVideoUITests.pickMenuItem) — plain name, validated tightly.
               ...(typeof args.collection === 'string' && /^[\w \-']{1,80}$/.test(args.collection)
                   ? { TEST_RUNNER_PDJ_DEMO_COLLECTION: args.collection } : {}) },
      }, append);
      const testCode = await test.done;
      append(`\n[gui-runner] demo test exited ${testCode}\n`);

      // (4) Stop the recording and WAIT for screencapture to exit — that exit is
      // the .mov finalize; killing harder (or not waiting) leaves a truncated moov.
      job.phase = 'finalizing-video';
      try { cap.child.kill('SIGINT'); } catch {}
      const capCode = await cap.done;
      cap = null;
      append(`[gui-runner] screencapture exited ${capCode}\n`);
      if (!existsSync(video)) throw new Error('screencapture produced no .mov');
      // A nonzero test exit is NOT fatal here: the walk runs with continueAfterFailure, so a
      // recorded cosmetic failure (stale-snapshot tap, non-adjustable slider, unfocused typeKey)
      // still means a complete video + .m4a pair — locate + mux best-effort and surface the
      // failure through job.status/exitCode instead of discarding the artifact.
      const testFailed = testCode !== 0;
      if (testFailed) {
        job.exitCode = testCode;
        append(`[gui-runner] WARNING: demo test exited ${testCode} — muxing anyway; review the walk log\n`);
      }

      // (5) The soundtrack: the newest in-app mix capture written DURING this job.
      job.phase = 'locating-audio';
      const m4a = newestMixRecording(startedMs);
      if (!m4a) {
        throw new Error('no fresh in-app mix recording found under Application Support/'
          + 'mix-sessions (plain or sandbox container) — did the demo tap mix-record? '
          + '(A user-picked session folder is not searchable from here; see the comment '
          + `on newestMixRecording.) Raw video kept at ${video}`);
      }
      job.audio = m4a.path;
      append(`[gui-runner] in-app mix recording: ${m4a.path}\n`);

      // (6) Mux. ALIGNMENT CAVEAT: the .m4a starts when the demo tapped mix-record,
      // some unknowable seconds after screencapture started — there is no timestamp
      // tying the two clocks together, so the audio is mapped from t=0 of the video
      // and `-shortest` pads/truncates. The result drifts by the lead-in (launch +
      // any build time on camera); a pre-warmed build keeps that small. Perfect sync
      // would need the app to emit a capture-start timestamp — not built today.
      job.phase = 'muxing';
      const ff = runLogged(FFMPEG, ['-y', '-i', video, '-i', m4a.path,
        '-map', '0:v:0', '-map', '1:a:0',
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', '-shortest',
        finalOut], {}, append);
      const ffCode = await ff.done;
      if (ffCode !== 0 || !existsSync(finalOut)) throw new Error(`ffmpeg mux failed (exit ${ffCode})`);
      // job.final is populated either way so mac_job_status hands back the artifact even on a
      // failed-but-complete walk; status still reports the recorded test failure honestly.
      job.final = finalOut;
      job.phase = 'done';
      job.status = testFailed ? 'failed' : 'succeeded';
      job.exitCode = testCode;
    } catch (e) {
      job.status = 'failed';
      if (job.exitCode === null) job.exitCode = -1;
      job.phase = `failed (was: ${job.phase})`;
      append(`\n# mac_record_demo error: ${e.message}\n`);
    } finally {
      if (cap) { try { cap.child.kill('SIGINT'); } catch {} await cap.done; }
      if (caff) { try { caff.kill(); } catch {} }
      lock?.release();
      job.ended = new Date().toISOString();
      append(`\n# exit ${job.exitCode}\n`);
      console.log(`[gui-runner] mac_record_demo ${id} → ${job.status} (exit ${job.exitCode})`);
    }
  })();

  console.log(`[gui-runner] started mac_record_demo ${id} → ${log}`);
  return job;
}

function startJob(kind, args = {}) {
  // The one job buildCommand can't express (multi-phase); still allowlist-only.
  if (kind === 'mac_record_demo') return startDemoJob(args);
  const built = buildCommand(kind, args);
  const { cwd, produces } = built;
  // Screenshots are instantaneous and harmless; only real test runs need the lock.
  const needsLock = kind !== 'screenshot';
  const { cmd, args: cmdArgs } = needsLock ? withDisplayLock(built.cmd, built.args) : built;
  const id = randomUUID().slice(0, 8);
  const log = join(LOG_DIR, `${kind}-${id}.log`);
  writeFileSync(log, `# ${kind} ${JSON.stringify(args)}\n# ${cmd} ${cmdArgs.join(' ')}\n\n`);
  const job = { id, kind, args, status: 'running', exitCode: null, log, produces: produces || null,
                started: new Date().toISOString(), ended: null };
  jobs.set(id, job);

  const child = spawn(cmd, cmdArgs, {
    cwd,
    env: { ...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer' },
  });
  const append = (b) => { try { writeFileSync(log, b, { flag: 'a' }); } catch {} };
  child.stdout.on('data', append);
  child.stderr.on('data', append);
  child.on('close', (code) => {
    job.status = code === 0 ? 'succeeded' : 'failed';
    job.exitCode = code;
    job.ended = new Date().toISOString();
    append(`\n# exit ${code}\n`);
    console.log(`[gui-runner] ${kind} ${id} → ${job.status} (exit ${code})`);
  });
  child.on('error', (e) => {
    job.status = 'failed'; job.exitCode = -1; job.ended = new Date().toISOString();
    append(`\n# spawn error: ${e.message}\n`);
  });
  console.log(`[gui-runner] started ${kind} ${id} → ${log}`);
  return job;
}

function jobView(job, tailLines = 40) {
  let tail = '';
  try {
    const txt = readFileSync(job.log, 'utf8');
    tail = txt.split('\n').slice(-tailLines).join('\n');
  } catch {}
  // Pull the lines a caller actually cares about out of a 100k-line xcodebuild log.
  let summary = '';
  try {
    const txt = readFileSync(job.log, 'utf8');
    const m = txt.match(/Executed \d+ tests?, with [^\n]*/g);
    const fails = (txt.match(/Test Case '-\[[^\]]+\]' failed/g) || []).length;
    const verdict = /\*\* TEST (SUCCEEDED|EXECUTE SUCCEEDED) \*\*/.test(txt) ? 'TEST SUCCEEDED'
                  : /\*\* TEST (FAILED|EXECUTE FAILED) \*\*/.test(txt) ? 'TEST FAILED'
                  : /\*\* BUILD SUCCEEDED \*\*/.test(txt) ? 'BUILD SUCCEEDED'
                  : /\*\* BUILD FAILED \*\*/.test(txt) ? 'BUILD FAILED' : '';
    summary = [verdict, ...(m ? m.slice(-3) : []), fails ? `${fails} failed test cases` : ''].filter(Boolean).join(' | ');
  } catch {}
  return { ...job, summary, tail };
}

// ------------------------------------------------------------------- MCP glue
const TOOLS = [
  {
    name: 'mac_health',
    description: 'Verify this runner really has GUI-session access (takes a real screenshot and checks it decoded). Call this FIRST — if it reports ok:false, macOS UI tests cannot work and any failures are environmental.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'mac_run_tests',
    description: 'Run the macOS test suite via apple/scripts/test-macos.sh in the GUI session. Returns a job id immediately; poll mac_job_status. Use onlyTesting to scope (e.g. ["PocketDJUITests/FavoritesUITests"]). This is the ONLY way to run macOS XCUITests when the agent is on SSH.',
    inputSchema: {
      type: 'object',
      properties: {
        onlyTesting: { type: 'array', items: { type: 'string' }, description: 'Optional -only-testing identifiers' },
        derivedDataPath: { type: 'string', description: 'Derived data dir relative to apple/ (default build-mactest)' },
      },
    },
  },
  {
    name: 'mac_record_demo',
    description: 'Record the PocketDJ demo video end-to-end: verify Aqua session + Screen Recording permission, wait for the console to be UNLOCKED (up to args.waitForUnlockSeconds, default 900s — the app cannot come foreground on a locked screen), hold a caffeinate display-awake assertion and the display lock for the whole job, roll `screencapture -v -x <out>.mov`, run -only-testing:PocketDJUITests/DemoVideoUITests via apple/scripts/test-macos.sh with TEST_RUNNER_PDJ_DEMO_VIDEO=1 (xcodebuild strips the TEST_RUNNER_ prefix, so the suite sees PDJ_DEMO_VIDEO=1), SIGINT screencapture on test completion, find the newest in-app mix recording (.m4a under Application Support/mix-sessions/mses_*/, plain or sandbox-container root), and mux with ffmpeg → <out>-final.mp4 (H.264 + AAC, faststart). CAVEAT: the mix audio starts when the demo tapped mix-record, not at video t=0 — it is mapped from 0 with -shortest, so pre-warm the build (mac_run_tests, same derivedDataPath) to keep the on-camera lead-in (and the resulting A/V offset) small. Returns a job id immediately; poll mac_job_status — the finished job carries video/audio/final paths.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Output base path — ".mov" and "-final.mp4" are appended (default: <logDir>/demo-<ts>)' },
        derivedDataPath: { type: 'string', description: 'Derived data dir relative to apple/ (default build-mactest)' },
      },
    },
  },
  {
    name: 'mac_job_status',
    description: 'Poll a job started by this runner. Returns status, exit code, a parsed summary (verdict + Executed-N-tests lines + failure count) and a log tail. The full log path is on the shared filesystem and can be read directly.',
    inputSchema: { type: 'object', properties: { id: { type: 'string' }, tailLines: { type: 'number' } }, required: ['id'] },
  },
  {
    name: 'mac_screenshot',
    description: 'Capture the Mac screen to a PNG (works only because this process is in the GUI session). Useful for verifying real UI state that an SSH agent cannot see.',
    inputSchema: { type: 'object', properties: { path: { type: 'string' } } },
  },
];

async function callTool(name, a = {}) {
  switch (name) {
    case 'mac_health': {
      const gui = await checkGuiAccess();
      return { ...gui, logDir: LOG_DIR, root: ROOT };
    }
    case 'mac_run_tests': return startJob('macos_tests', a);
    case 'mac_record_demo': return startJob('mac_record_demo', a);
    case 'mac_screenshot': return startJob('screenshot', a);
    case 'mac_job_status': {
      const j = jobs.get(a.id);
      if (!j) return { error: `no such job: ${a.id}`, known: [...jobs.keys()] };
      return jobView(j, a.tailLines || 40);
    }
    default: return { error: `unknown tool: ${name}` };
  }
}

function rpc(id, result) { return { jsonrpc: '2.0', id, result }; }

async function handleMcp(body) {
  const { id, method, params } = body;
  if (method === 'initialize') {
    return rpc(id, {
      protocolVersion: '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'pocketdj-mac-gui-runner', version: '1.0.0' },
    });
  }
  if (method === 'notifications/initialized') return null;
  if (method === 'tools/list') return rpc(id, { tools: TOOLS });
  if (method === 'tools/call') {
    const out = await callTool(params?.name, params?.arguments || {});
    return rpc(id, { content: [{ type: 'text', text: JSON.stringify(out, null, 2) }] });
  }
  return { jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } };
}

// ---------------------------------------------------------------------- server
const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const json = (code, obj) => {
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(JSON.stringify(obj, null, 2));
  };

  if (req.method === 'GET' && url.pathname === '/health') {
    const gui = await checkGuiAccess();
    return json(200, { ok: true, service: 'mac-gui-runner', version: 1, gui: gui.ok, screenshotBytes: gui.bytes, jobs: jobs.size, logDir: LOG_DIR });
  }
  if (req.method === 'GET' && url.pathname.startsWith('/jobs/')) {
    const j = jobs.get(url.pathname.split('/')[2]);
    return j ? json(200, jobView(j)) : json(404, { error: 'no such job' });
  }
  if (req.method === 'GET' && url.pathname === '/jobs') {
    return json(200, { jobs: [...jobs.values()].map((j) => ({ id: j.id, kind: j.kind, status: j.status, exitCode: j.exitCode })) });
  }

  let body = '';
  req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
  req.on('end', async () => {
    let parsed = {};
    try { parsed = body ? JSON.parse(body) : {}; } catch { return json(400, { error: 'bad json' }); }

    if (req.method === 'POST' && url.pathname === '/mcp') {
      const out = await handleMcp(parsed);
      if (out === null) { res.writeHead(202); return res.end(); }
      return json(200, out);
    }
    if (req.method === 'POST' && url.pathname === '/run') {
      try { return json(200, startJob(parsed.kind || 'macos_tests', parsed.args || {})); }
      catch (e) { return json(400, { error: e.message }); }
    }
    json(404, { error: 'not found', endpoints: ['GET /health', 'GET /jobs', 'GET /jobs/:id', 'POST /run', 'POST /mcp'] });
  });
});

// A stale instance holding the port is the single most likely startup failure (an
// agent's smoke test, or a previous window you forgot). Say so in one line and offer
// the fix, rather than dumping an unhandled EADDRINUSE stack trace.
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`\n  ❌ Port ${PORT} is already in use — something else is holding it.\n`);
    console.error(`  Most likely a stale copy of this server. See what it is:`);
    console.error(`      lsof -i :${PORT}`);
    console.error(`  If it IS a stale mac-gui-runner, take the port back:`);
    console.error(`      lsof -ti:${PORT} | xargs kill -9 && bash apple/scripts/mac-gui-runner-start.sh`);
    console.error(`  Or just use another port:`);
    console.error(`      PDJ_GUI_RUNNER_PORT=8792 bash apple/scripts/mac-gui-runner-start.sh`);
    console.error(`  (if you change it, tell Claude — .mcp.json points at ${PORT})\n`);
    process.exit(1);
  }
  console.error(`\n  ❌ Server error: ${err.message}\n`);
  process.exit(1);
});

server.listen(PORT, '127.0.0.1', async () => {
  const gui = await checkGuiAccess();
  console.log(`\n  PocketDJ Mac GUI runner → http://127.0.0.1:${PORT}`);
  console.log(`  logs: ${LOG_DIR}`);
  console.log(`  launchd session: ${gui.sessionType}`);
  if (gui.ok) {
    console.log(`  ✅ Aqua session — macOS UI tests WILL run.`);
    if (!gui.screenRecordingPermission) {
      console.log(`     (screencapture is blocked — Terminal lacks Screen Recording permission.`);
      console.log(`      That is fine: XCUITest does not need it. Grant it in System Settings ▸`);
      console.log(`      Privacy & Security ▸ Screen Recording only if you want screenshots.)`);
    }
    console.log('');
  } else {
    console.log(`  ❌ NOT an Aqua session — macOS UI tests cannot work here.`);
    console.log(`     Start this from Terminal.app ON the Mac (not SSH, not a daemon).\n`);
  }
  console.log(`  Leave this window open. Ctrl-C to stop.\n`);
});
