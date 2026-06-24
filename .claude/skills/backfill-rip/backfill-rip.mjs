#!/usr/bin/env node
// backfill-rip — rip out-of-streaming-catalog songs locally to backfill them.
//
// The Apple Music catalog-id crawl resolves PocketDJ songs → Apple Music storeIds
// (so the app can stream them). Some songs never resolve (storeId === null) — they
// are NOT in the streaming catalog. This skill takes that miss list and tells the
// iMac rip server to LOCAL-RIP each one from Apple Music (real-time Audio Hijack
// capture → S3), backfilling a streamable mp3 for songs that otherwise can't stream.
//
// Worklist: apple-music-catalog-misses.csv at the repo root. Regenerate it from the
// latest crawl outputs with --refresh:
//   misses = catalog-cache.ndjson rows where storeId === null,
//   joined to artist/title/album/year/... from public/apple-music-index.json.
// Otherwise the existing CSV is read as-is.
//
// Action: POST /rip-collection {songIds} to the rip server (default localhost:8787).
// These have no catalog id, so the server local-rips them from Apple Music. The
// server is idempotent (skips songs already in the S3 manifest), so re-running is safe.
//
// Usage: node .claude/skills/backfill-rip/backfill-rip.mjs [flags]
//   (no args)            print usage + summary (total misses, top artists)
//   --refresh            regenerate the CSV from the latest crawl outputs, then proceed
//   --artist <substr>    select misses whose artist contains <substr> (case-insensitive)
//   --album  <substr>    select misses whose album  contains <substr> (case-insensitive)
//   --ids a,b,c          select these exact songIds (comma-separated)
//   --limit N            cap the selection to the first N
//   --all                select every miss
//   --dry-run            preview the selection + counts, no network
//   --watch              after submitting, poll the S3 manifest until the selection finishes
//   --server <url>       rip server base URL (default http://localhost:8787)
//   --token <token>      bearer token (default $RIP_TOKEN)
//   --csv <path>         worklist CSV (default <repo>/apple-music-catalog-misses.csv)
//
// No external deps — Node built-ins only; shells `aws` for the S3 manifest check.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, '..', '..', '..'); // .claude/skills/backfill-rip → repo root

const CFG = {
  csv: join(REPO, 'apple-music-catalog-misses.csv'),
  ndjson: join(REPO, 'index-out', 'apple-music', 'catalog-cache.ndjson'),
  index: join(REPO, 'public', 'apple-music-index.json'),
  server: 'http://localhost:8787',
  token: process.env.RIP_TOKEN || '',
  bucket: 'pocketdj-rips-011183829623',
  awsProfile: 'levi',
};

const CSV_COLS = ['songId', 'artist', 'title', 'album', 'albumId', 'year', 'trackNumber', 'lengthMs', 'fileType', 'source'];

// ---------------- arg parsing ----------------
function parseArgs(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--refresh') o.refresh = true;
    else if (a === '--all') o.all = true;
    else if (a === '--dry-run') o.dryRun = true;
    else if (a === '--watch') o.watch = true;
    else if (a === '--artist') o.artist = argv[++i];
    else if (a === '--album') o.album = argv[++i];
    else if (a === '--ids') o.ids = (argv[++i] || '').split(',').map((s) => s.trim()).filter(Boolean);
    else if (a === '--limit') o.limit = parseInt(argv[++i], 10);
    else if (a === '--server') o.server = argv[++i];
    else if (a === '--token') o.token = argv[++i];
    else if (a === '--csv') o.csv = argv[++i];
    else if (a === '-h' || a === '--help') o.help = true;
    else o._.push(a);
  }
  return o;
}

// ---------------- CSV (minimal RFC-4180: quote fields containing , " or newline) ----------------
function csvCell(v) {
  const s = v == null ? '' : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}
function csvRow(values) { return values.map(csvCell).join(','); }
function parseCsv(text) {
  const rows = [];
  let row = [], cell = '', inQ = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) {
      if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else inQ = false; }
      else cell += c;
    } else if (c === '"') inQ = true;
    else if (c === ',') { row.push(cell); cell = ''; }
    else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; }
    else if (c === '\r') { /* skip */ }
    else cell += c;
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
  return rows;
}

