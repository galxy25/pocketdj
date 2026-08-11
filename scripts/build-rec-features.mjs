#!/usr/bin/env node
// Build public/rec-features.json — the slim, precomputed per-song feature file the PocketDJ
// recommendation engine Lambda (scripts/lambda/rec-engine) scores against. Reads the local
// catalog index documents (or the CDN copies with --from-cdn), reduces each song to the handful
// of fields the scorer needs, and writes one compact JSON document that deploys with the catalog
// via scripts/deploy.sh (publish-s3) — no new upload path.
//
// REGENERATION IS WIRED IN — the committed copy is a bootstrap snapshot, not the source of
// truth, and the indexes it derives from churn nightly (am-sync 04:00, digital-sync 05:00,
// streaming-links 06:00). It is rebuilt automatically by:
//   • scripts/deploy.sh — before every PWA build (soft-fail), shipped no-cache with the shell;
//   • scripts/streaming-links-nightly.sh stage 4 — nightly regen; the normalized-hash change
//     gate commits + publishes it to the PROD bucket ONLY when its content actually moved
//     (root generatedAt is ignored by the gate, so an unchanged catalog ships nothing).
// The Lambda refetches the CDN copy with If-None-Match on a 15-minute TTL, so a shipped
// regen reaches live scoring within minutes without a Lambda redeploy.
//
//   node scripts/build-rec-features.mjs [--from-cdn]
//
// Output shape (nulls stay ABSENT — omitted keys shrink the file):
//   { "v":1, "generatedAt":"…", "counts":{"songs":N},
//     "songs":[ {"i":"sng_x","al":"alb_y","a":"Artist","n":"Name","g":"electronic","y":1994,
//                "b":120.1,"c":"8A","s":["dark","moody"],"am":"123"} ] }

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(__dirname, '..', 'public');
const CDN = 'https://d2p4cubg6se03u.cloudfront.net';
const OUT = join(PUBLIC, 'rec-features.json');
const fromCdn = process.argv.includes('--from-cdn');

