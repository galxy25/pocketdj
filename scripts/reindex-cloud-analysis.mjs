#!/usr/bin/env node
// reindex-cloud-analysis — durable "cloud source-of-truth" re-index of the ANALOG
// catalog (public/current-index.json) from Apple Music.
//
// WHY: the analog librosa analysis is only ~70% right for LENGTH and ~30% right for
// BPM/KEY. The Apple Music library on the iMac is the source of truth. When an analog
// song EXACTLY matches Apple Music, the cloud value must take PRECEDENCE per field.
//
// WHAT IT DOES, per analog song:
//   1. Resolve an EXACT Apple Music match (scripts/lib/am-match.mjs findInLibrary).
//      Only match === 'exact' is honoured — a loose/ambiguous match must NOT overwrite
//      (a wrong length/key is worse than the analog estimate).
//   2. LENGTH (mass fix, metadata only): set song.length = the library "Total Time"
//      (ms) from the matched entry. No audio capture needed — runs in minutes for the
//      whole catalog. Cloud overrides analog length.
//   3. BPM/KEY/CAMELOT (opportunistic): if the rips manifest has a CLOUD entry
//      (source === 'digital' && analyzed === true) for the matched Apple Music song,
//      override song.bpm / song.key / song.camelot from it (manifest.musicalKey -> key).
//      The manifest is keyed by Apple-Music songIds, so we derive the id from the
//      matched library entry's Persistent ID:
//          sng_ + sha1(`digital|<sourceName>|<persistentID>`)[:12]
//      Re-running later picks up more rows as cloud rips accumulate.
//   When there is no exact cloud match, the existing analog value is kept untouched.
//
// IDEMPOTENT: the output is a deterministic function of (catalog, library, manifest).
// Re-running yields the same result. Each touched song carries a `cloudReindex`
// provenance stamp so the fold is auditable + safe to re-run.
//
// SAFETY: writes to a SIDE output (index-out/reindex/current-index.json by default)
// + a JSON report. It NEVER overwrites public/current-index.json (which is in
// deploy.sh NOCACHE, committed + deployed) and NEVER deploys. The owner reviews +
// applies.
//
// Usage:
//   node scripts/reindex-cloud-analysis.mjs \
//     [--index public/current-index.json] \
//     [--library-xml ~/Downloads/Library.xml] \
//     [--manifest s3|<file>] \
//     [--out index-out/reindex/current-index.json] \
//     [--report index-out/reindex/report.json] \
//     [--limit N]   # smoke: only process the first N analog songs
//
// --manifest s3  fetches s3://<bucket>/rips/manifest.json (aws profile levi); a path
// reads a local manifest json. Default tries the rip-server local cache
// (~/.pocketdj/rips/manifest.json), then s3.

import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { loadLibraryXML, indexLibrary } from './lib/am-match.mjs';
import { foldCloudReindex, isCloudEntry } from './lib/cloud-reindex-fold.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, '..');
const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);

const RIP_BUCKET = process.env.RIP_BUCKET || 'pocketdj-rips-011183829623';
const AWS_PROFILE = process.env.AWS_PROFILE || 'levi';
const AWS_REGION = process.env.AWS_REGION || 'us-west-2';
const LOCAL_MANIFEST_CACHE = join(homedir(), '.pocketdj', 'rips', 'manifest.json');

// ---------- args ----------
function parseArgs(argv) {
  const a = {
    index: join(REPO, 'public/current-index.json'),
    libraryXml: join(homedir(), 'Downloads', 'Library.xml'),
    manifest: '', // '' -> auto (local cache, then s3); 's3' -> force s3; else path
    out: join(REPO, 'index-out/reindex/current-index.json'),
    report: join(REPO, 'index-out/reindex/report.json'),
    limit: 0,
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i];
    if (k === '--index') a.index = next();
    else if (k === '--library-xml') a.libraryXml = next();
    else if (k === '--manifest') a.manifest = next();
    else if (k === '--out') a.out = next();
    else if (k === '--report') a.report = next();
    else if (k === '--limit') a.limit = parseInt(next(), 10) || 0;
    else if (k === '--help' || k === '-h') a.help = true;
  }
  return a;
}

