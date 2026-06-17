#!/usr/bin/env node
// backfill-apple-music — for setlist songs NOT in the local Apple Music library, find the
// matching Apple Music catalog track via the public iTunes Search API. Produces a review
// file of proposed additions (artist/title/album/catalog id/url + confidence). The actual
// "add to library" step needs the Music UI (Accessibility) and is done by --add (see below).
//
// Usage:
//   node scripts/backfill-apple-music.mjs --setlist "<csv>"            # resolve + write review
//   node scripts/backfill-apple-music.mjs --setlist "<csv>" --add      # also add to library (UI, needs Accessibility)
//
// Options:
//   --setlist <csv>    setlist export (needs Song ID column)            [required]
//   --index <json>     index for canonical artist/title (default public/current-index.json)
//   --library-tsv <t>  local library dump (default index-out/apple-music-library.tsv)
//   --country <cc>     iTunes storefront (default us)
//   --out <csv>        review output (default "<setlist> - backfill.csv")
//   --delay-ms <n>     pause between API calls (default 1200; Apple rate-limits ~20/min)
//   --add              after resolving, add confirmed matches to the library via the Music UI

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]; if (!a.startsWith('--')) continue;
    const k = a.slice(2);
    if (k === 'add') { out.add = true; continue; }
    out[k] = argv[++i];
  }
  return out;
}
const args = parseArgs(process.argv.slice(2));
const die = (m) => { console.error(`\n✗ ${m}\n`); process.exit(1); };

const SETLIST = args.setlist;
const INDEX = args.index || 'public/current-index.json';
const LIB_TSV = args['library-tsv'] || 'index-out/apple-music-library.tsv';
const COUNTRY = (args.country || 'us').toLowerCase();
const DELAY = parseInt(args['delay-ms'] || '1200', 10);
if (!SETLIST) die('Missing --setlist <csv>.');
if (!fs.existsSync(SETLIST)) die(`Setlist not found: ${SETLIST}`);
if (!fs.existsSync(LIB_TSV)) die(`Library dump not found: ${LIB_TSV} (run dump-apple-music-library.mjs).`);

// ---- CSV ----
function parseCSV(text) {
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\n') { row.push(f); rows.push(row); row = []; f = ''; }
    else if (c === '\r') { }
    else f += c;
  }
  if (f.length || row.length) { row.push(f); rows.push(row); }
  return rows.filter(r => r.length > 1 || (r.length === 1 && r[0] !== ''));
}
const csvCell = (s) => { s = s == null ? '' : String(s); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };

// ---- normalization ----
const stripD = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '');
function normTitle(s) {
  let t = stripD(String(s || '').toLowerCase());
  t = t.replace(/[\(\[].*?[\)\]]/g, ' ').replace(/\b(feat|featuring|ft)\b.*$/g, ' ').replace(/&/g, ' and ');
  return t.replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
}
function normArtist(s) {
  let t = stripD(String(s || '').toLowerCase());
  t = t.replace(/[\(\[].*?[\)\]]/g, ' ').replace(/\b(feat|featuring|ft)\b.*$/g, ' ').replace(/&/g, ' and ');
  t = t.replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
  return t.replace(/^the\s+/, '');
}
const toks = (s) => new Set(s.split(' ').filter(Boolean));
function overlap(a, b) {
  const A = toks(a), B = toks(b); if (!A.size || !B.size) return 0;
  let n = 0; for (const x of A) if (B.has(x)) n++;
  return n / Math.max(A.size, B.size);
}

// ---- local library (to know what's already there) ----
const libKeys = new Set();
for (const ln of fs.readFileSync(LIB_TSV, 'utf8').trim().split('\n').slice(1)) {
  const [, artist, title] = ln.split('\t');
  if (title) libKeys.add(normArtist(artist) + '\x00' + normTitle(title));
}

// ---- index + setlist ----
const idx = fs.existsSync(INDEX) ? JSON.parse(fs.readFileSync(INDEX, 'utf8')) : { songs: [] };
const songById = new Map((idx.songs || []).map(s => [s.id, s]));
const rows = parseCSV(fs.readFileSync(SETLIST, 'utf8'));
const header = rows[0].map(h => h.trim());
const col = (n) => header.findIndex(h => h.toLowerCase() === n.toLowerCase());
const cId = col('Song ID'), cArtist = col('Artist'), cTitle = col('Title'), cNum = col('#');
if (cId < 0) die('Setlist has no Song ID column.');

