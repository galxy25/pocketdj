#!/usr/bin/env node
// End-to-end test of the Stemify endpoints — POST /stemify, /stemify-collection,
// /stemify-cancel, /backfill-stems — on the REAL rip-server, with zero network and zero
// real Demucs. A fake `aws` shim (seeded manifest + materialized downloads + no-op uploads)
// and a fake native "venv python" that fabricates the 4 stem files + prints the one JSON
// line separate-one.py would. Asserts:
//   (a) /health advertises stems:true
//   (b) /stemify unknown songId → 404
//   (c) /stemify an already-ripped DIGITAL song → job runs queued→stemming→ready, and the
//       manifest entry gains stems{vocals,drums,bass,other} + stemModel + stemVersion
//   (d) idempotent skip: a 2nd /stemify on the now-stemmed song → phase 'ready' immediately
//   (e) round-trip idempotency: /backfill-stems candidates EXCLUDES the just-stemmed song
//       (proves the writer/predicate field names agree — the corpus-re-stem guard)
//   (f) analog song with NO cut + NO derivable boundaries → 'ineligible' (never a zombie)
//   (g) /stemify-collection over the cap WITHOUT confirmLarge → needsConfirm (no huge job)
//
//   node scripts/test/stemify-e2e.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync, mkdirSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8804;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://localhost:${PORT}`;
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-stem-'));

// ---- catalog: a ripped digital song, + an analog song with NO boundaries (ineligible) ----
const DIGITAL = 'sng_digital_ripped';
const ANALOG_NOCUT = 'sng_analog_noboundary';
const UNKNOWN = 'sng_missing';
const digitalCatalog = join(work, 'digital.json');
writeFileSync(digitalCatalog, JSON.stringify({
  manifest: { sourceType: 'digital', sourceName: 'Test' },
  albums: [{ id: 'alb_dig', artist: 'Digi', name: 'Digital Album', trackList: [DIGITAL] }],
  songs: [{ id: DIGITAL, albumId: 'alb_dig', artist: 'Digi', name: 'Digital Ripped', length: 6000 }],
}));
const analogCatalog = join(work, 'analog.json');
writeFileSync(analogCatalog, JSON.stringify({
  manifest: { sourceType: 'analog', sourceName: 'Vinyl' },
  albums: [{ id: 'alb_analog', artist: 'Vinyl', name: 'Analog Album',
    pointer: { originalFilename: 'nope.flac' }, trackList: [ANALOG_NOCUT] }],
  // NO pointer.startMs / endMs and NO length → cutDurationMs null → cutImpossible → ineligible
  songs: [{ id: ANALOG_NOCUT, albumId: 'alb_analog', artist: 'Vinyl', name: 'No Boundary' }],
}));

// ---- seeded manifest: the digital song is already ripped; the analog song is album-ripped
//      (has key, NO cutKey) so it classifies as ineligible (no derivable per-song cut). ----
const seedManifest = join(work, 'seed-manifest.json');
writeFileSync(seedManifest, JSON.stringify({
  [DIGITAL]: { key: `rips/${DIGITAL}.mp3`, ext: 'mp3', bytes: 100000, source: 'digital', albumId: 'alb_dig', startMs: null, durationMs: 6000, rippedAt: 1700000000000, analyzed: true },
  [ANALOG_NOCUT]: { key: 'rips/alb_analog.mp3', ext: 'mp3', bytes: 200000, source: 'analog', albumId: 'alb_analog', startMs: null, durationMs: null, rippedAt: 1700000000000, analyzed: true },
}));

// ---- fake `aws`: manifest read → seed; download (s3://→local) → write bytes so the lib's
//      copyFileSync succeeds; upload (local→s3://) → no-op. ----
const shimDir = join(work, 'bin');
mkdirSync(shimDir, { recursive: true });
const awsShim = join(shimDir, 'aws');
writeFileSync(awsShim, `#!/usr/bin/env node
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
const a = process.argv.slice(2).filter((x, i, arr) => !(x === '--profile' || x === '--region' || arr[i-1] === '--profile' || arr[i-1] === '--region') && x !== '--content-type' && arr[i-1] !== '--content-type');
if (a[0] === 's3' && a[1] === 'cp') {
  const src = a[2], dst = a[3];
  if (dst === '-' && /\\/rips\\/manifest\\.json$/.test(src || '')) {
    const seed = ${JSON.stringify(seedManifest)};
    process.stdout.write(existsSync(seed) ? readFileSync(seed, 'utf8') : '{}');
    process.exit(0);
  }
  if (String(src).startsWith('s3://') && !String(dst).startsWith('s3://') && dst !== '-') {
    try { writeFileSync(dst, 'FAKEAUDIO'); } catch {}
    process.exit(0);
  }
  process.exit(0); // upload no-op
}
process.exit(0);
`);
chmodSync(awsShim, 0o755);

