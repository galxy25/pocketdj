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
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
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
  const tmp = join(LOG_DIR, `.probe-${Date.now()}.png`);
  await run('screencapture', ['-x', tmp]);
  try { screenshotBytes = existsSync(tmp) ? readFileSync(tmp).length : 0; } catch {}
  try { if (existsSync(tmp)) spawn('rm', ['-f', tmp]); } catch {}

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

function startJob(kind, args = {}) {
  const { cmd, args: cmdArgs, cwd, produces } = buildCommand(kind, args);
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
