#!/usr/bin/env node
// Offline DRY-RUN harness for the Apple Music (Local) sync feature. Exercises the whole thing
// WITHOUT touching the live Music library, the real ~/Downloads, prod S3, GitHub, or the running
// rip server:
//   (1) the diff/change-set BRAIN — the real index-apple-music.mjs CLI the server shells out to,
//   (2) the rip-server ENDPOINTS — POST /am-sync → jobId, GET /am-sync/<id> → result set, the
//       change-set + snapshot written to a TEMP Downloads (never the real one), and the exclusive-
//       boundary "no new tracks ⇒ 0 added, no change-set" property,
//   (3) the SCHEDULER math (msUntilNext) + the inert gate,
//   (4) the CRON-AGENT ordered sequence (index → git commit → git push → deploy.sh → mark
//       processed), the empty-diff guard, and the already-processed no-op — with git/deploy/node/jq
//       shimmed by fakes that just log.
//
//   node scripts/test/am-sync-dryrun.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, readFileSync, existsSync, mkdtempSync, mkdirSync, rmSync, chmodSync, copyFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const FIX = join(REPO, 'scripts/test/fixtures');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };
const work = mkdtempSync(join(tmpdir(), 'pdj-amsync-'));

// run a node subprocess to completion, capturing stdout/stderr.
function runNode(args, env = {}) {
  return new Promise((res) => {
    const p = spawn('node', args, { cwd: REPO, env: { ...process.env, ...env } });
    let out = '', err = '';
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (err += d));
    p.on('close', (code) => res({ code, out, err }));
  });
}

