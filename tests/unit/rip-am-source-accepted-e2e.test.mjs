// REGRESSION (2026-09-29): an "Apple Music (Local)" song must be ACCEPTED by POST /rip.
//
// From 2026-09-05 a source allowlist (My Vinyl | My Digital) made acceptRip answer every
// Apple Music row with a 200 "ineligible" body — no job, no worker, no log line — so every
// passive stream-through rip silently stopped for 24 days. The operator decides what their
// own server captures; the server must not second-guess a known catalog row. Also pins the
// one-line-per-request log, so a refusal can never be invisible again.
//
// Boots the real rip server (isolated HOME, allocated port, fake aws + osascript, a capture
// worker that just reports success) exactly like rip-server-heal-e2e.test.mjs.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { freePort } from './helpers/free-port.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const USER = 'user-token-for-the-app-tier';
const ADMIN = 'admin-token-for-the-admin-tier';
const AUTH = { authorization: `Bearer ${USER}` };
const AM_SONG = 'sng_am_local_row';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let work, srv, base, serverLog = '', srvExit = null;

beforeAll(async () => {
  work = mkdtempSync(join(tmpdir(), 'pdj-am-accept-'));
  const shimDir = join(work, 'bin');
  mkdirSync(shimDir, { recursive: true });
  mkdirSync(join(work, 'home'), { recursive: true });
  const shell = (p, body) => { writeFileSync(p, body); chmodSync(p, 0o755); };
  shell(join(shimDir, 'aws'), `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(join(REPO, 'scripts/test/fake-aws.mjs'))} "$@"\n`);
  shell(join(shimDir, 'osascript'), `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(join(REPO, 'scripts/test/fake-music-rig.mjs'))} "$@"\n`);
  shell(join(shimDir, 'pkill'), '#!/bin/sh\nexit 0\n');   // never touch the real Music.app

  const catalog = join(work, 'am.json');
  writeFileSync(catalog, JSON.stringify({
    manifest: { sourceType: 'digital', sourceName: 'Apple Music (Local)' },
    albums: [{ id: 'alb_am', artist: 'Aaliyah', name: 'Aaliyah', trackList: [AM_SONG] }],
    songs: [{ id: AM_SONG, albumId: 'alb_am', artist: 'Aaliyah', name: "Don't Know What to Tell Ya", length: 3000 }],
  }));
  const worker = join(work, 'worker.mjs');
  writeFileSync(worker, `
import { writeFileSync } from 'node:fs';
const a = {}; for (let i=2;i<process.argv.length;i++){const k=process.argv[i];if(k.startsWith('--'))a[k.slice(2)]=process.argv[++i];}
const key = 'rips/' + a['song-id'] + '.mp3';
writeFileSync(a.status, JSON.stringify({ songId: a['song-id'], phase: 'uploaded', key, bytes: 4242, updatedAt: Date.now() }));
console.log('RESULT ' + JSON.stringify({ ok: true, key, bytes: 4242 }));
`);
  const env = {
    ...process.env,
    PATH: `${shimDir}:${dirname(process.execPath)}:/usr/bin:/bin`,
    HOME: join(work, 'home'),
    RIP_BUCKET: 'pocketdj-test-bucket',
    RIP_SOURCES: catalog,
    RIP_WORKER: worker,
    RIP_PUBLIC_FOLD: '0',
    RIP_TOKEN: USER,
    RIP_ADMIN_TOKEN: ADMIN,
    POCKETDJ_STEM_OFFLOAD: '0',
    POCKETDJ_AUTO_STEM_ON_RIP: '0',
    POCKETDJ_ANALYSIS_OFFLOAD: '0',
    PDJ_FAKE_COUNTER: join(work, 'fake-counter'),
    RIP_TEST_DIGITAL_BUFFER_MS: '2000',
    RIP_TEST_DIGITAL_FLOOR_MS: '2000',
  };
  for (let attempt = 1; ; attempt++) {
    const port = await freePort();
    base = `http://127.0.0.1:${port}`;
    serverLog = ''; srvExit = null;
    srv = spawn(process.execPath, [join(REPO, 'scripts/rip-server.mjs')],
      { env: { ...env, RIP_PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe'] });
    srv.stdout.on('data', (d) => { serverLog += d; });
    srv.stderr.on('data', (d) => { serverLog += d; });
    srv.on('exit', (code, sig) => { srvExit = sig || code; });
    let up = false;
    for (let i = 0; i < 300 && srvExit === null && !up; i++) {
      try { up = (await fetch(`${base}/health`)).ok; } catch { /* not up yet */ }
      if (!up) await sleep(100);
    }
    if (up) break;
    try { srv.kill('SIGKILL'); } catch { /* already gone */ }
    if (srvExit !== null && /EADDRINUSE/.test(serverLog) && attempt < 5) continue;
    throw new Error(`rip-server never became healthy on ${base} (exit=${srvExit})\n${serverLog}`);
  }
}, 60_000);

afterAll(() => {
  try { srv?.kill('SIGKILL'); } catch { /* already gone */ }
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('POST /rip for an Apple Music (Local) song', () => {
  it('enqueues a job instead of a silent 200 refusal, and logs the outcome', async () => {
    const r = await fetch(`${base}/rip`, {
      method: 'POST', headers: { 'content-type': 'application/json', ...AUTH }, body: JSON.stringify({ songId: AM_SONG }),
    });
    const body = await r.json();
    expect(r.status).toBe(200);
    expect(body && body.jobId, `no job — got ${JSON.stringify(body)}\n${serverLog}`).toBeTruthy();
    expect(body.error).toBeFalsy();
    const end = Date.now() + 5_000;
    while (Date.now() < end && !/POST \/rip sng_am_local_row → queued job=/.test(serverLog)) await sleep(50);
    expect(serverLog).toMatch(/POST \/rip sng_am_local_row → queued job=/);
  }, 30_000);
});
