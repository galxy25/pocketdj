// END-TO-END wiring test for the playback-health check: does the rip SKILL (where `play` is
// actually issued) detect a wedged Music.app, and does that diagnosis SURVIVE the process
// boundary up to the rip server's reason code?
//
// The unit tests in music-health.test.mjs prove the detector. This file proves it is WIRED —
// which is the half that was missing: the skill already wrote a precise per-track status into
// rip-manifest.json, and rip-one.mjs threw it away and re-derived a generic "no audio captured"
// verdict, so the one remedy that works was unreachable from any code path for 38 hours.
//
// SAFETY: the real Music.app and Audio Hijack belong to a LIVE rip daemon. Both are intercepted
// by a fake `osascript` / `shortcuts` on PATH (scripts/test/fake-music-rig.mjs), and every test
// asserts the shim was really used — if PATH interception ever stopped working the test FAILS
// rather than quietly driving the user's GUI.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
// The shim dir comes FIRST so the fakes win over /usr/bin/osascript; node's own dir is included
// because rip-one.mjs spawns the rip skill as plain `node`.
const pathWith = (binDir) => `${binDir}:${dirname(process.execPath)}:/usr/bin:/bin`;
const RIP_SKILL = join(REPO, '.claude/skills/rip/rip.mjs');
const RIP_ONE = join(REPO, 'scripts/rip-one.mjs');
const SONG = 'sng_fake_wedge';

let work, binDir, logFile;

beforeAll(() => {
  work = mkdtempSync(join(tmpdir(), 'pdj-playback-health-'));
  binDir = join(work, 'bin');
  logFile = join(work, 'rig.log');
  mkdirSync(binDir, { recursive: true });

  // PATH shims — the same trick scripts/test/rip-selfheal-e2e.mjs uses for `aws`.
  const shim = join(REPO, 'scripts/test/fake-music-rig.mjs');
  for (const name of ['osascript', 'shortcuts']) {
    const p = join(binDir, name);
    writeFileSync(p, `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(shim)} "$@"\n`);
    chmodSync(p, 0o755);
  }

  // A one-track library export (the loader is a line-based plist scan, so this is enough).
  writeFileSync(join(work, 'library.xml'), `<plist><dict><dict>
<key>Persistent ID</key><string>AAAABBBBCCCC1111</string>
<key>Name</key><string>Fake Song</string>
<key>Artist</key><string>Fake Artist</string>
<key>Album</key><string>Fake Album</string>
</dict></dict></plist>`);
  writeFileSync(join(work, 'index.json'), JSON.stringify({
    manifest: { sourceType: 'digital' },
    albums: [{ id: 'alb_x', artist: 'Fake Artist', name: 'Fake Album', trackList: [SONG] }],
    songs: [{ id: SONG, albumId: 'alb_x', artist: 'Fake Artist', name: 'Fake Song' }],
  }));
  writeFileSync(join(work, 'setlist.csv'), `Song ID\n${SONG}\n`);
});

afterAll(() => { try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ } });

// Run the rip skill against the fake rig. `caseName` isolates each run's dirs/counters.
function runSkill(caseName, { mode, ahDead = false, extra = [] } = {}) {
  const outBase = join(work, `out-${caseName}`);
  const ahDir = join(work, `ah-${caseName}`);
  mkdirSync(outBase, { recursive: true });
  mkdirSync(ahDir, { recursive: true });
  const r = spawnSync(process.execPath, [
    RIP_SKILL,
    '--setlist', join(work, 'setlist.csv'), '--index', join(work, 'index.json'),
    '--library-xml', join(work, 'library.xml'),
    '--out-base', outBase, '--ah-recordings-dir', ahDir, '--limit', '1',
    '--settle-ms', '20', '--tail-ms', '20', '--play-start-timeout-ms', '1200', ...extra,
  ], {
    cwd: REPO, encoding: 'utf8', timeout: 60_000,
    env: {
      ...process.env,
      PATH: pathWith(binDir),                   // the shims win over /usr/bin/osascript
      PDJ_FAKE_MODE: mode, PDJ_FAKE_LOG: logFile, PDJ_FAKE_AH_DIR: ahDir,
      PDJ_FAKE_COUNTER: join(work, `counter-${caseName}`),
      ...(ahDead ? { PDJ_FAKE_AH_DEAD: '1' } : {}),
    },
  });
  const dirs = readdirSync(outBase).filter((d) => d.endsWith('_ripped')).map((d) => join(outBase, d));
  const manifest = dirs.length ? JSON.parse(readFileSync(join(dirs[0], 'rip-manifest.json'), 'utf8')) : null;
  return { r, manifest, track: manifest?.tracks?.[0] || null, outBase, ahDir };
}

const rigLog = () => (existsSync(logFile) ? readFileSync(logFile, 'utf8') : '');