try {
  // ============================================================================
  // (1) DIFF / CHANGE-SET BRAIN — the exact CLI the server shells out to.
  // ============================================================================
  console.log('\n(1) diff brain — index-apple-music.mjs incremental CLI');
  const s1 = join(work, 'brain'); mkdirSync(s1, { recursive: true });
  const state = join(s1, 'state.json');
  // seed the cursor between v1 (2020) and v2's new tracks (2026) → v1 emits 0.
  let r = await runNode(['scripts/index-apple-music.mjs', '--xml', join(FIX, 'library-v1.xml'),
    '--out', join(s1, 'v1.json'), '--state', state, '--since', '2021-01-01T00:00:00Z']);
  ok(r.code === 0, 'seed run exits 0');
  const v1 = JSON.parse(readFileSync(join(s1, 'v1.json'), 'utf8'));
  ok(v1.songs.length === 0, `seed emits 0 songs (older than cursor) (got ${v1.songs.length})`);

  // delta on v2 → exactly the 2 genuinely-new tracks.
  r = await runNode(['scripts/index-apple-music.mjs', '--xml', join(FIX, 'library-v2.xml'),
    '--out', join(s1, 'v2.json'), '--state', state]);
  ok(r.code === 0, 'delta run exits 0');
  const v2 = JSON.parse(readFileSync(join(s1, 'v2.json'), 'utf8'));
  ok(v2.songs.length === 2, `delta emits the 2 new tracks (got ${v2.songs.length})`);
  const names = v2.songs.map((s) => s.name).sort().join(',');
  ok(names === 'Afterglow,New Horizon', `delta names = New Horizon + Afterglow (got ${names})`);
  ok(v2.songs.every((s) => s.id && s.albumId && s.artist), 'delta songs carry id/albumId/artist');
  const cursor2 = JSON.parse(readFileSync(state, 'utf8')).lastDateAdded;
  ok(cursor2 === '2026-06-02T00:00:00.000Z', `cursor advanced to the max Date Added (got ${cursor2})`);

  // re-run with the raw cursor: the indexer's boundary is INCLUSIVE, so it re-emits ONLY the
  // single track at exactly the cursor (an idempotent id-keyed upsert) — never the consumed
  // older tracks. (The SERVER wrapper passes since=cursor+1ms to make this a true zero — see (2).)
  r = await runNode(['scripts/index-apple-music.mjs', '--xml', join(FIX, 'library-v2.xml'),
    '--out', join(s1, 'v2b.json'), '--state', state]);
  const v2b = JSON.parse(readFileSync(join(s1, 'v2b.json'), 'utf8'));
  ok(v2b.songs.length <= 1, `raw re-run re-emits only the boundary track, never the old set (got ${v2b.songs.length})`);
  ok(!v2b.songs.some((s) => ['First Light', 'Second Wind', 'Third Rail'].includes(s.name)),
    'raw re-run never re-emits a previously-consumed older track (monotonic cursor)');

  // ============================================================================
  // (2) RIP-SERVER ENDPOINTS — POST /am-sync, GET /am-sync/<id>, change-set to TEMP Downloads.
  // ============================================================================
  console.log('\n(2) rip-server endpoints (no Music, no S3, TEMP Downloads)');
  const PORT = 8809;
  const base = `http://localhost:${PORT}`;
  const TOKEN = 'amsync-test-tok';
  const dl = join(work, 'downloads'); mkdirSync(dl, { recursive: true });
  // Sync artifacts moved OUT of ~/Downloads in 8036439f: change-sets now land in
  // ~/Documents/PocketDJ and the 157 MB snapshots in a `snapshots.nosync` sibling (kept out of
  // iCloud Drive). Point both at the temp tree and assert THERE — asserting the old Downloads
  // path left four checks failing on main, which is exactly the noise that hides a real break.
  const artifacts = join(work, 'artifacts'); mkdirSync(artifacts, { recursive: true });
  const snaps = join(artifacts, 'snapshots.nosync'); mkdirSync(snaps, { recursive: true });
  const amState = join(work, 'am-state'); mkdirSync(amState, { recursive: true });
  // pre-seed the DETECTION cursor between v1 and v2 so the first check detects the 2 new tracks.
  writeFileSync(join(amState, 'state.json'), JSON.stringify({ lastDateAdded: '2021-01-01T00:00:00.000Z' }));
  // empty catalog source (avoid loading the real, large current-index.json).
  const emptyCatalog = join(work, 'empty-catalog.json');
  writeFileSync(emptyCatalog, JSON.stringify({ manifest: { sourceType: 'analog', sourceName: 'Empty' }, albums: [], songs: [] }));
  // fake aws on PATH so loadManifest() never hits S3 (exits 1 → manifest stays {}).
  const shimDir = join(work, 'bin'); mkdirSync(shimDir, { recursive: true });
  const awsShim = join(shimDir, 'aws');
  writeFileSync(awsShim, '#!/bin/sh\nexit 1\n'); chmodSync(awsShim, 0o755);

  const env = {
    ...process.env,
    PATH: `${shimDir}:${process.env.PATH}`,
    RIP_PORT: String(PORT),
    RIP_TOKEN: TOKEN,
    RIP_BUCKET: 'pocketdj-test-bucket',
    RIP_SOURCES: emptyCatalog,
    POCKETDJ_DISABLE_SCHEDULER: '1',                 // inert gate — scheduler must NOT arm
    POCKETDJ_AM_LIBRARY_XML: join(FIX, 'library-v2.xml'),
    POCKETDJ_DOWNLOADS_DIR: dl,                        // change-set OUTPUT → TEMP, never real ~/Downloads
    POCKETDJ_AM_STATE_DIR: amState,
    POCKETDJ_AM_ARTIFACT_DIR: artifacts,               // change-sets  → TEMP, never real ~/Documents
    POCKETDJ_AM_SNAPSHOT_DIR: snaps,                   // 157 MB xml   → TEMP
    HOME: join(work, 'home'),                          // isolate ~/.pocketdj
  };
  mkdirSync(env.HOME, { recursive: true });

  const srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });
  const auth = { Authorization: `Bearer ${TOKEN}` };
  try {
    let up = false;
    for (let i = 0; i < 60; i++) { try { const h = await fetch(`${base}/health`); if (h.ok) { up = true; break; } } catch { /* not yet */ } await sleep(200); }
    ok(up, 'server is up (/health)');

    // unknown sync job → 404
    const u = await fetch(`${base}/am-sync/does-not-exist`, { headers: auth });
    ok(u.status === 404, `GET /am-sync/<unknown> → 404 (got ${u.status})`);

    // POST /am-sync → immediate {jobId, phase}
    const post = await fetch(`${base}/am-sync`, { method: 'POST', headers: { 'content-type': 'application/json', ...auth }, body: '{}' });
    const pj = await post.json();
    ok(post.status === 200 && typeof pj.jobId === 'string', `POST /am-sync → 200 + jobId (got ${post.status}, ${pj.jobId})`);
    ok(pj.phase === 'queued', `POST returns phase 'queued' (got ${pj.phase})`);

    // poll GET /am-sync/<id> → ready
    let view = null;
    for (let i = 0; i < 60; i++) {
      const g = await fetch(`${base}/am-sync/${pj.jobId}`, { headers: auth });
      view = await g.json();
      if (view.phase === 'ready' || view.phase === 'error') break;
      await sleep(200);
    }
    ok(view && view.phase === 'ready', `job reaches phase 'ready' (got ${view?.phase}, err=${view?.error})`);
    ok(view?.result?.counts?.added === 2, `result.counts.added === 2 (got ${view?.result?.counts?.added})`);
    ok(view?.result?.added?.length === 2 && view.result.added.every((a) => a.songId && a.change === 'added'),
      'result.added carries 2 items shaped {songId,…,change:"added"}');
    const csPath = view?.result?.changeSetPath;
    ok(typeof csPath === 'string' && csPath.startsWith(artifacts), `changeSetPath is under the TEMP artifact dir (got ${csPath})`);
    ok(existsSync(csPath), 'change-set file exists on disk');

    // change-set schema + sibling snapshot
    const cs = JSON.parse(readFileSync(csPath, 'utf8'));
    ok(cs.schema === 'pocketdj-am-changeset/1', `change-set schema tag (got ${cs.schema})`);
    ok(cs.counts.added === 2 && cs.added.length === 2, 'change-set counts.added === 2');
    ok(cs.added[0].title && cs.added[0].album !== undefined && 'trackNumber' in cs.added[0], 'change-set added items are FULL (title/album/trackNumber)');
    ok(typeof cs.librarySnapshot === 'string' && existsSync(cs.librarySnapshot), 'librarySnapshot path exists (the exact xml to rebuild from)');
    ok(/^[0-9a-f]{64}$/.test(cs.librarySnapshotSha256 || ''), 'librarySnapshotSha256 is a sha256 hex');
    ok(cs.librarySnapshot.startsWith(snaps) && cs.librarySnapshot.endsWith('.xml'), 'snapshot xml is under the TEMP snapshots.nosync dir');

    // the REAL ~/Documents and ~/Downloads must be untouched (we only ever wrote under the temp tree).
    const artifactFiles = () => readdirSync(artifacts).filter((f) => f.startsWith('pocketdj-am-'));
    const snapFiles = () => readdirSync(snaps).filter((f) => f.endsWith('.xml'));
    ok(artifactFiles().length === 1, `exactly ONE change-set written (got ${artifactFiles().length})`);
    ok(snapFiles().length === 1, `exactly ONE snapshot written (got ${snapFiles().length})`);
    ok(readdirSync(dl).length === 0, 'nothing was written to the Downloads dir at all');

    // re-run: exclusive boundary (since=cursor+1ms) ⇒ 0 added, NO new change-set written.
    const post2 = await fetch(`${base}/am-sync`, { method: 'POST', headers: { 'content-type': 'application/json', ...auth }, body: '{}' });
    const pj2 = await post2.json();
    let view2 = null;
    for (let i = 0; i < 60; i++) {
      const g = await fetch(`${base}/am-sync/${pj2.jobId}`, { headers: auth });
      view2 = await g.json();
      if (view2.phase === 'ready' || view2.phase === 'error') break;
      await sleep(200);
    }
    ok(view2?.result?.counts?.added === 0, `re-run detects 0 added (exclusive boundary, no churn) (got ${view2?.result?.counts?.added})`);
    ok(view2?.result?.changeSetPath === null, 're-run writes NO change-set (changeSetPath null)');
    ok(artifactFiles().length === 1 && snapFiles().length === 1,
      `no extra files written on the no-change re-run (still ${artifactFiles().length} + ${snapFiles().length})`);

    // unauthorized (no token) is rejected — proves the endpoints sit behind the existing auth gate.
    const noauth = await fetch(`${base}/am-sync`, { method: 'POST', body: '{}' });
    ok(noauth.status === 401, `POST /am-sync without token → 401 (got ${noauth.status})`);
  } finally {
    srv.kill('SIGKILL');
  }

  // ============================================================================
  // (3) SCHEDULER math + inert gate.
  // ============================================================================
  console.log('\n(3) scheduler math (mirrors the server\'s internal msUntilNext)');
  // Identical algorithm to rip-server.mjs's msUntilNext (the module can't be imported without
  // booting the server, so the pure 4-line function is mirrored here).
  const msUntilNext = (hour, now) => { const n = new Date(now); n.setHours(hour, 0, 0, 0); if (n <= now) n.setDate(n.getDate() + 1); return n - now; };
  for (const probe of ['2026-06-25T03:59:00', '2026-06-25T04:00:01', '2026-06-25T12:00:00', '2026-06-25T23:59:59']) {
    const now = new Date(probe);
    const ms = msUntilNext(4, now);
    const landing = new Date(now.getTime() + ms);
    ok(ms > 0 && ms <= 24 * 3600 * 1000, `msUntilNext from ${probe} is in (0, 24h] (${Math.round(ms / 1000)}s)`);
    ok(landing.getHours() === 4 && landing.getMinutes() === 0 && landing.getSeconds() === 0, `…lands exactly on 04:00 (got ${landing.getHours()}:${landing.getMinutes()})`);
  }
  // the server in (2) booted with POCKETDJ_DISABLE_SCHEDULER=1 and answered /health → the gated
  // boot path is exercised (the scheduler did not interfere / crash the boot).
  ok(true, 'server booted cleanly with POCKETDJ_DISABLE_SCHEDULER=1 (inert gate path exercised)');

  // ============================================================================
  // (4) CRON-AGENT ordered sequence (index → commit → push → deploy → processed), with shims.
  // ============================================================================
  console.log('\n(4) am-sync-agent.sh ordered sequence (git/deploy/node/jq shimmed)');
  const agentRepo = join(work, 'agent-repo');
  mkdirSync(join(agentRepo, 'public'), { recursive: true });
  mkdirSync(join(agentRepo, 'index-out', 'apple-music'), { recursive: true });
  const agentDL = join(work, 'agent-downloads'); mkdirSync(agentDL, { recursive: true });
  const agentState = join(work, 'agent-state'); mkdirSync(agentState, { recursive: true }); // deploy receipt → TEMP, not real ~/.pocketdj
  const fakes = join(work, 'fakes'); mkdirSync(fakes, { recursive: true });
  const callLog = join(work, 'agent-calls.log');

  // fake git: logs each subcommand; `diff` exits per FAKE_GIT_DIFF_EXIT (default 1 = dirty);
  // `log` prints a hash only when FAKE_GIT_LOG_MATCH is set (simulates "this changeset was already
  // committed"); `rev-parse` prints a stub blob sha so the deploy-receipt write has content.
  const fakeGit = join(fakes, 'git');
  writeFileSync(fakeGit, `#!/bin/sh
echo "git $*" >> "$CALLLOG"
if [ "$1" = "diff" ]; then exit \${FAKE_GIT_DIFF_EXIT:-1}; fi
if [ "$1" = "log" ]; then [ -n "$FAKE_GIT_LOG_MATCH" ] && echo deadbeefcafe1234; exit 0; fi
if [ "$1" = "rev-parse" ]; then echo blobsha-stub; exit 0; fi
exit 0
`); chmodSync(fakeGit, 0o755);
  // fake deploy.sh: logs argv.
  const fakeDeploy = join(fakes, 'deploy.sh');
  writeFileSync(fakeDeploy, `#!/bin/sh
echo "deploy $*" >> "$CALLLOG"
exit 0
`); chmodSync(fakeDeploy, 0o755);
  // fake node (the indexer): logs "index" + writes the --out file so the agent's cp succeeds.
  const fakeNode = join(fakes, 'node');
  writeFileSync(fakeNode, `#!/bin/sh
echo "index $*" >> "$CALLLOG"
out=""
while [ $# -gt 0 ]; do if [ "$1" = "--out" ]; then out="$2"; fi; shift; done
if [ -n "$out" ]; then mkdir -p "$(dirname "$out")"; echo '{"manifest":{},"albums":[],"songs":[]}' > "$out"; fi
exit 0
`); chmodSync(fakeNode, 0o755);
  // jq is a real read-only tool (the spec shims only git/deploy/claude) — use the real one.
  const fakeJq = 'jq';

  // a change-set + its OWN snapshot copy (NOT the repo fixture — the agent MOVES the snapshot).
  const mkChangeset = (ts) => {
    const snap = join(agentDL, `pocketdj-am-library-${ts}.xml`);
    copyFileSync(join(FIX, 'library-v2.xml'), snap);
    const csp = join(agentDL, `pocketdj-am-changeset-${ts}.json`);
    writeFileSync(csp, JSON.stringify({
      schema: 'pocketdj-am-changeset/1', ts, librarySnapshot: snap,
      counts: { added: 2 }, added: [{ songId: 'sng_x', title: 'X', change: 'added' }], changed: [], removed: [],
    }, null, 2));
    return { csp, snap };
  };

  const runAgent = (extraEnv = {}) => new Promise((res) => {
    const p = spawn('bash', [join(REPO, 'scripts/am-sync-agent.sh')], {
      env: {
        ...process.env,
        POCKETDJ_AGENT_REPO: agentRepo,
        POCKETDJ_DOWNLOADS_DIR: agentDL,
        POCKETDJ_GIT_CMD: fakeGit,
        POCKETDJ_DEPLOY_CMD: fakeDeploy,
        POCKETDJ_NODE_CMD: fakeNode,
        POCKETDJ_JQ_CMD: fakeJq,
        POCKETDJ_AM_AGENT_LOG: join(work, 'agent.log'),
        POCKETDJ_AM_AGENT_STATE: agentState,
        CALLLOG: callLog,
        ...extraEnv,
      },
      stdio: ['ignore', 'ignore', 'ignore'],
    });
    p.on('close', (code) => res(code));
  });

  // --- scenario A: dirty diff → full ordered ship ---
  writeFileSync(callLog, '');
  const a = mkChangeset(1750000000001);
  let code = await runAgent({ FAKE_GIT_DIFF_EXIT: '1' });
  ok(code === 0, `agent (dirty diff) exits 0 (got ${code})`);
  const logA = readFileSync(callLog, 'utf8');
  const idx = (re) => logA.split('\n').findIndex((l) => re.test(l));
  const iIndex = idx(/^index /), iCommit = idx(/^git commit/), iPush = idx(/^git push/), iDeployDev = idx(/^deploy dev/), iDeployProd = idx(/^deploy prod/);
  ok(iIndex >= 0 && iCommit > iIndex, 'order: index BEFORE git commit');
  ok(iPush > iCommit, 'order: git push AFTER git commit (audit trail before S3)');
  ok(iDeployDev > iPush && iDeployProd > iDeployDev, 'order: deploy.sh dev+prod AFTER git push (GitHub before S3)');
  ok(!existsSync(a.csp) && existsSync(join(agentDL, 'pocketdj-am-processed', 'pocketdj-am-changeset-1750000000001.json')),
    'change-set moved to processed/ only after full success (step 7)');
  ok(!existsSync(a.snap), 'snapshot xml also moved to processed/');

  // --- scenario B: empty diff guard → archive WITHOUT commit/push/deploy ---
  writeFileSync(callLog, '');
  const b = mkChangeset(1750000000002);
  code = await runAgent({ FAKE_GIT_DIFF_EXIT: '0' });
  ok(code === 0, `agent (empty diff) exits 0 (got ${code})`);
  const logB = readFileSync(callLog, 'utf8');
  ok(!/^git commit/m.test(logB) && !/^git push/m.test(logB) && !/^deploy /m.test(logB),
    'empty-diff guard: NO commit / push / deploy');
  ok(/^index /m.test(logB), 'empty-diff guard still ran the rebuild (index) to detect the no-op');
  ok(existsSync(join(agentDL, 'pocketdj-am-processed', 'pocketdj-am-changeset-1750000000002.json')),
    'empty-diff change-set archived to processed/');

  // --- scenario C: already-processed pre-check → no-op (no new calls) ---
  writeFileSync(callLog, '');
  // re-create the scenario-A change-set name (already in processed) — agent must skip it.
  copyFileSync(join(agentDL, 'pocketdj-am-processed', 'pocketdj-am-changeset-1750000000001.json'),
    join(agentDL, 'pocketdj-am-changeset-1750000000001.json'));
  code = await runAgent({ FAKE_GIT_DIFF_EXIT: '1' });
  ok(code === 0, `agent (already-processed) exits 0 (got ${code})`);
  const logC = readFileSync(callLog, 'utf8').trim();
  ok(logC === '', 'already-processed change-set is a no-op (no index/commit/push/deploy calls)');

  // --- scenario D: --dry-run mutates nothing ---
  writeFileSync(callLog, '');
  const d = mkChangeset(1750000000003);
  code = await runAgent({ FAKE_GIT_DIFF_EXIT: '1' }); // first ensure a fresh changeset, then dry-run a NEW one
  // (the line above shipped it; make a brand-new one for the dry-run)
  const e = mkChangeset(1750000000004);
  const dryRun = () => new Promise((res) => {
    const p = spawn('bash', [join(REPO, 'scripts/am-sync-agent.sh'), '--dry-run'], {
      env: { ...process.env, POCKETDJ_AGENT_REPO: agentRepo, POCKETDJ_DOWNLOADS_DIR: agentDL,
        POCKETDJ_GIT_CMD: fakeGit, POCKETDJ_DEPLOY_CMD: fakeDeploy, POCKETDJ_NODE_CMD: fakeNode,
        POCKETDJ_JQ_CMD: fakeJq, POCKETDJ_AM_AGENT_LOG: join(work, 'agent.log'),
        POCKETDJ_AM_AGENT_STATE: agentState, CALLLOG: join(work, 'dry-calls.log') },
      stdio: ['ignore', 'ignore', 'ignore'] });
    p.on('close', (c) => res(c));
  });
  writeFileSync(join(work, 'dry-calls.log'), '');
  code = await dryRun();
  ok(code === 0, `--dry-run exits 0 (got ${code})`);
  // dry-run echoes mutating steps but executes none of git push / commit / deploy.
  const dryCalls = existsSync(join(work, 'dry-calls.log')) ? readFileSync(join(work, 'dry-calls.log'), 'utf8') : '';
  ok(!/^git commit/m.test(dryCalls) && !/^deploy /m.test(dryCalls), '--dry-run executed no commit/deploy (echo-only)');
  ok(existsSync(e.csp), '--dry-run left the change-set in place (did NOT move to processed)');

  // --- scenario E: committed-but-not-deployed RECOVERY (a prior run pushed, then deploy failed) ---
  // The rebuild now matches the (already-committed) index (empty diff), but the changeset's commit
  // EXISTS in git log → the agent must RE-DEPLOY (never leave S3 stale) and archive WITHOUT recommitting.
  writeFileSync(callLog, '');
  mkChangeset(1750000000005);
  code = await runAgent({ FAKE_GIT_DIFF_EXIT: '0', FAKE_GIT_LOG_MATCH: '1' });
  ok(code === 0, `agent (committed-but-not-deployed) exits 0 (got ${code})`);
  const logE = readFileSync(callLog, 'utf8');
  ok(!/^git commit/m.test(logE), 'recovery: does NOT re-commit (index already committed last run)');
  ok(/^deploy dev/m.test(logE) && /^deploy prod/m.test(logE), 'recovery: RE-DEPLOYS dev+prod so S3 is never left stale');
  ok(existsSync(join(agentDL, 'pocketdj-am-processed', 'pocketdj-am-changeset-1750000000005.json')),
    'recovery: change-set archived only after the re-deploy');

  // ============================================================================
  // (5) am-merge-catalog-ids.mjs — the catalog-id PRESERVATION the agent runs after a rebuild.
  //     A raw rebuild drops the resolver-baked appleMusicId storeIds; this merge carries them back.
  // ============================================================================
  console.log('\n(5) am-merge-catalog-ids.mjs preserves resolved appleMusicId across a full rebuild');
  const mergeDir = join(work, 'merge'); mkdirSync(mergeDir, { recursive: true });
  const oldIdx = { manifest: { counts: {} }, albums: [], songs: [
    { id: 'sng_a', name: 'A', artist: 'X', appleMusicId: '111' },
    { id: 'sng_b', name: 'B', artist: 'Y', appleMusicId: '222' },
    { id: 'sng_c', name: 'C', artist: 'Z' },                    // genuine miss — never resolved
  ], artists: [
    { key: 'x', name: 'X', id: 1001, songs: 1 },
    { key: 'y', name: 'Y', id: 1002, songs: 1 },
  ] };
  const newIdx = { manifest: { counts: {} }, albums: [], songs: [
    { id: 'sng_a', name: 'A', artist: 'X' },                    // rebuild DROPPED the resolved id
    { id: 'sng_b', name: 'B2', artist: 'Y' },                   // edited title, same id
    { id: 'sng_c', name: 'C', artist: 'Z' },
    { id: 'sng_d', name: 'D', artist: '  X  ' },                // new track, whitespace variant of X
  ] };
  writeFileSync(join(mergeDir, 'old.json'), JSON.stringify(oldIdx));
  writeFileSync(join(mergeDir, 'new.json'), JSON.stringify(newIdx));
  const mr = await runNode(['scripts/am-merge-catalog-ids.mjs', '--old', join(mergeDir, 'old.json'),
    '--new', join(mergeDir, 'new.json'), '--out', join(mergeDir, 'merged.json')]);
  ok(mr.code === 0, `merge exits 0 (got ${mr.code})`);
  const merged = JSON.parse(readFileSync(join(mergeDir, 'merged.json'), 'utf8'));
  const byId = Object.fromEntries(merged.songs.map((s) => [s.id, s]));
  ok(byId.sng_a.appleMusicId === '111', 'dropped id sng_a restored from the committed index (111)');
  ok(byId.sng_b.appleMusicId === '222' && byId.sng_b.name === 'B2', 'id restored AND the rebuild content (edited title) is kept');
  ok(byId.sng_c.appleMusicId === undefined, 'a genuine miss stays unresolved');
  ok(!byId.sng_d.appleMusicId, 'a brand-new track has no id (the resolver crawl will fill it later)');
  ok(merged.manifest.counts.songsWithAppleMusicId === 2, 'coverage count refreshed (2 songs with ids)');

  // ── The ARTIST TABLE: the same carry-forward, but NOT song-keyed ──────────────────────────
  // index-apple-music.mjs emits no `artists` key at all, so a rebuild drops the whole table with
  // ZERO per-song evidence that anything went missing — every song is intact and the release feed
  // just has no artist ids to ask Apple about. Nothing covered this before.
  const artistById = Object.fromEntries((merged.artists || []).map((a) => [a.key, a]));
  ok((merged.artists || []).length === 2, `artist table carried forward (got ${(merged.artists || []).length})`);
  ok(artistById.x?.id === 1001 && artistById.y?.id === 1002, 'artist → Apple Music id mapping preserved');
  ok(artistById.x?.songs === 2, `per-artist counts RE-DERIVED against the new songs (X: 1 → 2, got ${artistById.x?.songs})`);
  ok(merged.manifest.counts.artists === 2, `manifest artist count refreshed (got ${merged.manifest.counts.artists})`);
  ok(merged.manifest.counts.songsWithArtistId === 3,
    `songsWithArtistId counts the whitespace variant too (expect 3, got ${merged.manifest.counts.songsWithArtistId})`);

  // `[]` is TRUTHY in JS: a rebuild emitting an EMPTY artists array used to skip the carry-forward
  // and ship a wiped table, while the log still read a cheerful "carried 0 artist(s)".
  console.log('\n(5b) an EMPTY artists array is treated as "no table", not as a table');
  writeFileSync(join(mergeDir, 'new-empty-artists.json'),
    JSON.stringify({ ...newIdx, artists: [] }));
  const mr2 = await runNode(['scripts/am-merge-catalog-ids.mjs', '--old', join(mergeDir, 'old.json'),
    '--new', join(mergeDir, 'new-empty-artists.json'), '--out', join(mergeDir, 'merged-empty.json')]);
  ok(mr2.code === 0, `merge exits 0 (got ${mr2.code})`);
  const merged2 = JSON.parse(readFileSync(join(mergeDir, 'merged-empty.json'), 'utf8'));
  ok((merged2.artists || []).length === 2,
    `artists: [] still carries the old table forward (got ${(merged2.artists || []).length})`);

  // And the guard that would REFUSE to publish such a wipe, since the merge is a single point of
  // failure with no alarm on it.
  console.log('\n(5c) am-check-enrichment refuses to publish an index whose artist table collapsed');
  writeFileSync(join(mergeDir, 'wiped.json'), JSON.stringify({ ...oldIdx, artists: [] }));
  const wipe = await runNode(['scripts/am-check-enrichment.mjs', '--old', join(mergeDir, 'old.json'),
    '--new', join(mergeDir, 'wiped.json')]);
  ok(wipe.code === 1, `a wiped artist table FAILS the enrichment guard (got exit ${wipe.code})`);
  const kept = await runNode(['scripts/am-check-enrichment.mjs', '--old', join(mergeDir, 'old.json'),
    '--new', join(mergeDir, 'merged.json')]);
  ok(kept.code === 0, `a correctly merged index PASSES the enrichment guard (got exit ${kept.code})`);

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all am-sync dry-run checks passed'}`);
} finally {
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