// ── Genre → tier-1 category ─────────────────────────────────────────────────────────────────────
// KEEP IN SYNC with apple/PocketDJ/Support/Genre.swift (the ordered substring matcher + the full
// keyword table, ported verbatim). Drift silently skews the engine's genre scoring.
const GENRE_CATEGORIES = [
  ['hip-hop', ['hip hop', 'hip-hop', 'hiphop', 'rap', 'boom bap', 'gangsta', 'g-funk', 'crunk',
               'trap', 'conscious', 'jazzy hip', 'jazz rap', 'plunderphonics', 'dj battle',
               'cut-up/dj', 'ragga hiphop', 'thug rap', 'dance rap', 'political rap',
               'old-school hip', 'new-school hip', 'golden age', 'underground hip',
               'alternative hip', 'instrumental hip', 'east coast', 'west coast', 'southern hip']],
  ['classical', ['classical', 'baroque', 'romantic', 'symphonic', 'orchestral', 'chamber',
                 'opera', 'film music', 'wagnerian']],
  ['blues', ['blues']],
  ['country', ['country', 'americana', 'bluegrass', 'outlaw', 'nashville', 'bakersfield',
               'countrypolitan', 'western', 'ranchera', 'mariachi', 'norteño', 'norteno', 'honky']],
  ['world', ['latin', 'salsa', 'merengue', 'cumbia', 'charanga', 'bolero', 'samba', 'guajira',
             'marimba', 'andean', 'bossa', 'reggae', 'dancehall', 'ragga', 'ska', 'afro',
             'polka', 'hawaiian', 'indian classical', 'hindustani', 'world']],
  ['jazz', ['jazz', 'bossa nova', 'big band', 'bebop', 'cool jazz', 'smooth jazz', 'post-bop',
            'vocal jazz', 'fusion', 'crossover jazz', 'acid jazz', 'soul-jazz']],
  ['disco', ['disco', 'boogie', 'hi nrg', 'hi-nrg', 'hinrg', 'post-disco', 'nu-disco',
             'eurodance', 'freestyle', 'go-go']],
  ['funk', ['funk', 'minneapolis', 'p-funk', 'avant-funk', 'jazz-funk', 'jazz funk', 'acid jazz',
            'synth-funk', 'quiet storm', 'go-go']],
  ['soul', ['soul', 'motown', 'philly soul', 'philadelphia soul', 'gospel', 'doo wop',
            'doo-wop', 'quiet storm']],
  ['r&b', ['r&b', 'rnb', 'rhythm & blues', 'rhythm and blues', 'new jack', 'contemporary r&b',
           'hip-hop soul', 'hip hop soul', 'urban', 'minneapolis sound']],
  ['electronic', ['electronic', 'electronica', 'house', 'techno', 'trance', 'edm', 'synth-pop',
                  'synthpop', 'synth pop', 'electropop', 'electro', 'downtempo', 'trip hop',
                  'leftfield', 'new wave', 'breaks', 'tribal house', 'deep house',
                  'progressive house', 'witch house', 'darkwave', 'indietronica', 'bass music',
                  'dub', 'hi nrg']],
  ['rock', ['rock', 'metal', 'punk', 'grunge', 'psychedelic', 'garage', 'shoegaze', 'indie rock',
            'glam', 'arena', 'heartland', 'thrash']],
  ['folk', ['folk', 'singer-songwriter', 'indie folk', 'folk rock', 'folk-pop', 'folk jazz',
            'sunshine pop', 'spoken word', 'poetry']],
  ['pop', ['pop', 'dance-pop', 'dance pop', 'dance-rock', 'art pop', 'baroque pop', 'chamber pop',
           'sophisti-pop', 'europop', 'new pop', 'traditional pop', 'novelty', 'comedy',
           'adult contemporary', 'dance']],
];

const CSS_BLOB = /\.mw-parser-output[^}]*\}/g;

/** Map a raw genre string to its tier-1 category (first keyword hit wins). */
export function genreCategory(genre) {
  if (!genre) return 'other';
  let s = String(genre).toLowerCase().trim();
  if (!s) return 'other';
  s = s.replace(CSS_BLOB, ' ').trim();
  if (!s) return 'other';
  for (const [name, keywords] of GENRE_CATEGORIES) {
    if (keywords.some((k) => s.includes(k))) return name;
  }
  return 'other';
}

async function loadIndex(name) {
  if (fromCdn) {
    const res = await fetch(`${CDN}/${name}`);
    if (!res.ok) { console.warn(`[rec-features] skip ${name} (CDN ${res.status})`); return null; }
    return res.json();
  }
  const p = join(PUBLIC, name);
  if (!existsSync(p)) { console.warn(`[rec-features] skip ${name} (missing)`); return null; }
  return JSON.parse(readFileSync(p, 'utf8'));
}

// ── Timbre corpus (public/timbre.json, written by scripts/fold-timbre.mjs) ─────────────────────
/// Resolve the corpus into a flat id → 14-axis vector map. Aliases ({alias:"sng_x"}) are the
/// EXPLICIT same-recording indirections built by build-timbre-aliases.mjs — resolved here, at
/// read time, one hop only (an alias to an alias is a build error and resolves to nothing
/// rather than chasing a chain into a cycle).
export function timbreMap(doc) {
  const m = new Map();
  const songs = doc?.songs && typeof doc.songs === 'object' ? doc.songs : {};
  for (const [id, row] of Object.entries(songs)) {
    if (row?.f && typeof row.f === 'object') m.set(id, row.f);
  }
  for (const [id, row] of Object.entries(songs)) {
    if (row?.alias && !m.has(id)) {
      const f = m.get(row.alias);
      if (f) m.set(id, f);
    }
  }
  return m;
}

