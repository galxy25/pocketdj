#!/usr/bin/env node
// MEASURE the artist concentration the owner reported ("each tile is recommending multiple Drake
// songs") on the REAL catalog, the REAL Apple play counts, and the REAL playlists — and ATTRIBUTE
// it, because the fix differs by cause:
//
//   · the PLAY-COUNT term        → reweight / renormalize it
//   · the ARTIST family          → rebalance `SimilarityFamilies`
//   · a missing per-artist cap   → add one
//   · catalogue skew             → not a bug at all ("he owns 400 Drake songs")
//
// Sibling of scripts/measure-similarity-families.mjs, which measured the three SIMILARITY families
// in isolation. This one measures the SHIPPED SURFACES end to end:
//
//   S1  collection tiles   — a port of `ZoneEngine.suggestions` (device, For You per-collection)
//   S2  In Da Zone         — a port of `ZoneEngine.inDaZone` + `PuzzleSimilarity` balanced mode
//   S3  cloud For You      — `scoreForYou` IMPORTED from the Lambda, not ported
//   S4  cloud similar      — `scoreSimilarToCollections`, likewise imported
//
// S1/S2 are ports; they are validated against the Swift by `--selftest`, which reproduces the
// arithmetic of the shipped constants on hand-checkable inputs.
//
//   node scripts/measure-rec-concentration.mjs [--collections 40] [--json out.json]

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const PUBLIC = join(ROOT, 'public');

const arg = (flag, dflt) => {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
};
const N_COLLECTIONS = Number(arg('--collections', 40));
const JSON_OUT = arg('--json', null);
// The play-count cache is a LOCAL artifact (index-out/ is not committed), so it is resolved from
// the main checkout by default and overridable.
const PLAYCOUNTS = arg('--playcounts',
  join(homedir(), 'forges/levi/pocketdj/index-out/apple-music/playcounts.json'));

const NOW = Date.parse('2026-08-10T12:00:00Z');
const DAY = 86_400_000;

// ══════════════════════════════════════════════════════════════════════════════════════════════
// Load
// ══════════════════════════════════════════════════════════════════════════════════════════════

const feats = JSON.parse(readFileSync(join(PUBLIC, 'rec-features.json'), 'utf8'));

