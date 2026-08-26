#!/usr/bin/env node
// PARITY GATE, half 2 — compare the CLOUD vectors against the LOCAL ones axis by axis and decide
// PASS / CONDITIONAL / FAIL. The backfill must not start unless this passes.
//
//   node scripts/timbre-parity-check.mjs [--prefix rips/timbre-parity/] [--json out.json]
//
// WHY THIS IS A GATE AND NOT A REPORT: 12,395 existing vectors were measured on the Mac and every
// similarity comparison happens in ONE space. A cloud vector that is merely "close" silently
// corrupts every comparison involving a cloud-analysed song — and the corruption is invisible,
// because nothing in the corpus records which machine produced a row.
//
// THE TWO ARMS OF THE GATE (both are checked, because either alone is a null verifier):
//   · MAGNITUDE — max |Δ| ≤ 1e-4, one unit in the last place of the engine's own round(…,4).
//     Rounding-boundary ties are the only legitimate source of a difference that small.
//   · BIAS — the SIGNED mean Δ must be ~0 and the MEDIAN |Δ| must be 0 on every axis. A
//     systematic 1e-4 in one direction is a recalibrated stack, not float noise, and "max ≤ 1e-4"
//     alone would wave it through.
// A null↔number flip is an automatic FAIL: it means an axis stopped being computed at all.
import { readFileSync, readdirSync, existsSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { TIMBRE_VERSION } from './lib/audio-analyze.mjs';

const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const PREFIX = arg('--prefix', 'rips/timbre-parity/');
const BUCKET = process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623';
const REGION = process.env.AWS_REGION || 'us-west-2';
const PROFILE = process.env.AWS_PROFILE || 'levi';
const RESULTS = join(homedir(), '.pocketdj', 'timbre-batch', 'results');
export const EPS = 1e-4;

const median = (xs) => { if (!xs.length) return 0; const a = [...xs].sort((x, y) => x - y); const m = a.length >> 1; return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2; };

/// PURE COMPARATOR — the whole gate, so it can be unit-tested without S3.
/// local/cloud: Map(id -> f). Returns {axes, verdict, …}.
export function compareVectors(local, cloud) {
  const axes = {};
  let compared = 0; let missing = 0; let flips = 0;
  for (const [id, lf] of local) {
    const cf = cloud.get(id);
    if (!cf) { missing += 1; continue; }
    compared += 1;
    for (const k of Object.keys(lf)) {
      const a = axes[k] || (axes[k] = { n: 0, differing: 0, deltas: [], signed: [], max: 0, flips: 0 });
      const lv = lf[k]; const cv = cf[k];
      a.n += 1;
      if ((lv == null) !== (cv == null)) { a.flips += 1; flips += 1; continue; }
      if (lv == null) continue;
      const d = cv - lv;
      const ad = Math.abs(d);
      a.signed.push(d);
      a.deltas.push(ad);
      if (ad > 0) a.differing += 1;
      if (ad > a.max) a.max = ad;
    }
  }
  let worstMax = 0; let anyMedian = false; let anyBias = false;
  for (const [, a] of Object.entries(axes)) {
    a.median = median(a.deltas);
    a.meanSigned = a.signed.length ? a.signed.reduce((x, y) => x + y, 0) / a.signed.length : 0;
    if (a.max > worstMax) worstMax = a.max;
    if (a.median > 0) anyMedian = true;
    // Bias: a mean displacement more than a tenth of EPS with essentially every sample on one
    // side is a shifted calibration, not rounding noise.
    if (Math.abs(a.meanSigned) > EPS / 10 && a.differing > a.n / 2) anyBias = true;
  }
  const totalAxisValues = compared * Object.keys(axes).length;
  const differingValues = Object.values(axes).reduce((s, a) => s + a.differing, 0);
  let verdict;
  if (flips > 0 || worstMax > EPS || anyMedian || anyBias) verdict = 'FAIL';
  else if (worstMax === 0) verdict = 'PASS';
  else if (differingValues / Math.max(1, totalAxisValues) < 0.01) verdict = 'CONDITIONAL';
  else verdict = 'FAIL';
  return { verdict, compared, missing, flips, worstMax, differingValues, totalAxisValues, axes };
}

function loadLocal(ids) {
  const want = new Set(ids);
  const out = new Map();
  for (const f of readdirSync(RESULTS).sort()) {
    if (!f.endsWith('.ndjson')) continue;
    for (const line of readFileSync(join(RESULTS, f), 'utf8').split('\n')) {
      if (!line.trim()) continue;
      let r; try { r = JSON.parse(line); } catch { continue; }
      if (r.ok && r.f && want.has(r.id)) out.set(r.id, r.f);
    }
  }
  return out;
}

function main() {
  const samplePath = join(homedir(), '.pocketdj', 'timbre-batch', 'parity-sample.json');
  const sample = existsSync(samplePath) ? JSON.parse(readFileSync(samplePath, 'utf8')) : null;
  const dir = mkdtempSync(join(tmpdir(), 'parity-'));
  try {
    execFileSync('aws', ['s3', 'sync', `s3://${BUCKET}/${PREFIX}v${TIMBRE_VERSION}/`, dir,
      '--region', REGION, '--profile', PROFILE, '--only-show-errors'], { stdio: 'inherit' });
    const cloud = new Map(); const cloudDur = new Map();
    for (const f of readdirSync(dir)) {
      if (!f.endsWith('.json')) continue;
      const r = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      if (r.ok && r.f) { cloud.set(r.id, r.f); if (r.durationSec != null) cloudDur.set(r.id, r.durationSec); }
    }
    const ids = sample ? sample.ids : [...cloud.keys()];
    const local = loadLocal(ids);
    const res = compareVectors(local, cloud);
    const rows = Object.entries(res.axes).sort(([a], [b]) => (a < b ? -1 : 1))
      .map(([k, a]) => `  ${k.padEnd(10)} differing ${String(a.differing).padStart(4)}/${String(a.n).padStart(4)}  max|Δ| ${a.max.toExponential(2)}  median|Δ| ${a.median.toExponential(2)}  meanΔ ${a.meanSigned.toExponential(2)}${a.flips ? `  FLIPS ${a.flips}` : ''}`);
    console.log(`PARITY ${res.verdict} — ${res.compared} songs compared, ${res.missing} missing from cloud, `
      + `${res.differingValues}/${res.totalAxisValues} axis-values differ, worst |Δ| ${res.worstMax.toExponential(2)}`);
    console.log(rows.join('\n'));
    const outJson = arg('--json', null);
    if (outJson) writeFileSync(outJson, JSON.stringify(res, null, 1));
    if (res.verdict === 'FAIL') process.exit(1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

if (process.argv[1] && process.argv[1].endsWith('timbre-parity-check.mjs')) main();
