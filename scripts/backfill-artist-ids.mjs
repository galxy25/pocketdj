#!/usr/bin/env node
// Stamp Apple Music ARTIST ids onto the shared catalog index — the prerequisite for the release
// feed (GET /v1/catalog/us/artists?ids=…&views=latest-release,similar-artists needs artist ids,
// and songs only carry TRACK ids).
//
// ── WHY A SEPARATE `artists` ARRAY AND NOT A PER-SONG `artistId` FIELD ──────────────────────
// Measured on the live index (96,021 songs / 12,656 distinct artist names):
//
//   • DUPLICATION. artistId is a property of the ARTIST, not the song. A per-song field writes
//     the same 9-digit int once per song — ~10x amplification (96k songs over ~9.9k resolvable
//     artists). At ~22 bytes of JSON per song that is ~2.1 MB added to a 55 MB document that
//     EVERY install downloads. The normalized table is ~300 KB — a 7x saving for strictly more
//     information (it also carries the song count and the ambiguity alternates).
//
//   • ACCESS SHAPE. The release feed's unit of work is the ARTIST: "which artists did he play
//     recently, and which of those have a new release". A per-song field forces a full 96k-row
//     scan + dedupe every time that set is generated. The table IS the deduped set.
//
//   • RESOLUTION REACH. A store-id→artistId join only reaches songs that HAVE a store id
//     (76,646 of 96,021). Keying by artist NAME propagates the id to the other 14,979 songs
//     whose artist is known from a sibling track but which carry no store id of their own —
//     free coverage a per-song join cannot reach.
//
// AMBIGUITY, MEASURED NOT ASSUMED. 9,716 names map to exactly one artistId; 175 (1.8%) map to
// several. Those splits are lopsided and are compilation/feature credits, not real collisions —
// "Drake" is 271256 with 314 songs plus four ids with 1-2 songs each. The table stores the
// DOMINANT id (most songs) and keeps the losers in `alt`, so nothing is discarded. For a release
// feed the dominant id is also the RIGHT answer: a one-off compilation credit should still map
// to the artist the owner actually listens to.
//
// NAME KEY is normalized (trim + casefold + whitespace collapse) — that merges the 41 names with
// multiple raw spellings ("BANKS"/"Banks", "USHER"/"Usher"). `name` keeps the most common raw
// spelling for display. The app must normalize identically to join.
//
// NOTHING PERSONAL. Artist ids are public catalog data. No play counts, no dates, no per-install
// state goes in this document — it is shared with every install.
//
// ── COST ────────────────────────────────────────────────────────────────────────────────────
// Tier 1 is FREE: index-out/apple-music/song-meta.ndjson (harvested by the explicit-variant
// crawl) already holds {id, artistId} for 75,299 track ids and resolves 97.8% of store-id songs
// with ZERO network. Tier 2 crawls only the names Tier 1 leaves unresolved, and only needs ONE
// successful track lookup per NAME (not per song) — it sends a few representative ids per name.
// iTunes LOOKUP is used, never SEARCH: search silently filters explicit rows (see
// itunes-search-filters-explicit); lookup is unfiltered. 100 ids per request is the documented cap.
//
// Resumable (own ndjson cache, append-on-success), atomic writes, idempotent.
//
//   node --max-old-space-size=4096 scripts/backfill-artist-ids.mjs [--dry-run] [--limit N]

import { mkdirSync, readFileSync, writeFileSync, renameSync, existsSync, appendFileSync } from 'node:fs';

const INDEX = 'public/apple-music-index.json';
const SONG_META = 'index-out/apple-music/song-meta.ndjson';
const CACHE = 'index-out/apple-music/artist-id-cache.ndjson';
const LOOKUP = 'https://itunes.apple.com/lookup';

// iTunes lookup caps a batch at 100 ids. Concurrency stays LOW on purpose: the Apple edge rate
// limiter is bursty (a 40-way fan-out against the catalog API returned 24x HTTP 429), so this
// runs 2 batches at a time with exponential backoff on 429/5xx.
const BATCH = 100;
const CONCURRENCY = 2;
const MAX_RETRY = 5;
/** Representative track ids sent per unresolved name — a name needs only ONE to resolve; the
 *  extras are fallbacks for ids that have left the catalog. */
const IDS_PER_NAME = 3;

const args = {
  dryRun: process.argv.includes('--dry-run'),
  limit: (() => { const i = process.argv.indexOf('--limit'); return i >= 0 ? Number(process.argv[i + 1]) : Infinity; })(),
};