// Read the worklist CSV → array of {songId,artist,title,album,...}.
function readWorklist(csvPath) {
  if (!existsSync(csvPath)) {
    throw new Error(`worklist CSV not found: ${csvPath}\n  Generate it first with --refresh (needs the crawl outputs).`);
  }
  const rows = parseCsv(readFileSync(csvPath, 'utf8'));
  if (!rows.length) return [];
  const header = rows[0];
  const idx = Object.fromEntries(CSV_COLS.map((c) => [c, header.indexOf(c)]));
  const out = [];
  for (let r = 1; r < rows.length; r++) {
    const row = rows[r];
    if (!row.length || (row.length === 1 && row[0] === '')) continue;
    const get = (c) => (idx[c] >= 0 ? row[idx[c]] : '');
    const songId = get('songId');
    if (!songId) continue;
    out.push({
      songId, artist: get('artist'), title: get('title'), album: get('album'),
      albumId: get('albumId'), year: get('year'), trackNumber: get('trackNumber'),
      lengthMs: get('lengthMs'), fileType: get('fileType'), source: get('source'),
    });
  }
  return out;
}

// ---------------- regenerate the CSV from the latest crawl outputs ----------------
// misses = catalog-cache.ndjson rows where storeId === null, joined to song/album
// metadata from public/apple-music-index.json. Writes the CSV (sorted by artist,title).
function refreshCsv(csvPath) {
  if (!existsSync(CFG.ndjson)) throw new Error(`crawl cache not found: ${CFG.ndjson}`);
  if (!existsSync(CFG.index)) throw new Error(`index not found: ${CFG.index}`);

  const index = JSON.parse(readFileSync(CFG.index, 'utf8'));
  const songById = new Map((index.songs || []).map((s) => [s.id, s]));
  const albumById = new Map((index.albums || []).map((a) => [a.id, a]));
  const sourceName = index.manifest?.sourceName || index.manifest?.source || 'Apple Music (Local)';

  // Stream the ndjson line-by-line (it can be ~100k lines). Collect miss songIds.
  const ndjson = readFileSync(CFG.ndjson, 'utf8');
  const missIds = [];
  for (const line of ndjson.split('\n')) {
    if (!line) continue;
    let rec;
    try { rec = JSON.parse(line); } catch { continue; }
    if (rec && rec.storeId === null && rec.id) missIds.push(rec.id);
  }

  const rows = [];
  let missing = 0;
  for (const id of missIds) {
    const s = songById.get(id);
    if (!s) { missing++; continue; } // in cache but not in current index (stale) — skip
    const album = albumById.get(s.albumId);
    rows.push({
      songId: s.id,
      artist: s.artist || '',
      title: s.name || '',
      album: (album && album.name) || '',
      albumId: s.albumId || '',
      year: s.year ?? '',
      trackNumber: s.trackNumber ?? '',
      lengthMs: s.length ?? '',
      fileType: s.fileType || '',
      source: sourceName,
    });
  }
  rows.sort((a, b) =>
    (a.artist || '').toLowerCase().localeCompare((b.artist || '').toLowerCase()) ||
    (a.title || '').toLowerCase().localeCompare((b.title || '').toLowerCase()));

  const lines = [csvRow(CSV_COLS)];
  for (const r of rows) lines.push(csvRow(CSV_COLS.map((c) => r[c])));
  writeFileSync(csvPath, lines.join('\n') + '\n');
  return { written: rows.length, total: missIds.length, staleSkipped: missing };
}

// ---------------- selection ----------------
function selectMisses(worklist, opts) {
  let sel = worklist;
  if (opts.ids && opts.ids.length) {
    const set = new Set(opts.ids);
    sel = sel.filter((m) => set.has(m.songId));
  }
  if (opts.artist) {
    const q = opts.artist.toLowerCase();
    sel = sel.filter((m) => (m.artist || '').toLowerCase().includes(q));
  }
  if (opts.album) {
    const q = opts.album.toLowerCase();
    sel = sel.filter((m) => (m.album || '').toLowerCase().includes(q));
  }
  if (Number.isInteger(opts.limit) && opts.limit >= 0) sel = sel.slice(0, opts.limit);
  return sel;
}

