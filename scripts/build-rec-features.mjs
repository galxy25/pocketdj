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
import { TIMBRE_VERSION } from './lib/audio-analyze.mjs';
import { isUsableTimbreRow } from './lib/timbre-hygiene.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(__dirname, '..', 'public');
const CDN = 'https://d2p4cubg6se03u.cloudfront.net';
const OUT = join(PUBLIC, 'rec-features.json');
const fromCdn = process.argv.includes('--from-cdn');

// ── Genre → tier-1 category ─────────────────────────────────────────────────────────────────────
// KEEP IN SYNC with apple/PocketDJ/Support/Genre.swift (the ordered substring matcher + the full
// keyword table, ported verbatim). Drift silently skews the engine's genre scoring;
// tests/unit/genre-parity.test.mjs reads the Swift source and fails if the two tables diverge.
//
// AN UNMATCHED LABEL IS A DROPPED ROW, NOT A HARMLESS DEFAULT. `reduce()` omits row.g when the
// category is 'other', so a raw genre this table does not recognise leaves the song with NO genre
// signal — the engine cannot tell it apart from a song that was never genred. 57 real labels
// covering 10,516 songs (9.6% of the catalog) were being dropped that way — 'Alternative' 6,341,
// 'Singer/Songwriter' 600, 'Soundtrack' 583, 'Holiday' 218 — which is why 51 of the 62 members of
// the "Twinkle Toes" holiday crate carried no category and its profile was built from the 11
// non-holiday leftovers. Adding a keyword here is cheap; leaving one out is silent.
//
// Each entry is [name, keywords] or [name, keywords, broadKeywords]. The matcher runs TWO passes:
//   pass 1 — every category's `keywords`, in table order: specific leaf genres.
//   pass 2 — every category's `broadKeywords`, in table order: parent tags so broad they must lose
//            to ANY specific genre. "Alternative Folk" is folk; a bare "Alternative" is rock.
// A pass-2 tag cannot simply be appended to pass 1: the table is first-hit-wins and rock sits
// ahead of folk and pop, so 'alternative' in rock's pass-1 list would drag 58 "Alternative Folk"
// and 15 "Indie, Pop, Alternative" rows out of the category they already resolve to correctly.
const GENRE_CATEGORIES = [
  // A seasonal tag is the most specific thing about a record and outranks its parent genre:
  // "Christmas: R&B" belongs with the other holiday songs, not with the rest of soul.
  ['holiday', ['holiday', 'christmas', 'xmas', 'hanukkah', 'kwanzaa', 'yuletide', 'halloween']],
  ['hip-hop', ['hip hop', 'hip-hop', 'hiphop', 'rap', 'boom bap', 'gangsta', 'g-funk', 'crunk',
               'trap', 'conscious', 'jazzy hip', 'jazz rap', 'plunderphonics', 'dj battle',
               'cut-up/dj', 'ragga hiphop', 'thug rap', 'dance rap', 'political rap',
               'old-school hip', 'new-school hip', 'golden age', 'underground hip',
               'alternative hip', 'instrumental hip', 'east coast', 'west coast', 'southern hip',
               'dirty south']],
  ['classical', ['classical', 'baroque', 'romantic', 'symphonic', 'orchestral', 'chamber',
                 'opera', 'film music', 'wagnerian', 'minimalism'],
                // A soundtrack is whatever the film needed; only claim it when nothing else did.
                ['soundtrack', 'score', 'musicals']],
  ['blues', ['blues', 'jug band']],
  ['country', ['country', 'americana', 'bluegrass', 'outlaw', 'nashville', 'bakersfield',
               'countrypolitan', 'western', 'ranchera', 'mariachi', 'norteño', 'norteno', 'honky']],
  // 'asia', 'france', 'farsi', 'arabic' are Apple Music's REGIONAL buckets, which arrive as the
  // whole genre string for imported rows; they carry no other meaning in this catalog.
  ['world', ['latin', 'salsa', 'merengue', 'cumbia', 'charanga', 'bolero', 'samba', 'guajira',
             'marimba', 'andean', 'bossa', 'reggae', 'dancehall', 'ragga', 'ska', 'afro',
             'polka', 'hawaiian', 'indian classical', 'hindustani', 'world', 'african',
             'música tropical', 'musica tropical', 'música mexicana', 'musica mexicana',
             'brazilian', 'mpb', 'amapiano', 'kizomba', 'highlife', 'celtic', 'caribbean',
             'exotica', 'jùjú', 'juju', 'regional indian', 'asia', 'france', 'farsi', 'arabic']],
  ['jazz', ['jazz', 'bossa nova', 'big band', 'bebop', 'cool jazz', 'smooth jazz', 'post-bop',
            'vocal jazz', 'fusion', 'crossover jazz', 'acid jazz', 'soul-jazz', 'bop']],
  ['disco', ['disco', 'boogie', 'hi nrg', 'hi-nrg', 'hinrg', 'post-disco', 'nu-disco',
             'eurodance', 'freestyle', 'go-go']],
  ['funk', ['funk', 'minneapolis', 'p-funk', 'avant-funk', 'jazz-funk', 'jazz funk', 'acid jazz',
            'synth-funk', 'quiet storm', 'go-go']],
  ['soul', ['soul', 'motown', 'philly soul', 'philadelphia soul', 'gospel', 'doo wop',
            'doo-wop', 'quiet storm'],
           // Sits with gospel — but Christian ROCK is rock, so it only claims what nothing else did.
           ['christian', 'religious']],
  ['r&b', ['r&b', 'rnb', 'rhythm & blues', 'rhythm and blues', 'new jack', 'contemporary r&b',
           'hip-hop soul', 'hip hop soul', 'urban', 'minneapolis sound']],
  ['electronic', ['electronic', 'electronica', 'house', 'techno', 'trance', 'edm', 'synth-pop',
                  'synthpop', 'synth pop', 'electropop', 'electro', 'downtempo', 'trip hop',
                  'leftfield', 'new wave', 'breaks', 'tribal house', 'deep house',
                  'progressive house', 'witch house', 'darkwave', 'indietronica', 'bass music',
                  'dub', 'hi nrg', 'breakbeat', 'jungle', "drum'n'bass", 'drum and bass'],
                 ['ambient', 'idm', 'experimental', 'new age', 'bass']],
  ['rock', ['rock', 'metal', 'punk', 'grunge', 'psychedelic', 'garage', 'shoegaze', 'indie rock',
            'glam', 'arena', 'heartland', 'thrash'],
           // The catalog's single biggest dropped label ('Alternative', 6,341 rows) lives here.
           ['alternative', 'indie', 'hardcore']],
  ['folk', ['folk', 'singer-songwriter', 'singer/songwriter', 'singer songwriter', 'indie folk',
            'folk rock', 'folk-pop', 'folk jazz', 'sunshine pop', 'spoken word', 'poetry']],
  ['pop', ['pop', 'dance-pop', 'dance pop', 'dance-rock', 'art pop', 'baroque pop', 'chamber pop',
           'sophisti-pop', 'europop', 'new pop', 'traditional pop', 'novelty', 'comedy',
           'adult contemporary', 'dance', 'easy listening', 'children', 'oldies', 'lounge',
           'vocal']],
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
  for (const [name, , broad] of GENRE_CATEGORIES) {
    if (broad?.some((k) => s.includes(k))) return name;
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
export function timbreMap(doc, { strict = false } = {}) {
  const m = new Map();
  const songs = doc?.songs && typeof doc.songs === 'object' ? doc.songs : {};
  // ── REFUSE TO MIX CALIBRATIONS ────────────────────────────────────────────────────────────
  // The rails are the UNITS, so a corpus written under different rails is not "slightly stale",
  // it is a different measurement of a different quantity. Attaching it to rec-features would
  // ship those numbers to every device and to the Lambda, where nothing could tell them apart
  // from correct ones. So: attach NOTHING, loudly.
  //
  // Loudly but NOT fatally by default. A catalog deploy carries artists, albums, play counts and
  // genres; failing the whole build over an out-of-date audio corpus would hold all of that
  // hostage to a librosa sweep. `--strict` (CI) makes it fatal.
  if (doc) {
    const v = Number.isFinite(doc.timbreVersion) ? doc.timbreVersion : 1;
    if (v !== TIMBRE_VERSION) {
      const msg = `[rec-features] TIMBRE CORPUS REFUSED: public/timbre.json is calibration v${v}, `
        + `this build speaks v${TIMBRE_VERSION}. No \`t\` fields attached — the timbre term will be `
        + 'dead until the corpus is re-extracted (node scripts/timbre-batch.mjs && node scripts/fold-timbre.mjs).';
      if (strict) throw new Error(msg);
      console.warn(`\n${'!'.repeat(100)}\n${msg}\n${'!'.repeat(100)}\n`);
      return m;
    }
  }
  for (const [id, row] of Object.entries(songs)) {
    // Same hygiene predicate the fold and the device apply — a reader must not depend on the
    // writer's discipline, and an all-zero row is a fake similarity cluster wherever it lands.
    if (row?.f && typeof row.f === 'object' && isUsableTimbreRow(row.f)) m.set(id, row.f);
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

/// ── DO NOT SILENTLY REPLACE A CORPUS WITH NOTHING ─────────────────────────────────────────────
/// `timbreMap`'s refusal is deliberately non-fatal so an out-of-date audio corpus cannot hold a
/// catalog deploy hostage. On its own, though, that turns the worst outcome into the QUIETEST one:
/// the nightly runs, the corpus is a version behind, a warning scrolls past in a log nobody reads,
/// and a rec-features.json carrying ZERO `t` fields overwrites one carrying 18,747 of them. The
/// timbre term then dies everywhere it is read, and the only symptom is a recommendation feed that
/// feels slightly worse.
///
/// So the file on disk gets a vote. Dropping a term the CURRENT artifact carries is a regression,
/// and a regression has to be asked for by name (`--allow-timbre-loss` — for the deliberate case,
/// e.g. retiring the corpus). Adding, growing or keeping the term is always fine, and a first run
/// with nothing on disk is fine.
export function assertNoTimbreRegression(doc, allowLoss = false, previous = readCurrentOutput()) {
  const had = previous?.songs?.some?.((s) => s && s.t) === true;
  const has = doc?.songs?.some?.((s) => s && s.t) === true;
  if (!had || has || allowLoss) return;
  const beforeCount = previous.songs.filter((s) => s && s.t).length;
  throw new Error(
    `[rec-features] REFUSING TO PUBLISH: the existing ${OUT} carries timbre vectors for `
    + `${beforeCount} songs (calibration v${previous.timbreVersion ?? 1}) and this build would `
    + 'attach NONE, silently killing the timbre term on every device and in the Lambda.\n'
    + '  Rebuild the corpus first:\n'
    + '    node scripts/timbre-batch.mjs && node scripts/fold-timbre.mjs\n'
    + '  Or pass --allow-timbre-loss if dropping the term is what you actually mean.');
}

function readCurrentOutput() {
  try {
    return existsSync(OUT) ? JSON.parse(readFileSync(OUT, 'utf8')) : null;
  } catch {
    return null;   // unreadable/half-written: nothing to protect, and this is not the place to fail
  }
}

async function main() {
  // Priority order for the appleMusicId dedupe: apple-music > digital > vinyl (keep first).
  const sources = [
    ['apple-music-index.json', await loadIndex('apple-music-index.json')],
    ['digital-index.json', await loadIndex('digital-index.json')],
    ['current-index.json', await loadIndex('current-index.json')],
  ];
  // Timbre corpus rides along when present (built by fold-timbre.mjs; absent = no `t` fields).
  const timbre = timbreMap(await loadIndex('timbre.json'), { strict: process.argv.includes('--strict') });
  if (timbre.size) console.log(`[rec-features] timbre corpus: ${timbre.size} songs (calibration v${TIMBRE_VERSION})`);
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
    // Which calibration the `t` vectors below speak, or null when none were attached. A reader
    // that finds a version it does not speak drops `t` outright rather than scoring foreign units.
    timbreVersion: timbre.size ? TIMBRE_VERSION : null,
    counts: { songs: songs.length },
    songs,
  };
  const json = JSON.stringify(doc);
  assertNoTimbreRegression(doc, process.argv.includes('--allow-timbre-loss'));
  writeFileSync(OUT, json);
  const mb = json.length / (1024 * 1024);
  console.log(`[rec-features] wrote ${OUT} — ${songs.length} songs, ${mb.toFixed(1)} MB`);
  if (mb > 20) console.warn('[rec-features] WARNING: output exceeds 20 MB — consider trimming fields');
}

// Import-safe (tests import genreCategory); run only as a CLI entry.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