// ---- fake native "venv python": separateStems spawns <venv>/bin/python <separate-one.py> <song.mp3>.
//      Ignore separate-one.py; fabricate out/<model>/song/{4 stems}.mp3 and print the JSON line. ----
const venv = join(work, 'venv');
mkdirSync(join(venv, 'bin'), { recursive: true });
const fakePy = join(venv, 'bin', 'python');
writeFileSync(fakePy, `#!/bin/sh
# $1 = separate-one.py (ignored), $2 = .../song.mp3
SONG="$2"
WORK=$(dirname "$SONG")
MODEL=\${STEM_MODEL:-htdemucs}
OUT="$WORK/out/$MODEL/song"
mkdir -p "$OUT"
for s in vocals drums bass other; do printf 'STEM' > "$OUT/$s.mp3"; done
printf '{"ok":true,"model":"%s","stems":{"vocals":"out/%s/song/vocals.mp3","drums":"out/%s/song/drums.mp3","bass":"out/%s/song/bass.mp3","other":"out/%s/song/other.mp3"}}\\n' "$MODEL" "$MODEL" "$MODEL" "$MODEL" "$MODEL"
`);
chmodSync(fakePy, 0o755);

const env = {
  ...process.env,
  PATH: `${shimDir}:${process.env.PATH}`,
  RIP_PORT: String(PORT),
  RIP_BUCKET: 'pocketdj-test-bucket',
  RIP_SOURCES: `${analogCatalog},${digitalCatalog}`,
  FAKE_AWS_MANIFEST: seedManifest,
  HOME: join(work, 'home'), // isolate ~/.pocketdj (jobs + durable stem queue under here)
  POCKETDJ_DEMUCS_RUNTIME: 'native',
  POCKETDJ_STEM_VENV: venv,
  POCKETDJ_STEM_COLLECTION_CAP: '2', // small so (g) trips needsConfirm with 3 ids
  POCKETDJ_DISABLE_SCHEDULER: '1',
};

console.log('booting rip-server (fake aws + fake demucs)…');
const srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });

const postJSON = async (p, body) => {
  const r = await fetch(`${base}${p}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json().catch(() => null) };
};
const getJSON = async (p) => { const r = await fetch(`${base}${p}`); return { status: r.status, body: await r.json().catch(() => null) }; };

try {
  let up = false;
  for (let i = 0; i < 50; i++) { try { const r = await fetch(`${base}/health`); if (r.ok) { up = true; break; } } catch { /* not yet */ } await sleep(200); }
  ok(up, 'server is up (/health)');

  // (a) stems:true
  const health = (await getJSON('/health')).body;
  ok(health?.stems === true, `(a) /health advertises stems:true (got ${health?.stems})`);

  // (b) unknown → 404
  const unk = await postJSON('/stemify', { songId: UNKNOWN });
  ok(unk.status === 404, `(b) /stemify unknown → 404 (got ${unk.status})`);

  // (c) stemify the ripped digital song → poll the job to ready, manifest gains stems
  const s1 = await postJSON('/stemify', { songId: DIGITAL });
  ok(s1.status === 200 && s1.body?.jobId, `(c) /stemify returns a jobId (phase ${s1.body?.phase})`);
  let jph = s1.body?.phase, ready = false;
  for (let i = 0; i < 60; i++) {
    const j = await getJSON(`/jobs/${s1.body.jobId}`);
    jph = j.body?.phase;
    if (jph === 'ready') { ready = true; break; }
    if (jph === 'error' || jph === 'ineligible') break;
    await sleep(200);
  }
  ok(ready, `(c) stem job reached 'ready' (last phase ${jph})`);
  const st = (await getJSON(`/status/${DIGITAL}`)).body;
  const stems = st?.entry?.stems;
  ok(stems && stems.vocals && stems.drums && stems.bass && stems.other,
    `(c) manifest entry gained 4 stem keys (${stems ? Object.keys(stems).join(',') : 'none'})`);
  ok(stems?.vocals === `rips/stems/${DIGITAL}/vocals.mp3`, `(c) deterministic stem key (${stems?.vocals})`);
  ok(st?.entry?.stemModel === 'htdemucs' && st?.entry?.stemVersion === 1,
    `(c) stamped stemModel=${st?.entry?.stemModel} stemVersion=${st?.entry?.stemVersion}`);

  // (d) idempotent skip — a 2nd stemify returns ready immediately, no new job
  const s2 = await postJSON('/stemify', { songId: DIGITAL });
  ok(s2.body?.phase === 'ready' && s2.body?.jobId === null, `(d) re-stemify → ready, no job (phase ${s2.body?.phase})`);

  // (e) round-trip idempotency — backfill candidates EXCLUDE the stemmed song
  const bf = await postJSON('/backfill-stems', {});
  ok(bf.body?.candidates === 0, `(e) /backfill-stems candidates===0 after stemming (got ${bf.body?.candidates})`);

  // (f) analog with no boundaries → ineligible
  const inel = await postJSON('/stemify', { songId: ANALOG_NOCUT });
  ok(inel.body?.phase === 'ineligible', `(f) no-cut analog → ineligible (got ${inel.body?.phase})`);

  // (g) collection over the cap (2) without confirmLarge → needsConfirm
  const big = await postJSON('/stemify-collection', { songIds: [DIGITAL, ANALOG_NOCUT, UNKNOWN] });
  ok(big.body?.needsConfirm === true && big.body?.cap === 2,
    `(g) >cap collection → needsConfirm (count ${big.body?.count}, cap ${big.body?.cap})`);

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all stemify checks passed'}`);
} finally {
  srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