/// `PuzzleSimilarity.artistKey` — diacritic + case insensitive, trimmed, leading "the " stripped.
function artistKey(a) {
  let s = String(a || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  if (s.startsWith('the ')) s = s.slice(4);
  return s;
}

const songs = feats.songs.map((r) => ({
  id: r.i,
  album: r.al ?? null,
  artist: r.a ?? '',
  artistKey: artistKey(r.a),
  name: r.n ?? '',
  genre: r.g ?? null,          // 'other' is already omitted upstream, matching zoneTracks' nil
  year: r.y ?? null,
  bpm: r.b ?? null,
  camelot: r.c ?? null,
  kw: r.s ?? null,
}));
const byId = new Map(songs.map((s) => [s.id, s]));
const N = songs.length;

const pcDoc = existsSync(PLAYCOUNTS) ? JSON.parse(readFileSync(PLAYCOUNTS, 'utf8')) : null;
if (!pcDoc) { console.error(`play-count cache not found: ${PLAYCOUNTS}`); process.exit(1); }
const playCount = new Map();     // songId -> n
const lastPlayed = new Map();    // songId -> epoch ms
for (const [id, row] of Object.entries(pcDoc.counts)) {
  if (row?.n > 0) playCount.set(id, row.n);
  if (row?.lastMs) lastPlayed.set(id, row.lastMs);
}
const pc = (id) => playCount.get(id) || 0;
// Hoisted: `maxPlays` is a fact about the catalog, recomputed per call in the Swift but constant.
let MAX_PLAYS = 0;
for (const [, n] of playCount) if (n > MAX_PLAYS) MAX_PLAYS = n;
const FAM_DENOM = Math.log2(1 + Math.max(MAX_PLAYS, 1));
const familiarityOf = (id) => { const n = pc(id); return n > 0 ? Math.log2(1 + n) / FAM_DENOM : 0; };

// ── Artist- and genre-level play aggregates (the axes a NOVELTY term could be built from that
//    are NOT a monotone transform of the song's own count). Built once.
const artistPlaysByKey = new Map();
const genrePlaysByCat = new Map();
for (const r of feats.songs) {
  const n = playCount.get(r.i) || 0;
  if (!(n > 0)) continue;
  const ak = artistKey(r.a);
  artistPlaysByKey.set(ak, (artistPlaysByKey.get(ak) || 0) + n);
  if (r.g) genrePlaysByCat.set(r.g, (genrePlaysByCat.get(r.g) || 0) + n);
}
const MAX_ARTIST_PLAYS = Math.max(1, ...artistPlaysByKey.values());
const MAX_GENRE_PLAYS = Math.max(1, ...genrePlaysByCat.values());
const artistFamiliarityOf = (ak) => {
  const p = artistPlaysByKey.get(ak) || 0;
  return p > 0 ? Math.log2(1 + p) / Math.log2(1 + MAX_ARTIST_PLAYS) : 0;
};
const genreFamiliarityOf = (g) => {
  const p = g ? (genrePlaysByCat.get(g) || 0) : 0;
  return p > 0 ? Math.log2(1 + p) / Math.log2(1 + MAX_GENRE_PLAYS) : 0;
};

/// The PRIMARY artist of a credit string — what a per-artist cap has to key on if it is to treat
/// "Drake" and "Drake & Future" as the same budget.
///
/// IMPORTED from the Lambda rather than re-implemented here. This started as a local regex and
/// that was a mistake in the making: the measurement's whole value is that it reports what the
/// SHIPPED code does, and a splitter that drifts from the shipped one (the Lambda's handles
/// "Tyler, The Creator"; the regex did not) reports a fix that was never made. `RecNovelty
/// .primaryArtistKey` on the device is the third copy, and it is pinned against these by
/// `RecNoveltyTests` and `test-rec-engine.mjs` asserting the same table of credits.
const { primaryArtistKey } = await import('./lambda/rec-engine/index.mjs');

// Collections: the Apple Music index's own user playlists — the closest thing on disk to
// `CollectionsStore.suggestibleCollections()`.
const amIndex = JSON.parse(readFileSync(join(PUBLIC, 'apple-music-index.json'), 'utf8'));
const allPlaylists = (amIndex.playlists || [])
  .map((p) => ({ id: p.id, name: p.name, songIds: (p.songIds || []).filter((x) => byId.has(x)) }))
  .filter((p) => p.songIds.length >= 5);

// ══════════════════════════════════════════════════════════════════════════════════════════════
// SimilarityFamilies — ported verbatim from apple/PocketDJ/Services/Recommendations
// ══════════════════════════════════════════════════════════════════════════════════════════════

const BALANCE_EVEN = { artist: 0.25, genreYear: 0.375, genreMusical: 0.375 };
const W = { artist: 0.30, genre: 0.25, year: 0.15, coMember: 0.12, lyrics: 0.10, coPlay: 0.08, recency: 0.05 };
const FAMILY_TOTAL = W.artist + W.genre + W.year;    // 0.70
const TEMPO_SIGMA_OCT = 0.10;
const TRIPLET = 0.6;
const MAX_TEMPO_MODES = 6;
const FALLBACK_NEUTRAL = 0.34;
const MIN_OBS_ROUND_NEUTRAL = 25;
const MUSICAL_PRIOR = 2.0;
const RECENCY_HALF_LIFE = 730;

function termWeights(balance, hasGenre, hasYear, hasMusical, scaledTo = FAMILY_TOTAL) {
  let w = { artist: balance.artist, genre: 0, year: 0, musical: 0 };
  const bLive = (hasGenre ? 1 : 0) + (hasYear ? 1 : 0);
  if (bLive > 0) {
    const each = balance.genreYear / bLive;
    if (hasGenre) w.genre += each;
    if (hasYear) w.year += each;
  }
  const cLive = (hasGenre ? 1 : 0) + (hasMusical ? 1 : 0);
  if (cLive > 0) {
    const each = balance.genreMusical / cLive;
    if (hasGenre) w.genre += each;
    if (hasMusical) w.musical += each;
  }
  const sum = w.artist + w.genre + w.year + w.musical;
  if (!(sum > 0) || !(scaledTo > 0)) return { artist: 0, genre: 0, year: 0, musical: 0 };
  const k = scaledTo / sum;
  return { artist: w.artist * k, genre: w.genre * k, year: w.year * k, musical: w.musical * k };
}

const ALL_CAMELOT = [];
for (let n = 1; n <= 12; n++) { ALL_CAMELOT.push(`${n}A`); ALL_CAMELOT.push(`${n}B`); }

function parseCamelot(raw) {
  const s = String(raw || '').trim().toUpperCase();
  const m = /^(\d{1,2})([AB])$/.exec(s);
  if (!m) return null;
  const n = Number(m[1]);
  return n >= 1 && n <= 12 ? { n, letter: m[2] } : null;
}
function camelotRelatedness(a, b) {
  const x = parseCamelot(a), y = parseCamelot(b);
  if (!x || !y) return 0;
  if (x.n === y.n && x.letter === y.letter) return 1;
  if (x.n === y.n) return 0.75;
  if (x.letter !== y.letter) return 0;
  const up = (x.n % 12) + 1, down = ((x.n + 10) % 12) + 1;
  return (y.n === up || y.n === down) ? 0.6 : 0;
}
function musicalProfile(members) {
  const p = { tempoModes: [], camelotWeight: new Map(), tempoPeak: 0, camelotPeak: 0 };
  const buckets = new Map();
  for (const m of members) {
    const w = Math.max(0, m.weight);
    if (!(w > 0)) continue;
    if (m.bpm > 0) { const k = Math.round(m.bpm); buckets.set(k, (buckets.get(k) || 0) + w); }
    if (m.camelot) {
      const c = String(m.camelot).trim().toUpperCase();
      if (c) p.camelotWeight.set(c, (p.camelotWeight.get(c) || 0) + w);
    }
  }
  p.tempoModes = [...buckets.entries()]
    .sort((a, b) => (b[1] - a[1]) || (a[0] - b[0]))
    .slice(0, MAX_TEMPO_MODES)
    .map(([bpm, weight]) => ({ bpm, weight }));
  p.tempoPeak = Math.max(0, ...p.tempoModes.map((m) => tempoDensity(m.bpm, p)));
  p.camelotPeak = Math.max(0, ...ALL_CAMELOT.map((c) => camelotDensity(c, p)));
  return p;
}
const musicalEmpty = (p) => p.tempoModes.length === 0 && p.camelotWeight.size === 0;
function tempoDensity(bpm, p) {
  if (!(bpm > 0)) return 0;
  let sum = 0;
  for (const m of p.tempoModes) if (m.bpm > 0) sum += m.weight * Math.exp(-Math.abs(Math.log2(bpm / m.bpm)) / TEMPO_SIGMA_OCT);
  return sum;
}
function camelotDensity(code, p) {
  let sum = 0;
  for (const [c, w] of p.camelotWeight) sum += w * camelotRelatedness(code, c);
  return sum;
}
function bpmAffinity(bpm, p) {
  if (!(bpm > 0) || !p.tempoModes.length || !(p.tempoPeak > 0)) return 0;
  const related = [[bpm, 1], [bpm / 2, 1], [bpm * 2, 1], [bpm * 2 / 3, TRIPLET], [bpm * 3 / 2, TRIPLET]];
  let best = 0;
  for (const [b, s] of related) best = Math.max(best, s * tempoDensity(b, p) / p.tempoPeak);
  return Math.min(1, best);
}
function camelotAffinity(code, p) {
  if (!code || !p.camelotWeight.size || !(p.camelotPeak > 0) || !parseCamelot(code)) return 0;
  return Math.min(1, camelotDensity(code, p) / p.camelotPeak);
}
function rawMusicalFit(bpm, camelot, p) {
  const terms = [];
  if (p.tempoModes.length && bpm > 0) terms.push(bpmAffinity(bpm, p));
  if (p.camelotWeight.size && camelot) terms.push(camelotAffinity(camelot, p));
  if (!terms.length) return null;
  return { fit: terms.reduce((a, b) => a + b, 0) / terms.length, observations: terms.length };
}
function calibrate(candidates, p) {
  if (musicalEmpty(p)) return { neutral: FALLBACK_NEUTRAL, observations: 0 };
  let sum = 0, n = 0;
  for (const c of candidates) {
    const r = rawMusicalFit(c.bpm, c.camelot, p);
    if (!r) continue;
    sum += r.fit; n += 1;
  }
  return { neutral: n >= MIN_OBS_ROUND_NEUTRAL ? sum / n : FALLBACK_NEUTRAL, observations: n };
}
function musicalFit(bpm, camelot, p, cal) {
  const r = rawMusicalFit(bpm, camelot, p);
  if (!r) return cal.neutral;
  return (MUSICAL_PRIOR * cal.neutral + r.observations * r.fit) / (MUSICAL_PRIOR + r.observations);
}
const recencyScore = (lastMs, nowMs) =>
  (lastMs > 0 ? Math.pow(0.5, Math.max(0, (nowMs - lastMs) / DAY) / RECENCY_HALF_LIFE) : 0);

// ══════════════════════════════════════════════════════════════════════════════════════════════
// S1 — ZoneEngine.suggestions (device collection tiles), ported
// ══════════════════════════════════════════════════════════════════════════════════════════════

const TUNING = { familiarityWeight: 0.30, maxPerArtist: 3, limit: 25, balance: BALANCE_EVEN };

/// The SHIPPED-BEFORE shape, kept so the report can print a genuine before/after off ONE harness
/// rather than comparing today's numbers against a paragraph from last week.
const TUNING_BEFORE = { ...TUNING, mode: 'additive', capKey: 'artistKey' };
/// The SHIPPED-AFTER shape — mirrors `ZoneEngine.Tuning`'s novelty knobs exactly. Changing these
/// without changing the Swift (or vice versa) is what makes a harness lie, so they are named the
/// same and live next to each other.
const TUNING_AFTER = {
  ...TUNING, mode: 'multiplicative', capKey: 'primaryKey',
  suggestionAuxGain: 0.40, suggestionNoveltyWeight: 0.75, suggestionFamiliarityWeight: 0.25,
};

/// ARTIST-level familiarity keyed on the PRIMARY artist — `RecNovelty.ArtistFamiliarity`, ported.
/// Rolled up to the primary artist for the same reason the app does it: keyed on the raw credit,
/// "Drake & Future" is an artist with almost no plays and would score as NOVEL.
const artistPlaysByPrimary = new Map();
for (const s of songs) {
  const n = pc(s.id);
  if (n > 0) {
    const k = primaryArtistKey(s.artist);
    artistPlaysByPrimary.set(k, (artistPlaysByPrimary.get(k) || 0) + n);
  }
}
const MAX_PRIMARY_ARTIST_PLAYS = Math.max(0, ...artistPlaysByPrimary.values());
const primaryArtistNovelty = (k) => {
  if (!(MAX_PRIMARY_ARTIST_PLAYS > 0)) return 0;
  const p = artistPlaysByPrimary.get(k) || 0;
  return 1 - (p > 0 ? Math.log2(1 + p) / Math.log2(1 + MAX_PRIMARY_ARTIST_PLAYS) : 0);
};

/**
 * Faithful port of `ZoneEngine.suggestions`. `opts` exposes the knobs the attribution needs:
 *   famWeight  — `Tuning.familiarityWeight` (the additive lifetime-play term)
 *   balance    — `SimilarityFamilies.Balance`
 *   maxPerArtist — the diversity cap (Infinity ⇒ measure what the cap is hiding)
 * Returns the ranked ids AND the per-candidate term breakdown, for the correlations.
 */
function suggestions(memberIds, opts = {}) {
  const famWeight = opts.famWeight ?? TUNING.familiarityWeight;
  const balance = opts.balance ?? TUNING.balance;
  const cap = opts.maxPerArtist ?? TUNING.maxPerArtist;
  const limit = opts.limit ?? TUNING.limit;
  const members = new Set(memberIds);
  if (!members.size) return null;

  const artists = new Map(); const genres = new Map();
  const years = []; const musicalMembers = [];
  for (const id of members) {
    const t = byId.get(id);
    if (!t) continue;
    artists.set(t.artistKey, (artists.get(t.artistKey) || 0) + 1);
    if (t.genre) genres.set(t.genre, (genres.get(t.genre) || 0) + 1);
    if (t.year != null) years.push(t.year);
    if (t.bpm != null || t.camelot != null) musicalMembers.push({ bpm: t.bpm, camelot: t.camelot, weight: 1 });
  }
  if (!artists.size && !genres.size) return null;
  const maxA = Math.max(...artists.values());
  if (maxA > 0) for (const [k, v] of artists) artists.set(k, v / maxA);
  const maxG = genres.size ? Math.max(...genres.values()) : 0;
  if (maxG > 0) for (const [k, v] of genres) genres.set(k, v / maxG);

  let year = null;
  if (years.length) {
    const m = years.reduce((a, b) => a + b, 0) / years.length;
    const v = years.reduce((a, b) => a + (b - m) * (b - m), 0) / years.length;
    year = { mean: m, sigma: Math.max(8, Math.sqrt(v)) };
  }
  const musical = musicalProfile(musicalMembers);
  const terms = termWeights(balance, genres.size > 0, year != null, !musicalEmpty(musical), 1.0);
  const cal = calibrate(songs, musical);

  const scored = [];
  for (const t of songs) {
    if (members.has(t.songId ?? t.id)) continue;
    const a = artists.get(t.artistKey) || 0;
    const g = t.genre ? (genres.get(t.genre) || 0) : 0;
    if (!(a > 0 || g > 0)) continue;
    const tA = terms.artist * a;
    const tG = terms.genre * g;
    const tY = (year && t.year != null) ? terms.year * Math.exp(-Math.abs(t.year - year.mean) / year.sigma) : 0;
    const tM = terms.musical > 0 ? terms.musical * musicalFit(t.bpm, t.camelot, musical, cal) : 0;
    const sim = Math.max(0, tA + tG + tY + tM);
    if (!(sim > 0)) continue;
    const n = pc(t.id);
    const fam = familiarityOf(t.id);
    const pk = primaryArtistKey(t.artist);
    const novPrimary = primaryArtistNovelty(pk);
    // BEFORE: the play term ADDED on top of a similarity normalized to 1.0 — i.e. 23% of the
    // maximum achievable score, a larger weight than the entire artist family's 0.25.
    // AFTER: a BOUNDED MULTIPLIER, so a candidate can never outrank one whose similarity is more
    // than `1 + gain` times its own. Both live here so the report can print one against the other.
    let net;
    if (opts.mode === 'multiplicative') {
      const wn = opts.suggestionNoveltyWeight ?? 0.75;
      const wf = opts.suggestionFamiliarityWeight ?? 0.25;
      const gain = opts.suggestionAuxGain ?? 0.30;
      const aux = MAX_PRIMARY_ARTIST_PLAYS > 0 ? (wn * novPrimary + wf * fam) / (wn + wf) : 0;
      net = sim * (1 + gain * aux);
    } else {
      net = sim + fam * famWeight;
    }
    if (!(net > 0)) continue;
    scored.push({ id: t.id, artistKey: t.artistKey, primaryKey: pk,
                  artist: t.artist, score: net,
                  tA, tG, tY, tM, fam: fam * famWeight, sim, n,
                  // Raw 0…1 axes, kept unweighted so the driver can re-rank without re-scoring.
                  famRaw: fam,
                  novSong: 1 - fam,
                  novArtist: 1 - artistFamiliarityOf(t.artistKey),
                  novPrimary,
                  novGenre: 1 - genreFamiliarityOf(t.genre),
                  dormancy: 1 - recencyScore(lastPlayed.get(t.id) || 0, NOW) });
  }
  scored.sort((x, y) => (y.score - x.score) || (x.id < y.id ? -1 : 1));

  const capField = opts.capKey ?? 'artistKey';
  const perArtist = new Map();
  const out = [];
  for (const c of scored) {
    if (out.length >= limit) break;
    const k = perArtist.get(c[capField]) || 0;
    if (k >= cap) continue;
    perArtist.set(c[capField], k + 1);
    out.push(c);
  }
  return { picks: out, scored, terms, candidates: scored.length };
}

// ══════════════════════════════════════════════════════════════════════════════════════════════
// S2 — ZoneEngine.inDaZone, ported (PuzzleSimilarity balanced mode)
// ══════════════════════════════════════════════════════════════════════════════════════════════

const ZT = {
  halfLifeDays: 7, rediscoveryQuietDays: 60, cooldownHours: 6, maxPerArtist: 3,
  minSongs: 30, maxSongs: 90, rediscoveryFloor: 0.5, familiarityWeight: 0.30,
  auxGain: 0.6, dormancyWeight: 0.40, auxFamiliarityWeight: 0.30, auxNoveltyWeight: 0.30,
  shortlistCap: 6000,
};

function zoneProfile(tasteWeight, crates, balance) {
  const p = { artistShare: new Map(), maxArtistShare: 0, genreShare: new Map(), maxGenreShare: 0,
              yearMean: null, yearSigma: 8, keywordShare: new Map(), maxKeywordShare: 0,
              musical: null, cal: { neutral: FALLBACK_NEUTRAL, observations: 0 }, terms: null,
              coMemberIds: new Set(), availableWeight: 0, memberIds: new Set(tasteWeight.keys()) };
  const artistCount = new Map(), genreCount = new Map(), keywordCount = new Map();
  const years = []; let keywordBearers = 0; let resolved = 0;
  const musicalMembers = [];
  for (const [id, w0] of tasteWeight) {
    const s = byId.get(id);
    if (!s) continue;
    const w = Math.max(0, w0);
    if (!(w > 0)) continue;
    resolved += w;
    artistCount.set(s.artistKey, (artistCount.get(s.artistKey) || 0) + w);
    if (s.genre) genreCount.set(s.genre, (genreCount.get(s.genre) || 0) + w);
    if (s.year != null) years.push([s.year, w]);
    if (s.kw?.length) {
      keywordBearers += w;
      for (const k of new Set(s.kw.map((x) => x.toLowerCase()))) keywordCount.set(k, (keywordCount.get(k) || 0) + w);
    }
    if (balance && (s.bpm != null || s.camelot != null)) musicalMembers.push({ bpm: s.bpm, camelot: s.camelot, weight: w });
  }
  if (!(resolved > 0)) return p;
  for (const [k, v] of artistCount) p.artistShare.set(k, v / resolved);
  p.maxArtistShare = Math.max(0, ...p.artistShare.values());
  for (const [k, v] of genreCount) p.genreShare.set(k, v / resolved);
  p.maxGenreShare = p.genreShare.size ? Math.max(...p.genreShare.values()) : 0;
  if (years.length) {
    const wS = years.reduce((a, [, w]) => a + w, 0);
    const mean = years.reduce((a, [y, w]) => a + y * w, 0) / wS;
    p.yearMean = mean;
    p.yearSigma = Math.max(8, Math.sqrt(years.reduce((a, [y, w]) => a + w * (y - mean) ** 2, 0) / wS));
  }
  if (keywordBearers > 0) {
    const shares = [...keywordCount.entries()].map(([k, v]) => [k, v / keywordBearers])
      .sort((a, b) => (b[1] - a[1]) || (a[0] < b[0] ? 1 : -1)).slice(0, 20);
    p.keywordShare = new Map(shares);
    p.maxKeywordShare = shares.length ? Math.max(...shares.map((x) => x[1])) : 0;
  }
  for (const ids of crates) {
    const set = new Set(ids);
    let touches = false;
    for (const id of set) if (p.memberIds.has(id)) { touches = true; break; }
    if (!touches) continue;
    for (const id of set) if (!p.memberIds.has(id)) p.coMemberIds.add(id);
  }
  if (balance) {
    p.musical = musicalProfile(musicalMembers);
    p.terms = termWeights(balance, p.genreShare.size > 0, p.yearMean != null, !musicalEmpty(p.musical));
  }
  let w = 0;
  if (p.terms) {
    if (p.artistShare.size) w += p.terms.artist;
    if (p.genreShare.size) w += p.terms.genre;
    if (p.yearMean != null) w += p.terms.year;
    w += p.terms.musical;
  } else {
    if (p.artistShare.size) w += W.artist;
    if (p.genreShare.size) w += W.genre;
    if (p.yearMean != null) w += W.year;
  }
  if (p.keywordShare.size) w += W.lyrics;
  if (p.coMemberIds.size) w += W.coMember;
  p.availableWeight = w;
  return p;
}
const zoneCalibrate = (p) => { if (p.terms && p.musical && !musicalEmpty(p.musical)) p.cal = calibrate(songs, p.musical); };

function zoneScore(s, p) {
  if (!(p.availableWeight > 0)) return { score: 0 };
  const tArtist = p.terms?.artist ?? W.artist;
  const tGenre = p.terms?.genre ?? W.genre;
  const tYear = p.terms?.year ?? W.year;
  let local = 0; const parts = {};
  if (p.artistShare.size) {
    const share = p.artistShare.get(s.artistKey) || 0;
    parts.artist = tArtist * Math.min(1, share / Math.max(0.05, p.maxArtistShare));
    local += parts.artist;
  }
  if (p.genreShare.size && p.maxGenreShare > 0) {
    const share = s.genre ? (p.genreShare.get(s.genre) || 0) : 0;
    parts.genre = tGenre * Math.min(1, share / p.maxGenreShare);
    local += parts.genre;
  }
  if (p.yearMean != null && s.year != null) {
    parts.year = tYear * Math.exp(-Math.abs(s.year - p.yearMean) / Math.max(8, p.yearSigma));
    local += parts.year;
  }
  if (p.terms && p.terms.musical > 0) {
    parts.musical = p.terms.musical * musicalFit(s.bpm, s.camelot, p.musical, p.cal);
    local += parts.musical;
  }
  if (p.keywordShare.size && p.maxKeywordShare > 0) {
    const hits = (s.kw || []).map((x) => x.toLowerCase()).filter((k) => p.keywordShare.has(k))
      .map((k) => p.keywordShare.get(k));
    if (hits.length) { parts.lyrics = W.lyrics * Math.min(1, hits.reduce((a, b) => a + b, 0) / p.maxKeywordShare); local += parts.lyrics; }
  }
  if (p.coMemberIds.size && p.coMemberIds.has(s.id)) { parts.coMember = W.coMember; local += W.coMember; }
  return { score: Math.min(1, Math.max(0, local / p.availableWeight)), parts };
}

/** Faithful port of `ZoneEngine.inDaZone`. `plays` = [{songId, playedAtMs}]. */
function inDaZone(plays, crates, opts = {}) {
  const famWeight = opts.famWeight ?? ZT.familiarityWeight;
  const auxGain = opts.auxGain ?? ZT.auxGain;
  const balance = opts.balance ?? BALANCE_EVEN;
  const cap = opts.maxPerArtist ?? ZT.maxPerArtist;
  const windowMs = ZT.rediscoveryQuietDays * DAY;
  const cooldownMs = ZT.cooldownHours * 3_600_000;
  const halfLifeMs = ZT.halfLifeDays * DAY;

  const seedWeight = new Map(); const onCooldown = new Set();
  for (const p of plays) {
    const age = NOW - p.playedAtMs;
    if (age < cooldownMs) onCooldown.add(p.songId);
    if (age > windowMs || !byId.has(p.songId)) continue;
    seedWeight.set(p.songId, (seedWeight.get(p.songId) || 0) + Math.pow(2, -Math.max(0, age) / halfLifeMs));
  }
  const taste = zoneProfile(seedWeight, crates, balance);
  zoneCalibrate(taste);

  const familiarity = familiarityOf;
  const hasDormancy = lastPlayed.size > 0;
  const hasFamiliarity = MAX_PLAYS > 0;
  // `wNovelty` is exposed so the report can ABLATE the artist-novelty term (0) and print the
  // rediscovery pool with and without it. Defaults to the shipped weight, so the port stays a
  // faithful model of `ZoneEngine.inDaZone` rather than a snapshot of what it used to be.
  const wNovelty = opts.auxNoveltyWeight ?? ZT.auxNoveltyWeight;
  const hasNovelty = MAX_PRIMARY_ARTIST_PLAYS > 0 && wNovelty > 0;
  const capKeyOf = (s) => primaryArtistKey(s.artist);
  const auxOnly = (id, capKey) => {
    let num = 0, den = 0;
    if (hasDormancy) { num += ZT.dormancyWeight * (1 - recencyScore(lastPlayed.get(id) || 0, NOW)); den += ZT.dormancyWeight; }
    if (hasFamiliarity) { num += ZT.auxFamiliarityWeight * familiarity(id); den += ZT.auxFamiliarityWeight; }
    if (hasNovelty) { num += wNovelty * primaryArtistNovelty(capKey); den += wNovelty; }
    return den > 0 ? num / den : 0;
  };

  const familiarPool = []; const fallbackPool = []; const prescored = [];
  const tasteEmpty = !(taste.availableWeight > 0);
  for (const s of songs) {
    const id = s.id;
    if (onCooldown.has(id)) continue;
    // The CAP key is the primary artist (so "Drake & Future" spends Drake's budget); the
    // SIMILARITY key stays the raw credit's, because that is how the taste profile was built.
    const capKey = capKeyOf(s);
    if (seedWeight.has(id)) {
      familiarPool.push({ id, artist: capKey, score: seedWeight.get(id) + familiarity(id) * famWeight });
      continue;
    }
    const lp = lastPlayed.get(id);
    if (lp && NOW - lp < windowMs) continue;
    const artistHit = taste.artistShare.has(s.artistKey);
    const genreHit = s.genre ? taste.genreShare.has(s.genre) : false;
    const related = artistHit || genreHit || taste.coMemberIds.has(id);
    if (!tasteEmpty && !related) { fallbackPool.push({ id, artist: capKey, score: auxOnly(id, capKey) }); continue; }
    prescored.push({ s, artist: capKey, pre: (artistHit ? 2 : 0) + (genreHit ? 1 : 0) + auxOnly(id, capKey) });
  }
  prescored.sort((a, b) => (b.pre - a.pre) || (a.s.id < b.s.id ? -1 : 1));
  const perArtistQuota = Math.max(4, ZT.maxPerArtist * 3);
  const quota = new Map(); const shortlist = [];
  for (const c of prescored) {
    if (shortlist.length >= ZT.shortlistCap) break;
    const n = quota.get(c.artist) || 0;
    if (n >= perArtistQuota) continue;
    quota.set(c.artist, n + 1);
    shortlist.push(c);
  }
  const rediscoveryPool = [];
  const auxBaseDen = ZT.dormancyWeight * (hasDormancy ? 1 : 0)
    + ZT.auxFamiliarityWeight * (hasFamiliarity ? 1 : 0) + (hasNovelty ? wNovelty : 0);
  for (const c of shortlist) {
    const sim = tasteEmpty ? 1 : zoneScore(c.s, taste).score;
    if (!(sim > 0)) continue;
    const aux = auxBaseDen > 0 ? auxOnly(c.s.id, c.artist) : 0;
    rediscoveryPool.push({ id: c.s.id, artist: c.artist, score: sim * (1 + auxGain * aux),
                           sim, aux, fam: familiarity(c.s.id) });
  }
  const byScore = (a, b) => (b.score - a.score) || (a.id < b.id ? -1 : 1);
  familiarPool.sort(byScore); rediscoveryPool.sort(byScore); fallbackPool.sort(byScore);

  const recentArtists = new Set();
  for (const id of seedWeight.keys()) { const s = byId.get(id); if (s) recentArtists.add(s.artistKey); }
  const target = Math.min(ZT.maxSongs, Math.max(ZT.minSongs, ZT.maxPerArtist * recentArtists.size));

  const perArtist = new Map();
  let fi = 0, ri = 0, rediscoveryCount = 0;
  const picks = [];
  const take = (pool, cursorRef) => {
    while (cursorRef.i < pool.length) {
      const c = pool[cursorRef.i]; cursorRef.i += 1;
      if ((perArtist.get(c.artist) || 0) < cap) { perArtist.set(c.artist, (perArtist.get(c.artist) || 0) + 1); return c; }
    }
    return null;
  };
  const fc = { i: 0 }, rc = { i: 0 };
  while (picks.length < target) {
    const wantRe = rediscoveryCount < ZT.rediscoveryFloor * (picks.length + 1);
    const order = wantRe ? ['rediscovery', 'familiar'] : ['familiar', 'rediscovery'];
    let got = false;
    for (const pool of order) {
      const c = pool === 'rediscovery' ? take(rediscoveryPool, rc) : take(familiarPool, fc);
      if (!c) continue;
      picks.push({ ...c, pool });
      if (pool === 'rediscovery') rediscoveryCount += 1;
      got = true; break;
    }
    if (!got) break;
  }
  const bc = { i: 0 };
  while (picks.length < ZT.minSongs) { const c = take(fallbackPool, bc); if (!c) break; picks.push({ ...c, pool: 'rediscovery' }); }
  fi = fc.i; ri = rc.i;
  return { picks, rediscoveryPool, familiarPool, taste, target, _cursors: { fi, ri } };
}

// ══════════════════════════════════════════════════════════════════════════════════════════════
// Stats helpers
// ══════════════════════════════════════════════════════════════════════════════════════════════

function artistStats(rows) {
  const per = new Map();
  for (const r of rows) per.set(r.artist || r.artistKey, (per.get(r.artist || r.artistKey) || 0) + 1);
  const sorted = [...per.entries()].sort((a, b) => (b[1] - a[1]) || (a[0] < b[0] ? -1 : 1));
  const n = rows.length;
  return {
    n, distinct: per.size,
    top: sorted[0]?.[0] ?? null, topN: sorted[0]?.[1] ?? 0,
    topShare: n ? (sorted[0]?.[1] ?? 0) / n : 0,
    atLeast3: sorted.filter((x) => x[1] >= 3).length,
    atLeast2: sorted.filter((x) => x[1] >= 2).length,
    table: sorted,
  };
}
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0);
function pearson(xs, ys) {
  const n = xs.length; if (n < 2) return 0;
  const mx = mean(xs), my = mean(ys);
  let num = 0, dx = 0, dy = 0;
  for (let i = 0; i < n; i++) { const a = xs[i] - mx, b = ys[i] - my; num += a * b; dx += a * a; dy += b * b; }
  return dx > 0 && dy > 0 ? num / Math.sqrt(dx * dy) : 0;
}
function ranks(xs) {
  const idx = xs.map((v, i) => [v, i]).sort((a, b) => a[0] - b[0]);
  const r = new Array(xs.length);
  let i = 0;
  while (i < idx.length) {
    let j = i; while (j + 1 < idx.length && idx[j + 1][0] === idx[i][0]) j++;
    const avg = (i + j) / 2 + 1;
    for (let k = i; k <= j; k++) r[idx[k][1]] = avg;
    i = j + 1;
  }
  return r;
}
const spearman = (xs, ys) => pearson(ranks(xs), ranks(ys));
const jaccard = (a, b) => { const B = new Set(b); let i = 0; for (const x of a) if (B.has(x)) i++; return i / (a.length + b.length - i); };
const pctl = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * q)))];

export { songs, byId, playCount, lastPlayed, suggestions, inDaZone, allPlaylists, artistStats,
         spearman, pearson, jaccard, NOW, N, pc, mean, pctl, recencyScore, artistKey,
         primaryArtistKey, familiarityOf, artistFamiliarityOf, genreFamiliarityOf,
         primaryArtistNovelty, TUNING_BEFORE, TUNING_AFTER };
