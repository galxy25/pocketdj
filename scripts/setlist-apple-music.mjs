#!/usr/bin/env node
// setlist-apple-music — for each row in a PocketDJ setlist CSV, report whether that
// song exists in your local Apple Music (Music.app) library.
//
// It resolves each setlist row to its canonical artist/title (via the index, by Song ID)
// and fuzzy-matches against the library dump produced by dump-apple-music-library.mjs.
// Output is a CSV: one row per setlist row + InLibrary (Yes/No), Match (exact|loose|none),
// and the matched library Artist/Title/Album.
//
// First build (or refresh) the library dump:
//   node scripts/dump-apple-music-library.mjs            # full first run, then incremental
// Then:
//   node scripts/setlist-apple-music.mjs --setlist "<csv>"
//
// Options:
//   --setlist <csv>   Setlist export CSV (required; needs a "Song ID" column).
//   --index <json>    Music index for canonical artist/title (default public/current-index.json).
//   --library <tsv>   Library dump TSV (default index-out/apple-music-library.tsv).
//   --refresh         Run the dumper first (slow on a large library), then match.
//   --out <csv>       Output path (default "<setlist basename> - apple-music.csv" in cwd).

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]; if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    if (key === 'refresh') { out.refresh = true; continue; }
    out[key] = argv[++i];
  }
  return out;
}
const args = parseArgs(process.argv.slice(2));
function die(msg) { console.error(`\n✗ ${msg}\n`); process.exit(1); }

const SETLIST = args.setlist;
const INDEX = args.index || 'public/current-index.json';
const LIB_TSV = args.library || 'index-out/apple-music-library.tsv';
const DUMPER = path.join(path.dirname(new URL(import.meta.url).pathname), 'dump-apple-music-library.mjs');
if (!SETLIST) die('Missing --setlist <csv>. See header of this script for usage.');
if (!fs.existsSync(SETLIST)) die(`Setlist CSV not found: ${SETLIST}`);

// ---------- CSV ----------
function parseCSV(text) {
  const rows = []; let row = [], field = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; } else field += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (c === '\r') { /* skip */ }
    else field += c;
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  return rows.filter(r => r.length > 1 || (r.length === 1 && r[0] !== ''));
}
const csvCell = (s) => { s = s == null ? '' : String(s); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };

// ---------- normalization ----------
const stripDiacritics = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '');
function normTitle(s) {
  let t = stripDiacritics(String(s || '').toLowerCase());
  t = t.replace(/[\(\[].*?[\)\]]/g, ' ');                 // drop (…)/[…] qualifiers
  t = t.replace(/\b(feat|featuring|ft)\b.*$/g, ' ');      // drop "feat …" tail
  t = t.replace(/&/g, ' and ');
  return t.replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
}
function normArtist(s) {
  let t = stripDiacritics(String(s || '').toLowerCase());
  t = t.replace(/[\(\[].*?[\)\]]/g, ' ');
  t = t.replace(/\b(feat|featuring|ft)\b.*$/g, ' ');
  t = t.replace(/&/g, ' and ');
  t = t.replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
  return t.replace(/^the\s+/, '');
}
const tokens = (s) => new Set(s.split(' ').filter(Boolean));
function subsetEither(a, b) {
  const A = tokens(a), B = tokens(b);
  if (!A.size || !B.size) return false;
  const small = A.size <= B.size ? A : B, big = A.size <= B.size ? B : A;
  for (const x of small) if (!big.has(x)) return false;
  return true;
}

// ---------- ensure library dump exists ----------
if (args.refresh) {
  console.log('Refreshing Apple Music library dump…');
  const r = spawnSync('node', [DUMPER], { stdio: 'inherit' });
  if (r.status !== 0) die('Library dump failed; see output above.');
}
if (!fs.existsSync(LIB_TSV)) {
  die(`No library dump at ${LIB_TSV}.\n   Build it first (slow on a large library, then incremental):\n     node scripts/dump-apple-music-library.mjs\n   …or pass --refresh to do it now.`);
}

// ---------- load library ----------
function loadLibrary() {
  const rows = fs.readFileSync(LIB_TSV, 'utf8').trim().split('\n').slice(1);
  const exact = new Map(), byTitle = new Map(); let count = 0;
  for (const ln of rows) {
    const [, artist, title, album] = ln.split('\t');
    if (!title) continue;
    const e = { artist, title, album, na: normArtist(artist), nt: normTitle(title) };
    count++;
    const k = e.na + '\x00' + e.nt;
    if (!exact.has(k)) exact.set(k, e);
    if (!byTitle.has(e.nt)) byTitle.set(e.nt, []);
    byTitle.get(e.nt).push(e);
  }
  return { exact, byTitle, count };
}
const lib = loadLibrary();

// ---------- match ----------
const idx = fs.existsSync(INDEX) ? JSON.parse(fs.readFileSync(INDEX, 'utf8')) : { songs: [] };
const songById = new Map((idx.songs || []).map(s => [s.id, s]));
const rows = parseCSV(fs.readFileSync(SETLIST, 'utf8'));
if (!rows.length) die('Setlist CSV is empty.');
const header = rows[0].map(h => h.trim());
const col = (n) => header.findIndex(h => h.toLowerCase() === n.toLowerCase());
const cId = col('Song ID'); if (cId < 0) die('Setlist has no "Song ID" column.');
const cArtist = col('Artist'), cTitle = col('Title');

const outRows = [[...header, 'InLibrary', 'Match', 'LibraryArtist', 'LibraryTitle', 'LibraryAlbum']];
let inLib = 0, exactN = 0, looseN = 0;
const missing = [];
const data = rows.slice(1);
for (const r of data) {
  const song = songById.get((r[cId] || '').trim());
  const artist = song?.artist || (cArtist >= 0 ? r[cArtist] : '');
  const title = song?.name || (cTitle >= 0 ? r[cTitle] : '');
  const na = normArtist(artist), nt = normTitle(title);
  // lib.exact values are ARRAYS since the edition-aware matcher (first-in wins, the
  // historical single-entry behavior).
  let match = 'none', hit = (lib.exact.get(na + '\x00' + nt) || [])[0] || null;
  if (hit) match = 'exact';
  else { hit = (lib.byTitle.get(nt) || []).find(e => subsetEither(e.na, na)) || null; if (hit) match = 'loose'; }
  if (match !== 'none') { inLib++; match === 'exact' ? exactN++ : looseN++; }
  else missing.push(`${artist} — ${title}`);
  outRows.push([...r, match === 'none' ? 'No' : 'Yes', match, hit?.artist || '', hit?.title || '', hit?.album || '']);
}

const outPath = args.out || (path.basename(SETLIST).replace(/\.[^.]+$/, '') + ' - apple-music.csv');
fs.writeFileSync(outPath, outRows.map(r => r.map(csvCell).join(',')).join('\n') + '\n');

console.log(`\nMatched ${data.length} setlist songs against ${lib.count} library tracks:`);
console.log(`  in library: ${inLib}   (exact ${exactN}, loose ${looseN})   not found: ${data.length - inLib}`);
if (missing.length) { console.log('  missing:'); for (const m of missing) console.log(`     - ${m}`); }
console.log(`\n  → ${outPath}\n`);