describe('rip skill: a play that is ACCEPTED but never starts', () => {
  it('(a) is DETECTED and named — not reported as a missing file', () => {
    const { r, track } = runSkill('wedged', { mode: 'wedged' });

    // the fake rig really did intercept everything (no real Music.app was touched)
    expect(rigLog()).toContain('play-accepted');
    // …and the play command was accepted, exactly as it was during the incident
    expect(track).toBeTruthy();

    expect(track.status).toBe('play-not-started');       // ← the detection, by name
    expect(track.err).toMatch(/never reached state=playing/);
    expect(track.err).toMatch(/missing value/);          // the position that used to parse as 0
    // and NOT the old ambiguous verdict that made the wedge indistinguishable from a dead rig
    expect(track.status).not.toBe('no-recording');
  }, 60_000);

  it('exits NON-ZERO when nothing was captured, so its caller cannot read failure as success', () => {
    const { r } = runSkill('wedged-exit', { mode: 'wedged' });
    expect(r.status).not.toBe(0);
    expect(r.stdout).toMatch(/Done: 0\/1 ripped/);
  }, 60_000);

  it('fails FAST — ~1s, not a whole song length of recorded silence', () => {
    const t0 = Date.now();
    runSkill('wedged-fast', { mode: 'wedged' });
    expect(Date.now() - t0).toBeLessThan(20_000);
  }, 60_000);
});

describe('rip skill: a healthy capture', () => {
  it('(d) reports ok, exits 0, and never claims a wedge', () => {
    const { r, track } = runSkill('healthy', { mode: 'healthy', extra: ['--max-seconds', '1'] });
    expect(track.status).toBe('ok');
    expect(r.status).toBe(0);
    expect(rigLog()).toContain('play-accepted');
  }, 60_000);
});

describe('rip skill: Audio Hijack armed but recording nothing', () => {
  it('gets its OWN name — identical symptom to the wedge, opposite cause', () => {
    // Music plays fine; the "Rip Start" shortcut exits 0 and records nothing.
    const { track } = runSkill('ah-dead', { mode: 'healthy', ahDead: true, extra: ['--ah-file-timeout-ms', '600'] });
    expect(track.status).toBe('ah-not-recording');
    expect(track.status).not.toBe('play-not-started');
  }, 60_000);
});

describe('rip-one.mjs: the diagnosis survives the process boundary', () => {
  it('propagates reason "play-not-started" instead of collapsing it into "no-match"', () => {
    const statusFile = join(work, 'job-status.json');
    const ahDir = join(work, 'ah-ripone');
    mkdirSync(ahDir, { recursive: true });
    const r = spawnSync(process.execPath, [
      RIP_ONE, '--song-id', SONG, '--artist', 'Fake Artist', '--title', 'Fake Song',
      '--status', statusFile, '--library-xml', join(work, 'library.xml'),
      '--tmp', join(work, 'tmp-ripone'), '--ah-recordings-dir', ahDir,
    ], {
      cwd: REPO, encoding: 'utf8', timeout: 60_000,
      env: {
        ...process.env,
        PATH: pathWith(binDir),
        PDJ_FAKE_MODE: 'wedged', PDJ_FAKE_LOG: logFile, PDJ_FAKE_AH_DIR: ahDir,
        PDJ_FAKE_COUNTER: join(work, 'counter-ripone'),
        RIP_TEST_SETTLE_MS: '20', RIP_TEST_TAIL_MS: '20', RIP_TEST_PLAY_START_MS: '1200',
      },
    });
    const result = JSON.parse((r.stdout.match(/^RESULT (.*)$/m) || [])[1] || '{}');
    expect(result.ok).toBe(false);
    // THE fix: this is the reason code the rip server heals on. As 'no-match' it was inert.
    expect(result.reason).toBe('play-not-started');
    expect(result.error).toMatch(/never reached state=playing/);
    // the status file the rip server actually reads carries it too
    expect(JSON.parse(readFileSync(statusFile, 'utf8'))).toMatchObject({ phase: 'error', reason: 'play-not-started' });
  }, 60_000);

  it('a genuinely absent track still reports the ORIGINAL no-match reason (no over-claiming)', () => {
    const statusFile = join(work, 'job-status-missing.json');
    const ahDir = join(work, 'ah-missing');
    mkdirSync(ahDir, { recursive: true });
    const r = spawnSync(process.execPath, [
      RIP_ONE, '--song-id', 'sng_not_in_library', '--artist', 'Nobody', '--title', 'Nothing',
      '--status', statusFile, '--library-xml', join(work, 'library.xml'),
      '--tmp', join(work, 'tmp-missing'), '--ah-recordings-dir', ahDir,
    ], {
      cwd: REPO, encoding: 'utf8', timeout: 60_000,
      env: {
        ...process.env,
        PATH: pathWith(binDir),
        // the live-search fallback finds nothing → play-failed, never a wedge claim
        PDJ_FAKE_MODE: 'wedged', PDJ_FAKE_LOG: logFile, PDJ_FAKE_AH_DIR: ahDir,
        PDJ_FAKE_COUNTER: join(work, 'counter-missing'),
        RIP_TEST_SETTLE_MS: '20', RIP_TEST_TAIL_MS: '20', RIP_TEST_PLAY_START_MS: '600',
      },
    });
    const result = JSON.parse((r.stdout.match(/^RESULT (.*)$/m) || [])[1] || '{}');
    expect(result.ok).toBe(false);
    expect(result.reason).toBe('no-match'); // ← healing Music cannot help this one; don't heal
  }, 60_000);
});