// ---------- manifest ----------
function fetchS3Manifest() {
  const out = execFileSync(
    'aws',
    ['s3', 'cp', `s3://${RIP_BUCKET}/rips/manifest.json`, '-', '--profile', AWS_PROFILE, '--region', AWS_REGION],
    { maxBuffer: 64 * 1024 * 1024 },
  );
  return JSON.parse(out.toString('utf8'));
}
function loadManifest(spec) {
  if (spec === 's3') return { src: 's3', manifest: fetchS3Manifest() };
  if (spec) {
    const p = expand(spec);
    return { src: p, manifest: JSON.parse(readFileSync(p, 'utf8')) };
  }
  // auto: local rip-server cache first, then s3
  if (existsSync(LOCAL_MANIFEST_CACHE)) {
    return { src: LOCAL_MANIFEST_CACHE, manifest: JSON.parse(readFileSync(LOCAL_MANIFEST_CACHE, 'utf8')) };
  }
  return { src: 's3', manifest: fetchS3Manifest() };
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log('Usage: node scripts/reindex-cloud-analysis.mjs [--index f] [--library-xml f] [--manifest s3|f] [--out f] [--report f] [--limit N]');
    process.exit(0);
  }

  const indexPath = expand(args.index);
  const xmlPath = expand(args.libraryXml);
  if (!existsSync(indexPath)) { console.error('index not found:', indexPath); process.exit(1); }
  if (!existsSync(xmlPath)) { console.error('library xml not found:', xmlPath); process.exit(1); }

  console.error(`[reindex] reading catalog ${indexPath}`);
  const index = JSON.parse(readFileSync(indexPath, 'utf8'));
  const songs = index.songs || [];
  if ((index.manifest?.sourceType) !== 'analog') {
    console.error(`[reindex] WARNING: manifest.sourceType is '${index.manifest?.sourceType}', expected 'analog'`);
  }

  console.error(`[reindex] loading library xml ${xmlPath} (this can take a few seconds)`);
  const lib = indexLibrary(loadLibraryXML(xmlPath));
  console.error(`[reindex] library entries: ${lib.count}`);

  const { src: manifestSrc, manifest } = loadManifest(args.manifest);
  const cloudCount = Object.values(manifest).filter(isCloudEntry).length;
  console.error(`[reindex] manifest ${manifestSrc}: ${Object.keys(manifest).length} entries, ${cloudCount} cloud (digital+analyzed)`);

  const n = args.limit > 0 ? Math.min(args.limit, songs.length) : songs.length;
  // The fold itself (exact-match, cloud-precedence, idempotent provenance) is the SHARED
  // pure function the rip-server also runs in-process (ITEM 10). The CLI wraps it with the
  // report envelope (generatedAt/inputs/totals) + the side-output + the index.manifest stamp.
  const report = {
    generatedAt: new Date().toISOString(),
    inputs: { index: indexPath, libraryXml: xmlPath, manifest: manifestSrc, limit: args.limit || null },
    totals: { songsConsidered: n, totalSongs: songs.length },
    ...foldCloudReindex(index, lib, manifest, { limit: args.limit }),
  };

  // stamp the catalog manifest so an applied fold is auditable. Use the newest
  // INPUT mtime (catalog/library/manifest-cache) — a deterministic function of the
  // inputs — not wall-clock, so re-running with the same inputs yields a byte-
  // identical current-index.json (idempotent). The report keeps a real wall-clock.
  const inputMtimes = [indexPath, xmlPath, manifestSrc !== 's3' ? manifestSrc : null]
    .filter((p) => p && existsSync(p))
    .map((p) => statSync(p).mtimeMs);
  const sourceStamp = inputMtimes.length ? new Date(Math.max(...inputMtimes)).toISOString() : null;
  index.manifest = index.manifest || {};
  index.manifest.cloudReindex = {
    generatedAt: sourceStamp,
    library: xmlPath,
    manifest: manifestSrc,
    matched: report.matched,
    lengthUpdated: report.lengthUpdated,
    bpmKeyUpdatedFromCloud: report.bpmKeyUpdatedFromCloud,
    limit: args.limit || null,
  };

  const outPath = expand(args.out);
  const reportPath = expand(args.report);
  mkdirSync(dirname(outPath), { recursive: true });
  mkdirSync(dirname(reportPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(index));
  writeFileSync(reportPath, JSON.stringify(report, null, 2));

  console.error('[reindex] ---- summary ----');
  console.error(`  songs considered:        ${report.totals.songsConsidered} / ${report.totals.totalSongs}`);
  console.error(`  exact matches:           ${report.matchExact}`);
  console.error(`  loose (ignored):         ${report.matchLoose}`);
  console.error(`  no match:                ${report.matchNone}`);
  console.error(`  length updated:          ${report.lengthUpdated} (of which newly added: ${report.lengthAdded})`);
  console.error(`  length delta >60s:       ${report.lengthDelta.gt60s}  (30-60s: ${report.lengthDelta.gt30s}, <=30s: ${report.lengthDelta.le30s}, new: ${report.lengthDelta.newlyAdded})`);
  console.error(`  bpm/key from cloud:      ${report.bpmKeyUpdatedFromCloud}`);
  console.error(`  matched, nothing to write: ${report.matchedNoValue}`);
  console.error(`[reindex] wrote ${outPath}`);
  console.error(`[reindex] wrote ${reportPath}`);
  console.error('[reindex] NOTE: side output only — public/current-index.json was NOT modified and nothing was deployed.');
}

main();
