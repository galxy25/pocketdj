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
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { loadLibraryXML, indexLibrary, findInLibrary } from './lib/am-match.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, '..');
const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);
const sha1 = (s) => createHash('sha1').update(s).digest('hex');

// Apple Music (Local) namespace — must match scripts/index-apple-music.mjs (ns =
// `digital|${sourceName}`; songId = 'sng_' + sha1(`${ns}|${persistentID}`)[:12]).
const AM_SOURCE_NAME = 'Apple Music (Local)';
const amSongId = (persistentID) =>
  'sng_' + sha1(`digital|${AM_SOURCE_NAME}|${persistentID}`).slice(0, 12);

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

// A manifest entry is a CLOUD source of truth only if it is a digital rip that has
// been analyzed (analog entries deliberately keep the catalog's suspect bpm/key).
const isCloudEntry = (e) => !!e && e.source === 'digital' && e.analyzed === true;

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
  const report = {
    generatedAt: new Date().toISOString(),
    inputs: { index: indexPath, libraryXml: xmlPath, manifest: manifestSrc, limit: args.limit || null },
    totals: { songsConsidered: n, totalSongs: songs.length },
    matched: 0,
    matchExact: 0,
    matchLoose: 0,      // counted but NOT applied
    matchNone: 0,
    lengthUpdated: 0,
    lengthAdded: 0,     // rows that had no length before
    bpmKeyUpdatedFromCloud: 0,
    cloudEntriesUsed: 0,
    matchedNoValue: 0,  // exact AM match but nothing to write (no Total Time, no cloud rip)
    unmatched: 0,       // no exact AM match (loose + none)
    // length-delta breakdown — surfaces the matcher-looseness bug (a recording variant
    // matching the standard recording overwrites length by a large margin).
    lengthDelta: {
      gt60s: 0,         // |after - before| > 60s — the symptom the fix targets
      gt30s: 0,         // 30s < |delta| <= 60s
      le30s: 0,         // 0 < |delta| <= 30s
      newlyAdded: 0,    // had no length before (delta undefined)
    },
    lengthDeltaGt60sSamples: [], // before/after for every >60s change (capped)
    samples: [],
  };

  for (let i = 0; i < n; i++) {
    const song = songs[i];
    const r = findInLibrary(lib, song.artist, song.name);

    if (r.match !== 'exact') {
      if (r.match === 'loose') report.matchLoose++; else report.matchNone++;
      report.unmatched++;
      continue;
    }
    report.matched++;
    report.matchExact++;

    const before = { length: song.length ?? null, bpm: song.bpm ?? null, key: song.key ?? null, camelot: song.camelot ?? null };
    // Provenance carries NO wall-clock so the catalog output is byte-idempotent
    // (re-running yields an identical current-index.json). The run timestamp lives
    // only in the report + index.manifest.cloudReindex (audit artifacts).
    const prov = { persistentID: r.hit.persistentID || null, fields: [] };

    // LENGTH — cloud (Apple Music Total Time) overrides analog length. Guard on a
    // real ms value (a library entry can lack Total Time for streaming-only tracks).
    if (r.hit.lengthMs != null && Number.isFinite(r.hit.lengthMs) && r.hit.lengthMs > 0) {
      const had = song.length != null;
      const prevLength = song.length;
      if (song.length !== r.hit.lengthMs) {
        song.length = r.hit.lengthMs;
        report.lengthUpdated++;
        if (!had) report.lengthAdded++;
        // delta breakdown (only meaningful when a previous length existed)
        if (had) {
          const deltaMs = Math.abs(r.hit.lengthMs - prevLength);
          const deltaS = deltaMs / 1000;
          if (deltaS > 60) {
            report.lengthDelta.gt60s++;
            if (report.lengthDeltaGt60sSamples.length < 200) {
              report.lengthDeltaGt60sSamples.push({
                id: song.id, artist: song.artist, name: song.name,
                amTitle: r.hit.title, persistentID: r.hit.persistentID || null,
                beforeMs: prevLength, afterMs: r.hit.lengthMs,
                deltaS: Math.round(deltaS),
              });
            }
          } else if (deltaS > 30) report.lengthDelta.gt30s++;
          else report.lengthDelta.le30s++;
        } else {
          report.lengthDelta.newlyAdded++;
        }
      } else if (!had) {
        song.length = r.hit.lengthMs;
      }
      prov.length = r.hit.lengthMs;
      prov.fields.push('length');
    }

    // BPM/KEY/CAMELOT — opportunistic, from a digital+analyzed cloud rip. Two sources,
    // in precedence order: (a) a cloud rip of THIS song itself — e.g. "Rip from cloud
    // source" of this analog/vinyl track, whose manifest entry is keyed by the song's
    // OWN id; (b) a separately-ripped DIGITAL copy of the matched Apple Music track,
    // keyed by the derived am songId. manifest.musicalKey -> catalog key.
    const derivedId = r.hit.persistentID ? amSongId(r.hit.persistentID) : null;
    const cloudSongId = isCloudEntry(manifest[song.id]) ? song.id
      : (derivedId && isCloudEntry(manifest[derivedId]) ? derivedId : null);
    if (cloudSongId) {
      const e = manifest[cloudSongId];
      let touched = false;
      if (e.bpm != null) { song.bpm = e.bpm; prov.fields.push('bpm'); touched = true; }
      if (e.musicalKey != null) { song.key = e.musicalKey; prov.fields.push('key'); touched = true; }
      if (e.camelot != null) { song.camelot = e.camelot; prov.fields.push('camelot'); touched = true; }
      if (touched) {
        report.bpmKeyUpdatedFromCloud++;
        report.cloudEntriesUsed++;
        prov.cloudSongId = cloudSongId;
      }
    }

    if (prov.fields.length) {
      song.cloudReindex = prov; // idempotent provenance stamp (overwritten each run)
      if (report.samples.length < 25) {
        report.samples.push({
          id: song.id,
          artist: song.artist,
          name: song.name,
          fields: prov.fields,
          before,
          after: { length: song.length ?? null, bpm: song.bpm ?? null, key: song.key ?? null, camelot: song.camelot ?? null },
          persistentID: prov.persistentID,
        });
      }
    } else {
      // exact match but nothing to write (no Total Time, no cloud rip)
      report.matchedNoValue++;
    }
  }

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