function topArtists(worklist, n = 12) {
  const counts = new Map();
  for (const m of worklist) counts.set(m.artist, (counts.get(m.artist) || 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, n);
}

// ---------------- S3 manifest (already-ripped check) ----------------
function fetchManifest() {
  const r = spawnSync('aws', ['--profile', CFG.awsProfile, 's3', 'cp',
    `s3://${CFG.bucket}/rips/manifest.json`, '-'], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (r.status !== 0) {
    throw new Error(`aws s3 cp manifest failed (profile ${CFG.awsProfile}): ${(r.stderr || '').trim() || r.error?.message || 'unknown'}`);
  }
  try { return JSON.parse(r.stdout || '{}'); } catch { return {}; }
}

// ---------------- rip server ----------------
async function postRipCollection(server, token, songIds) {
  const headers = { 'content-type': 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(`${server.replace(/\/$/, '')}/rip-collection`, {
    method: 'POST', headers, body: JSON.stringify({ songIds }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`POST /rip-collection → ${res.status} ${res.statusText} ${body.slice(0, 200)}`);
  }
  return res.json();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------- formatting ----------------
function fmt(n) { return n.toLocaleString('en-US'); }
function previewTable(sel, max = 40) {
  const lines = [];
  for (const m of sel.slice(0, max)) {
    const dur = m.lengthMs ? `${Math.round((+m.lengthMs) / 1000)}s` : '?';
    lines.push(`  ${m.songId}  ${(m.artist || '—').slice(0, 28).padEnd(28)}  ${(m.title || '—').slice(0, 34).padEnd(34)}  ${dur}`);
  }
  if (sel.length > max) lines.push(`  … and ${fmt(sel.length - max)} more`);
  return lines.join('\n');
}

function printUsageSummary(worklist, csvPath) {
  console.log(`backfill-rip — rip out-of-streaming-catalog songs locally to backfill them.\n`);
  console.log(`Worklist: ${csvPath}`);
  console.log(`Total catalog misses (un-streamable, need local rip): ${fmt(worklist.length)}\n`);
  if (worklist.length) {
    console.log('Top artists by miss count:');
    for (const [artist, n] of topArtists(worklist)) {
      console.log(`  ${String(n).padStart(5)}  ${artist || '—'}`);
    }
    console.log('');
  }
  console.log(`Usage:
  node .claude/skills/backfill-rip/backfill-rip.mjs [selection] [flags]

Selection (combine freely; default none → prints this summary):
  --artist <substr>   misses whose artist contains <substr> (case-insensitive)
  --album  <substr>   misses whose album  contains <substr>
  --ids a,b,c         exact songIds (comma-separated)
  --all               every miss
  --limit N           cap to first N (after other filters)

Flags:
  --refresh           regenerate the CSV from the latest crawl outputs, then run
  --dry-run           preview the selection + counts, no network
  --watch             poll the S3 manifest until the selection finishes
  --server <url>      rip server (default ${CFG.server})
  --token  <token>    bearer (default $RIP_TOKEN)
  --csv    <path>     worklist CSV (default repo apple-music-catalog-misses.csv)

Examples:
  # regenerate the worklist from the latest crawl, then show the summary
  node .claude/skills/backfill-rip/backfill-rip.mjs --refresh

  # preview every Curren$y miss without touching the network
  node .claude/skills/backfill-rip/backfill-rip.mjs --artist "Curren" --dry-run

  # rip a whole album's misses, watching until done
  node .claude/skills/backfill-rip/backfill-rip.mjs --album "Pilot Talk" --watch

  # rip the first 50 misses (smoke run)
  node .claude/skills/backfill-rip/backfill-rip.mjs --all --limit 50`);
}

// ---------------- main ----------------
async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.csv) CFG.csv = resolve(opts.csv);
  if (opts.server) CFG.server = opts.server;
  if (opts.token != null) CFG.token = opts.token;
  const csvPath = CFG.csv;

  if (opts.help) { printUsageSummary([], csvPath); return; }

  // --refresh regenerates the CSV first (offline; reads crawl outputs).
  if (opts.refresh) {
    console.log(`Refreshing worklist from crawl outputs…`);
    console.log(`  cache: ${CFG.ndjson}`);
    console.log(`  index: ${CFG.index}`);
    const r = refreshCsv(csvPath);
    console.log(`Wrote ${fmt(r.written)} misses → ${csvPath}` +
      (r.staleSkipped ? `  (${fmt(r.staleSkipped)} stale cache ids not in current index, skipped)` : ''));
    console.log('');
  }

  const worklist = readWorklist(csvPath);

  const hasSelection = opts.all || opts.artist || opts.album || (opts.ids && opts.ids.length);
  if (!hasSelection) {
    // No-arg (or refresh-only): print usage + summary.
    printUsageSummary(worklist, csvPath);
    return;
  }

  const sel = selectMisses(worklist, opts);
  const filterDesc = [
    opts.artist && `artist~"${opts.artist}"`,
    opts.album && `album~"${opts.album}"`,
    opts.ids && opts.ids.length && `${opts.ids.length} ids`,
    opts.all && 'all',
    Number.isInteger(opts.limit) && `limit ${opts.limit}`,
  ].filter(Boolean).join(', ');
  console.log(`Selected ${fmt(sel.length)} of ${fmt(worklist.length)} misses` +
    (filterDesc ? `  (${filterDesc})` : ''));

  if (!sel.length) { console.log('Nothing selected — adjust the filters.'); return; }
  console.log('');
  console.log(previewTable(sel));
  console.log('');

  if (opts.dryRun) {
    console.log(`[dry-run] would POST ${fmt(sel.length)} songIds to ${CFG.server}/rip-collection — no network performed.`);
    return;
  }

  // Idempotency: how many of the selection are already ripped (in the S3 manifest)?
  let manifest = {};
  let alreadyIds = new Set();
  try {
    manifest = fetchManifest();
    alreadyIds = new Set(sel.map((m) => m.songId).filter((id) => manifest[id]));
    console.log(`S3 manifest: ${fmt(Object.keys(manifest).length)} songs already ripped overall.`);
    console.log(`  Of this selection: ${fmt(alreadyIds.size)} already ripped, ${fmt(sel.length - alreadyIds.size)} to rip.`);
  } catch (e) {
    console.log(`Warning: could not read S3 manifest (${e.message}). Proceeding; the rip server still dedups.`);
  }
  console.log('');

  const songIds = sel.map((m) => m.songId);
  console.log(`POST ${CFG.server}/rip-collection  (${fmt(songIds.length)} songIds)…`);
  let resp;
  try {
    resp = await postRipCollection(CFG.server, CFG.token, songIds);
  } catch (e) {
    console.error(`Rip server request failed: ${e.message}`);
    console.error(`  Is the rip server running? (default ${CFG.server}; override --server / --token)`);
    process.exitCode = 1;
    return;
  }

  const counts = resp.counts || {};
  console.log(`Result counts: ` +
    `ready=${fmt(counts.ready || 0)}  queued=${fmt(counts.queued || 0)}  ` +
    `inflight=${fmt(counts.inflight || 0)}  unknown=${fmt(counts.unknown || 0)}  total=${fmt(counts.total || songIds.length)}`);
  console.log(`  ready    = already ripped (manifest) — nothing to do`);
  console.log(`  queued   = newly enqueued for a real-time local rip`);
  console.log(`  inflight = joined an already-running rip`);
  console.log(`  unknown  = not in the rip server catalog (won't rip — re-index?)`);

  const unknowns = (resp.results || []).filter((r) => r.status === 'unknown');
  if (unknowns.length) {
    console.log(`\n${fmt(unknowns.length)} unknown songId(s) (first 10): ${unknowns.slice(0, 10).map((r) => r.songId).join(', ')}`);
  }

  if (opts.watch) {
    const watchIds = songIds.filter((id) => {
      const r = (resp.results || []).find((x) => x.songId === id);
      return r && r.status !== 'unknown' && r.status !== 'ready';
    });
    if (!watchIds.length) { console.log('\nNothing left to wait on — all ready/unknown.'); return; }
    console.log(`\nWatching S3 manifest until ${fmt(watchIds.length)} rip(s) finish (Ctrl-C to stop)…`);
    const pending = new Set(watchIds);
    const startedAt = Date.now();
    while (pending.size) {
      await sleep(15000);
      let m;
      try { m = fetchManifest(); } catch (e) { console.log(`  (manifest read failed: ${e.message})`); continue; }
      for (const id of [...pending]) if (m[id]) pending.delete(id);
      const done = watchIds.length - pending.size;
      const mins = ((Date.now() - startedAt) / 60000).toFixed(1);
      console.log(`  ${fmt(done)}/${fmt(watchIds.length)} ripped  (${mins}m elapsed)`);
    }
    console.log('All selected rips are in the S3 manifest. Done.');
  } else {
    console.log(`\nRips run in the background on the server (real-time Apple Music capture). Re-run with --watch to poll until done, or re-run the same selection later — it's idempotent.`);
  }
}

main().catch((e) => { console.error(`Error: ${e.message}`); process.exitCode = 1; });