const norm = (s) => String(s).trim().toLowerCase().replace(/\s+/g, ' ');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function atomicWriteJSON(file, obj) {
  const tmp = file + '.tmp';
  writeFileSync(tmp, JSON.stringify(obj));
  renameSync(tmp, file);
}

/** Read an ndjson file into a callback; missing file is not an error (first run). */
function readNdjson(file, onRow) {
  if (!existsSync(file)) return 0;
  let n = 0;
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try { onRow(JSON.parse(line)); n++; } catch { /* a torn last line from a killed run */ }
  }
  return n;
}

/** Returns the results array on a SUCCESSFUL request (possibly empty — that means the catalog
 *  genuinely knows none of these ids), or `null` if the request never succeeded. The caller relies
 *  on that distinction: empty-but-successful is what licenses writing negative cache entries, and
 *  conflating it with failure would poison the cache with 100 false permanent misses. */
async function lookupBatch(ids) {
  const url = `${LOOKUP}?id=${ids.join(',')}&entity=song&limit=200`;
  for (let attempt = 0; attempt <= MAX_RETRY; attempt++) {
    try {
      const r = await fetch(url);
      if (r.status === 429 || r.status >= 500) {
        const wait = Math.min(30000, 1000 * 2 ** attempt);
        console.error(`  … HTTP ${r.status}, backing off ${wait}ms`);
        await sleep(wait);
        continue;
      }
      if (!r.ok) return null;
      const j = await r.json();
      return j.results || [];
    } catch (e) {
      const wait = Math.min(30000, 1000 * 2 ** attempt);
      console.error(`  … ${e.message}, retry in ${wait}ms`);
      await sleep(wait);
    }
  }
  return null;
}