const missing = [];
rows.slice(1).forEach((r, i) => {
  const song = songById.get((r[cId] || '').trim());
  const artist = song?.artist || (cArtist >= 0 ? r[cArtist] : '');
  const title = song?.name || (cTitle >= 0 ? r[cTitle] : '');
  const pos = cNum >= 0 ? (r[cNum] || '').trim() : String(i + 1);
  if (libKeys.has(normArtist(artist) + '\x00' + normTitle(title))) return; // already in library
  missing.push({ pos, songId: (r[cId] || '').trim(), artist, title });
});

// ---- iTunes Search API resolver ----
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
async function searchCatalog(artist, title) {
  const term = encodeURIComponent(`${artist} ${title}`.replace(/[\(\[].*?[\)\]]/g, ' ').trim());
  const url = `https://itunes.apple.com/search?term=${term}&entity=song&limit=8&country=${COUNTRY}`;
  let data;
  try { const res = await fetch(url); data = await res.json(); }
  catch (e) { return { status: 'api-error', err: String(e) }; }
  const na = normArtist(artist), nt = normTitle(title);
  let best = null, bestScore = -1;
  for (const r of (data.results || [])) {
    const ra = normArtist(r.artistName), rt = normTitle(r.trackName);
    const titleScore = rt === nt ? 1 : overlap(rt, nt);
    const artistScore = ra === na ? 1 : overlap(ra, na);
    const score = titleScore * 0.6 + artistScore * 0.4;
    if (score > bestScore) { bestScore = score; best = r; }
  }
  if (!best) return { status: 'none' };
  const conf = bestScore >= 0.95 ? 'exact' : bestScore >= 0.7 ? 'strong' : bestScore >= 0.5 ? 'weak' : 'poor';
  return {
    status: 'found', confidence: conf, score: +bestScore.toFixed(3),
    catalogArtist: best.artistName, catalogTitle: best.trackName, catalogAlbum: best.collectionName,
    trackId: best.trackId, collectionId: best.collectionId, url: best.trackViewUrl, streamable: best.isStreamable !== false,
  };
}

// ---- run ----
console.log(`\nBackfill resolver — ${missing.length} setlist songs not in your library:\n`);
const resolved = [];
for (const m of missing) {
  const r = await searchCatalog(m.artist, m.title);
  resolved.push({ ...m, ...r });
  const tag = r.status === 'found' ? `${r.confidence}(${r.score})  → ${r.catalogArtist} — ${r.catalogTitle}` : r.status;
  console.log(`  ${m.pos.padStart(3)}. ${m.artist} — ${m.title}\n        ${tag}`);
  await sleep(DELAY);
}

const outPath = args.out || (path.basename(SETLIST).replace(/\.[^.]+$/, '') + ' - backfill.csv');
const outRows = [['#', 'SetlistArtist', 'SetlistTitle', 'SongID', 'Status', 'Confidence', 'Score', 'CatalogArtist', 'CatalogTitle', 'CatalogAlbum', 'TrackID', 'URL']];
for (const r of resolved) outRows.push([r.pos, r.artist, r.title, r.songId, r.status, r.confidence || '', r.score ?? '', r.catalogArtist || '', r.catalogTitle || '', r.catalogAlbum || '', r.trackId || '', r.url || '']);
fs.writeFileSync(outPath, outRows.map(r => r.map(csvCell).join(',')).join('\n') + '\n');
const jsonPath = outPath.replace(/\.csv$/, '.json');
fs.writeFileSync(jsonPath, JSON.stringify(resolved, null, 2));

const found = resolved.filter(r => r.status === 'found');
const strong = found.filter(r => r.confidence === 'exact' || r.confidence === 'strong');
console.log(`\nResolved ${found.length}/${missing.length}  (${strong.length} exact/strong)`);
console.log(`  → ${outPath}\n  → ${jsonPath}`);

if (args.add) {
  // Adding catalog songs requires the Music UI (no AppleScript path). Needs Accessibility.
  const acc = spawnSync('sqlite3', [`${process.env.HOME}/Library/Application Support/com.apple.TCC/TCC.db`, "select count(*) from access where service='kTCCServiceAccessibility' and auth_value=2;"], { encoding: 'utf8' }).stdout?.trim();
  console.log(`\n--add requested. Adding catalog tracks to the library needs the Music UI (Accessibility).`);
  console.log(`  Accessibility-allowed clients: ${acc || '0'}.`);
  console.log('  The UI-automation add step is implemented separately once Accessibility is granted —');
  console.log('  review the matches above first, then we wire the add. (Nothing was added in this run.)');
}