/** One reduced feature row per song; nulls omitted. Exported for tests.
 *  `timbre`: optional Map(id → f) from timbreMap() — attached as row.t (absent when unknown). */
export function reduce(index, timbre = null) {
  const albums = new Map((index.albums || []).map((a) => [a.id, a]));
  const rows = [];
  for (const s of index.songs || []) {
    const album = s.albumId ? albums.get(s.albumId) : null;
    const row = { i: s.id };
    if (s.albumId) row.al = s.albumId;
    if (s.artist) row.a = s.artist;
    if (s.name) row.n = s.name;
    const g = genreCategory(album?.genre);
    if (g !== 'other') row.g = g;
    const year = s.year ?? album?.year;
    if (Number.isFinite(year)) row.y = year;
    // bpm/camelot: song-level first, else the album audioTracks row that IS this song's audio —
    // identified by the segment boundaries stamped on the song's pointer (startMs) at analysis
    // time. NEVER match by trackNumber: catalog trackNumber is the wiki-tracklist position, not
    // the rip's segment ordinal, and un-analyzed duplicate/bonus entries (pointer.startMs absent)
    // would silently borrow ANOTHER recording's bpm/key (49 fabricated rows shipped 08-07..08-10).
    let bpm = s.bpm; let camelot = s.camelot;
    if ((bpm == null || camelot == null) && album?.audioTracks
        && Number.isFinite(s.pointer?.startMs)) {
      const at = album.audioTracks.find((t) => t.startMs === s.pointer.startMs);
      if (at) { bpm = bpm ?? at.bpm; camelot = camelot ?? at.camelot; }
    }
    if (Number.isFinite(bpm)) row.b = Math.round(bpm * 10) / 10;
    if (camelot) row.c = String(camelot);
    if (Array.isArray(s.sentimentKeywords) && s.sentimentKeywords.length) {
      row.s = s.sentimentKeywords.slice(0, 6).map((k) => String(k).toLowerCase());
    }
    if (s.appleMusicId) row.am = String(s.appleMusicId);
    // Timbre vector — under the song's OWN id (or its explicit alias, resolved upstream).
    const t = timbre?.get(s.id);
    if (t) row.t = t;
    rows.push(row);
  }
  return rows;
}

async function main() {
  // Priority order for the appleMusicId dedupe: apple-music > digital > vinyl (keep first).
  const sources = [
    ['apple-music-index.json', await loadIndex('apple-music-index.json')],
    ['digital-index.json', await loadIndex('digital-index.json')],
    ['current-index.json', await loadIndex('current-index.json')],
  ];
  // Timbre corpus rides along when present (built by fold-timbre.mjs; absent = no `t` fields).
  const timbre = timbreMap(await loadIndex('timbre.json'));
  if (timbre.size) console.log(`[rec-features] timbre corpus: ${timbre.size} songs`);
  const seenAm = new Set();
  const songs = [];
  for (const [name, index] of sources) {
    if (!index) continue;
    let kept = 0; let dropped = 0;
    for (const row of reduce(index, timbre)) {
      if (row.am) {
        if (seenAm.has(row.am)) { dropped += 1; continue; }
        seenAm.add(row.am);
      }
      songs.push(row);
      kept += 1;
    }
    console.log(`[rec-features] ${name}: kept ${kept}, deduped ${dropped}`);
  }
  const doc = {
    v: 1,
    generatedAt: new Date().toISOString(),
    counts: { songs: songs.length },
    songs,
  };
  const json = JSON.stringify(doc);
  writeFileSync(OUT, json);
  const mb = json.length / (1024 * 1024);
  console.log(`[rec-features] wrote ${OUT} — ${songs.length} songs, ${mb.toFixed(1)} MB`);
  if (mb > 20) console.warn('[rec-features] WARNING: output exceeds 20 MB — consider trimming fields');
}

// Import-safe (tests import genreCategory); run only as a CLI entry.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