async function main() {
  console.error('→ loading index …');
  const index = JSON.parse(readFileSync(INDEX, 'utf8'));
  const songs = index.songs || [];

  // ── Tier 1: the free cache ────────────────────────────────────────────────────────────────
  const trackToArtist = new Map(); // storeId(str) -> artistId(num)
  // Ids the catalog has already told us it does not know (delisted / region-gone). Cached as
  // NEGATIVES so a re-run doesn't re-request them forever — without this the crawl re-sends a
  // batch of permanent misses on every single run.
  const known404 = new Set();
  const metaRows = readNdjson(SONG_META, (o) => {
    if (o.id && o.artistId) trackToArtist.set(String(o.id), o.artistId);
  });
  const cacheRows = readNdjson(CACHE, (o) => {
    if (!o.id) return;
    if (o.artistId) trackToArtist.set(String(o.id), o.artistId);
    else if (o.miss) known404.add(String(o.id));
  });
  console.error(`  song-meta rows: ${metaRows}, own-cache rows: ${cacheRows}, distinct track ids: ${trackToArtist.size}`);

  // ── Vote artist ids per normalized name ───────────────────────────────────────────────────
  // A name's id is the one carried by the MOST of its songs; ties break on the smaller id
  // (Apple's older/primary entity), so the output is deterministic across runs.
  /** @type {Map<string,{raw:Map<string,number>, votes:Map<number,number>, ids:string[], songs:number}>} */
  const byName = new Map();
  for (const s of songs) {
    if (!s.artist) continue;
    const k = norm(s.artist);
    let e = byName.get(k);
    if (!e) { e = { raw: new Map(), votes: new Map(), ids: [], songs: 0 }; byName.set(k, e); }
    e.songs++;
    e.raw.set(s.artist, (e.raw.get(s.artist) || 0) + 1);
    for (const id of [s.appleMusicId, s.appleMusicIdExplicit, s.appleMusicIdClean]) {
      if (!id) continue;
      const sid = String(id);
      const a = trackToArtist.get(sid);
      if (a) e.votes.set(a, (e.votes.get(a) || 0) + 1);
      else if (!known404.has(sid) && e.ids.length < IDS_PER_NAME * 4) e.ids.push(sid);
    }
  }

  const resolvedFromCache = [...byName.values()].filter((e) => e.votes.size > 0).length;
  const unresolved = [...byName.entries()].filter(([, e]) => e.votes.size === 0 && e.ids.length > 0);
  const noRoute = [...byName.values()].filter((e) => e.votes.size === 0 && e.ids.length === 0).length;
  console.error(`  names: ${byName.size} total · ${resolvedFromCache} from cache · ${unresolved.length} need network · ${noRoute} have no store id at all`);

  // ── Tier 2: crawl only what Tier 1 could not cover ────────────────────────────────────────
  const targets = unresolved.slice(0, args.limit === Infinity ? undefined : args.limit);
  const wanted = [];
  for (const [, e] of targets) for (const id of e.ids.slice(0, IDS_PER_NAME)) wanted.push(id);
  const toLookup = [...new Set(wanted)];
  console.error(`→ network: ${toLookup.length} track ids for ${targets.length} names (${Math.ceil(toLookup.length / BATCH)} batches of ${BATCH}, concurrency ${CONCURRENCY})`);

  let fetched = 0, learned = 0;
  if (toLookup.length && !args.dryRun) {
    mkdirSync('index-out/apple-music', { recursive: true });
    const batches = [];
    for (let i = 0; i < toLookup.length; i += BATCH) batches.push(toLookup.slice(i, i + BATCH));
    let cursor = 0;
    const worker = async () => {
      while (cursor < batches.length) {
        const mine = batches[cursor++];
        const results = await lookupBatch(mine);
        fetched += mine.length;
        const lines = [];
        const seen = new Set();
        for (const r of results || []) {
          if (r.wrapperType !== 'track' || !r.trackId || !r.artistId) continue;
          const sid = String(r.trackId);
          seen.add(sid);
          if (trackToArtist.has(sid)) continue;
          trackToArtist.set(sid, r.artistId);
          lines.push(JSON.stringify({ id: sid, artistId: r.artistId, artistName: r.artistName }));
          learned++;
        }
        // Anything we asked for that a SUCCESSFUL request did not return is a permanent miss —
        // record it so the next run skips it. Gated on `results !== null` (request succeeded), NOT
        // on `results.length`: a batch of entirely-delisted ids legitimately comes back empty, and
        // that is precisely the case worth remembering.
        if (results !== null) {
          for (const sid of mine) {
            if (seen.has(sid) || trackToArtist.has(sid) || known404.has(sid)) continue;
            known404.add(sid);
            lines.push(JSON.stringify({ id: sid, miss: true }));
          }
        }
        // Append-on-success: a killed run resumes from exactly here.
        if (lines.length) appendFileSync(CACHE, lines.join('\n') + '\n');
        console.error(`  batch ${cursor}/${batches.length} · +${lines.length} ids`);
      }
    };
    await Promise.all(Array.from({ length: CONCURRENCY }, worker));

    // Re-vote with what the crawl learned.
    for (const [, e] of targets) {
      for (const sid of e.ids) {
        const a = trackToArtist.get(sid);
        if (a) e.votes.set(a, (e.votes.get(a) || 0) + 1);
      }
    }
  }

  // ── Emit the artists table ────────────────────────────────────────────────────────────────
  const artists = [];
  for (const [key, e] of byName) {
    if (e.votes.size === 0) continue;
    const ranked = [...e.votes.entries()].sort((a, b) => b[1] - a[1] || a[0] - b[0]);
    const [id] = ranked[0];
    const display = [...e.raw.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0][0];
    const row = { key, name: display, id, songs: e.songs };
    if (ranked.length > 1) row.alt = ranked.slice(1).map(([i]) => i);
    artists.push(row);
  }
  artists.sort((a, b) => b.songs - a.songs || a.key.localeCompare(b.key));

  // Coverage is measured in SONGS, not names — a name with 300 songs matters 300x more.
  let songsCovered = 0;
  const artistByKey = new Map(artists.map((a) => [a.key, a]));
  for (const s of songs) if (s.artist && artistByKey.has(norm(s.artist))) songsCovered++;

  index.artists = artists;
  if (index.manifest && index.manifest.counts) {
    index.manifest.counts.artists = artists.length;
    index.manifest.counts.songsWithArtistId = songsCovered;
  }

  console.error('');
  console.error(`✓ artists table: ${artists.length} artists (${artists.filter((a) => a.alt).length} with alternates)`);
  console.error(`✓ song coverage: ${songsCovered}/${songs.length} (${((songsCovered / songs.length) * 100).toFixed(2)}%)`);
  console.error(`✓ network: ${fetched} ids fetched, ${learned} new track→artist pairs learned`);
  if (args.dryRun) { console.error('(dry run — index NOT written)'); return; }
  atomicWriteJSON(INDEX, index);
  console.error(`✓ wrote ${INDEX}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
