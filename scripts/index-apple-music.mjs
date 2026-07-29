#!/usr/bin/env node
// Apple Music (Local) indexer — turns the canonical iTunes/Music `Library.xml`
// (a plist) into a PocketDJ IndexJson with manifest.sourceType = 'digital'.
//
// Why a bespoke streaming parser (not a plist lib): the real library is ~160MB /
// ~300k tracks. We read the file LINE BY LINE and stream songs straight to the
// output file, so peak memory is bounded by the album count (~tens of thousands),
// never the song count. The iTunes plist is extremely regular — every scalar is a
// one-line `<key>K</key><type>V</type>` — which makes a line parser robust.
//
// No audio analysis and no network: bpm/key/lyrics/sentiment/cover-art are left
// deferred (digital v1). Genre/Year/Track#/Explicit/length come straight from the
// library, so those are real.
//
// IDs are namespaced by the data source so the same album owned on vinyl AND in
// Apple Music are DISTINCT items (the app keys `items` by id alone) — each source
// owns its copy, and selecting/deselecting a source cleanly adds/removes it.
//   albumId = "alb_" + sha1(ns | normArtist | normAlbum)[:12]
//   songId  = "sng_" + sha1(ns | persistentID)[:12]   (persistent ID is globally
//             unique in the library → no dup-track-number collisions, stable across runs)
//
// Usage:
//   node scripts/index-apple-music.mjs --xml ~/Downloads/Library.xml \
//        --out index-out/apple-music/index.json [--source-name "Apple Music (Local)"] \
//        [--all-playlists] [--since 2026-01-01T00:00:00Z] [--state <state.json>] \
//        [--limit N] [--stats]
//
// Incremental: pass --state <file>. The run writes back {lastDateAdded, counts}.
// Pass --since <ISO> (or it reads state.lastDateAdded) to emit ONLY tracks added
// at/after that time + the albums they touch + all user playlists (playlists are
// small). The app upserts by id, so a delta import is additive and idempotent.
// (Deletions are out of scope for v1.)

import { createReadStream, createWriteStream, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

const INDEX_SCHEMA_VERSION = '1.0.0';

// Robust "mode" over an album's per-track catalog ids: returns the most-common
// NON-EMPTY value (String), so one mistagged track can't hijack the album's identity.
// Returns undefined when no track carries a value (ties resolve to the first-seen).
// This is the album `appleMusicId` (the iTunes collectionId) the client joins on to
// supersede a provisional Discover album. Exported for unit testing.
export function mostCommonNonEmpty(values) {
  const counts = new Map(); // insertion order → first-seen wins ties
  for (const v of values) {
    if (v == null || v === '') continue;
    const k = String(v);
    counts.set(k, (counts.get(k) || 0) + 1);
  }
  let best, bestN = 0;
  for (const [k, n] of counts) if (n > bestN) { bestN = n; best = k; }
  return best;
}

// ---------- args ----------
function parseArgs(argv) {
  const a = { sourceName: 'Apple Music (Local)', userPlaylistsOnly: true };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i];
    if (k === '--xml') a.xml = next();
    else if (k === '--out') a.out = next();
    else if (k === '--source-name') a.sourceName = next();
    else if (k === '--all-playlists') a.userPlaylistsOnly = false;
    else if (k === '--since') a.since = next();
    else if (k === '--state') a.state = next();
    else if (k === '--limit') a.limit = parseInt(next(), 10);
    else if (k === '--catalog-cache') a.catalogCache = next();
    else if (k === '--stats') a.stats = true;
  }
  return a;
}
const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);

// ---------- string helpers (mirror analog-indexer lib/normalize.js + ids.js) ----------
function normalize(s) {
  if (!s) return '';
  return String(s)
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/['’`]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^the\s+/, '');
}
const sha1 = (s) => createHash('sha1').update(s).digest('hex');

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
function decodeEntities(s) {
  if (s.indexOf('&') === -1) return s;
  return s.replace(/&(#x?[0-9a-fA-F]+|[a-z]+);/g, (m, code) => {
    if (code[0] === '#') {
      const n = code[1] === 'x' || code[1] === 'X' ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return Number.isFinite(n) ? String.fromCodePoint(n) : m;
    }
    return ENTITIES[code] ?? m;
  });
}

// Apple "Kind" string -> our FileType union (else undefined).
function fileTypeFromKind(kind) {
  if (!kind) return undefined;
  const k = kind.toLowerCase();
  if (k.includes('mpeg')) return 'mp3';
  if (k.includes('aiff')) return 'aiff';
  if (k.includes('wav')) return 'wav';
  if (k.includes('aac')) return 'aac'; // incl. "Apple Music AAC", "Purchased AAC"
  if (k.includes('lossless') || k.includes('m4a') || k.includes('matched')) return 'm4a';
  return undefined;
}

// Parse one scalar field line: `<key>NAME</key><type>VALUE</type>` or self-closing bool.
// Returns [name, value] or null. Bools -> true/false; integers -> Number; else string.
const FIELD_RE = /^\s*<key>([^<]+)<\/key>(?:<(\w+)>([\s\S]*?)<\/\2>|<(true|false)\/>)\s*$/;
function parseField(line) {
  const m = FIELD_RE.exec(line);
  if (!m) return null;
  const name = m[1];
  if (m[4]) return [name, m[4] === 'true'];
  const type = m[2];
  let raw = m[3];
  if (type === 'integer') return [name, Number(raw)];
  // string / date — decode entities
  return [name, decodeEntities(raw)];
}

async function main() {
  const args = parseArgs(process.argv);
  if (!args.xml || (!args.out && !args.stats)) {
    console.error('Usage: node scripts/index-apple-music.mjs --xml <Library.xml> --out <index.json> [--source-name N] [--all-playlists] [--since ISO] [--state f] [--limit N] [--stats]');
    process.exit(1);
  }
  const xmlPath = resolve(expand(args.xml));
  if (!existsSync(xmlPath)) { console.error('not found:', xmlPath); process.exit(1); }

  // incremental "since"
  let since = args.since ? Date.parse(args.since) : null;
  if (!since && args.state && existsSync(expand(args.state))) {
    try { since = Date.parse(JSON.parse(readFileSync(expand(args.state), 'utf8')).lastDateAdded); } catch { /* ignore */ }
  }
  if (Number.isNaN(since)) since = null;

  const ns = `digital|${args.sourceName}`;
  const albumIdFor = (artist, album) => 'alb_' + sha1(`${ns}|${normalize(artist)}|${normalize(album)}`).slice(0, 12);
  const songIdFor = (persistentId, fallback) =>
    'sng_' + sha1(`${ns}|${persistentId || fallback}`).slice(0, 12);

  // Optional Apple Music catalog ids resolved out-of-band by
  // scripts/resolve-apple-music-catalog.mjs (a multi-day iTunes-Search crawl). The
  // cache is ndjson keyed by song id; we bake the `appleMusicId` back onto each
  // song here so a re-index never drops the resolved ids. Misses (storeId:null)
  // are simply ignored.
  const catalogIds = new Map(); // songId -> storeId (per-song adam id → song.appleMusicId)
  // Per-song album catalog id (the iTunes `collectionId`), captured by the same
  // resolver pass. Aggregated per-album below into the album's `appleMusicId` so a
  // provisional Discover album is superseded by the real indexed one. Older cache
  // records without `collectionId` simply contribute nothing → album id undefined.
  const collectionIds = new Map(); // songId -> album collectionId
  if (args.catalogCache && existsSync(expand(args.catalogCache))) {
    for (const ln of readFileSync(expand(args.catalogCache), 'utf8').split('\n')) {
      if (!ln.trim()) continue;
      try {
        const o = JSON.parse(ln); // ndjson; last line for an id wins (Map.set)
        if (o.id && o.storeId) catalogIds.set(o.id, o.storeId);
        if (o.id && o.collectionId) collectionIds.set(o.id, String(o.collectionId));
      } catch { /* skip */ }
    }
    console.error(`  catalog cache: ${catalogIds.size} resolved appleMusicId(s), ${collectionIds.size} album collectionId(s)`);
  }

  // ---- output: stream songs to disk; keep albums + a trackID->songId map in memory ----
  const albums = new Map(); // albumId -> { id, artist, name, genre, year, fileType, trackList: [] }
  const trackToSong = new Map(); // numeric Track ID -> songId (for playlist resolution)
  let songStream = null;
  let songCount = 0;
  let songsFile = null;
  if (!args.stats) {
    mkdirSync(dirname(resolve(expand(args.out))), { recursive: true });
    songsFile = resolve(expand(args.out)) + '.songs.ndjson';
    songStream = createWriteStream(songsFile);
  }

  // counters
  let trackSeen = 0, trackEmitted = 0, trackSkipped = 0, withLocation = 0, explicitCount = 0;
  let maxDateAdded = since || 0;
  const genres = new Map();

  // ---- state machine ----
  let section = 'top';            // top | tracks | playlists
  let depth0Seen = false;         // saw the top-level <dict>
  let inTrack = false;            // accumulating a track dict
  let curTrack = null;
  // playlist parsing
  let inPlaylist = false, curPl = null, inItems = false;
  const playlists = [];

  const flushTrack = () => {
    inTrack = false;
    const t = curTrack; curTrack = null;
    if (!t) return;
    trackSeen++;
    // music only: must have a name; skip videos/podcasts/books if flagged
    if (!t['Name']) { trackSkipped++; return; }
    if (t['Movie'] || t['TV Show'] || t['Podcast'] || t['Audiobook'] || t['Has Video']) { trackSkipped++; return; }
    const tid = t['Track ID'];
    const added = t['Date Added'] ? Date.parse(t['Date Added']) : 0;
    if (added > maxDateAdded) maxDateAdded = added;

    const artist = t['Artist'] || t['Album Artist'] || 'Unknown Artist';
    const albumArtist = t['Album Artist'] || t['Artist'] || artist;
    const albumName = t['Album'] || t['Name']; // album-less single -> own album by track name
    const albumKey = albumIdFor(albumArtist, albumName);
    const sid = songIdFor(t['Persistent ID'], `${tid}`);
    // always map trackID -> songId so playlists can resolve even on a delta run
    if (tid != null) trackToSong.set(tid, sid);

    // incremental: skip emitting songs older than `since` (but still mapped above)
    if (since && added && added < since) { return; }

    if (t['Genre']) genres.set(t['Genre'], (genres.get(t['Genre']) || 0) + 1);
    if (t['Location']) withLocation++;
    if (t['Explicit']) explicitCount++;
    const fileType = fileTypeFromKind(t['Kind']);

    // album rollup
    let alb = albums.get(albumKey);
    if (!alb) {
      alb = {
        id: albumKey, artist: albumArtist, name: albumName,
        genre: t['Genre'] || undefined, year: t['Year'] || undefined,
        fileType, trackList: [], _disc: t['Disc Number'] || 1,
        fileLocation: t['Location'] ? dirname(decodeEntities(t['Location'])) : undefined,
      };
      albums.set(albumKey, alb);
    }
    // fill album year/genre if a later track has it and album lacked it
    if (!alb.year && t['Year']) alb.year = t['Year'];
    if (!alb.genre && t['Genre']) alb.genre = t['Genre'];
    // keep disc/track so we can present the album in playing order (the library
    // lists tracks in Track-ID/add order, which scrambles albums)
    alb.trackList.push({ sid, disc: t['Disc Number'] || 1, track: t['Track Number'] || 0 });

    const song = {
      id: sid,
      albumId: albumKey,
      artist,
      name: t['Name'],
      trackNumber: t['Track Number'] || undefined,
      year: t['Year'] || undefined,
      explicit: !!t['Explicit'],
      bpm: null, key: null, camelot: null,
      appleMusicId: catalogIds.get(sid) || undefined,
      // epoch ms the track was added to the library (Apple Music "Date Added"),
      // already parsed above as `added`. Powers the "Recently added" playlist's
      // ranking of catalog songs. `0`/missing -> undefined so old rows stay clean.
      dateAdded: added || undefined,
      length: t['Total Time'] || undefined,
      fileType,
      pointer: {
        fileLocation: t['Location'] ? decodeEntities(t['Location']) : undefined,
        disc: t['Disc Number'] || undefined,
        track: t['Track Number'] || undefined,
        timestamps: null,
      },
    };
    if (songStream) songStream.write(JSON.stringify(song) + '\n');
    songCount++;
    trackEmitted++;
  };

  const isUserPlaylist = (p) =>
    !p['Master'] && !p['Distinguished Kind'] && !p['Folder'] && !('Smart Info' in p) && !('Smart Criteria' in p) &&
    p['Name'] && p['Name'] !== 'Library' && p['Name'] !== 'Downloaded';

  const rl = createInterface({ input: createReadStream(xmlPath, { encoding: 'utf8' }), crlfDelay: Infinity });

  for await (const line of rl) {
    // ---- section transitions ----
    if (section === 'top') {
      if (line.includes('<key>Tracks</key>')) { section = 'tracks'; continue; }
      if (line.includes('<key>Playlists</key>')) { section = 'playlists'; continue; }
      continue;
    }

    if (section === 'tracks') {
      // a track opens with `<key>NNN</key>` then `<dict>`; closes at `</dict>`
      if (!inTrack) {
        if (/^\s*<key>\d+<\/key>\s*$/.test(line)) { inTrack = true; curTrack = {}; continue; }
        // end of the Tracks container -> move on (next top-level key is Playlists)
        if (/^\s*<\/dict>\s*$/.test(line)) { section = 'top'; continue; }
        continue;
      }
      // inside a track
      if (/^\s*<\/dict>\s*$/.test(line)) {
        flushTrack();
        if (args.limit && trackSeen >= args.limit) break;
        continue;
      }
      const f = parseField(line);
      if (f) curTrack[f[0]] = f[1];
      continue;
    }

    if (section === 'playlists') {
      // playlist dict opens with <dict>; its fields are flat until a nested
      // <key>Playlist Items</key><array> of <dict><key>Track ID</key>…</dict>.
      if (!inPlaylist) {
        if (/^\s*<dict>\s*$/.test(line)) { inPlaylist = true; curPl = { __items: [] }; inItems = false; continue; }
        if (/^\s*<\/array>\s*$/.test(line)) { section = 'top'; continue; } // end Playlists array
        continue;
      }
      // inside a playlist
      if (!inItems) {
        if (line.includes('<key>Playlist Items</key>')) { inItems = 'await-array'; continue; }
        if (/^\s*<\/dict>\s*$/.test(line)) {
          // playlist closes
          const p = curPl; inPlaylist = false; curPl = null;
          if (!args.userPlaylistsOnly || isUserPlaylist(p)) {
            playlists.push({
              persistentId: p['Playlist Persistent ID'],
              name: p['Name'] || 'Untitled Playlist',
              trackIds: p.__items,
            });
          }
          continue;
        }
        const f = parseField(line);
        if (f) curPl[f[0]] = f[1];
        continue;
      }
      // inItems: waiting for <array>, then collect Track IDs, until </array>
      if (inItems === 'await-array') {
        if (/^\s*<array\/>\s*$/.test(line)) { inItems = false; continue; } // empty playlist
        if (/^\s*<array>\s*$/.test(line)) { inItems = true; continue; }
        continue;
      }
      if (/^\s*<\/array>\s*$/.test(line)) { inItems = false; continue; }
      const m = /^\s*<key>Track ID<\/key><integer>(\d+)<\/integer>\s*$/.exec(line);
      if (m) curPl.__items.push(Number(m[1]));
      continue;
    }
  }
  flushTrack(); // safety
  if (songStream) await new Promise((r) => songStream.end(r));

  // ---- resolve playlists: Track IDs -> songIds. Empty playlists are KEPT: existence in
  // the source is truth (dropping them here made a full rebuild re-ship the deletion of
  // empty playlists the incremental sync intentionally preserves — the OTG lesson). ----
  const resolvedPlaylists = playlists.map((p) => {
    const songIds = p.trackIds.map((tid) => trackToSong.get(tid)).filter(Boolean);
    return { id: 'pl_' + sha1(`${ns}|${p.persistentId || p.name}`).slice(0, 12), name: p.name, songIds };
  });

  const albumArr = [...albums.values()].map((a) => ({
    id: a.id, artist: a.artist, name: a.name,
    genre: a.genre, year: a.year,
    // album catalog id = the most-common collectionId across this album's tracks
    // (undefined when no track resolved one → JSON.stringify omits it, backward-compatible).
    appleMusicId: mostCommonNonEmpty(a.trackList.map((e) => collectionIds.get(e.sid))),
    trackList: a.trackList
      .sort((x, y) => x.disc - y.disc || x.track - y.track)
      .map((e) => e.sid),
    fileType: a.fileType,
    pointer: a.fileLocation ? { fileLocation: a.fileLocation } : undefined,
    enrichment: { status: 'unmatched', sources: ['apple-music-library'] },
  }));

  const topGenres = [...genres.entries()].sort((x, y) => y[1] - x[1]).slice(0, 15);

  if (args.stats) {
    console.log(JSON.stringify({
      tracksSeen: trackSeen, tracksEmitted: trackEmitted, tracksSkipped: trackSkipped,
      albums: albumArr.length, withLocation, explicit: explicitCount,
      userPlaylists: resolvedPlaylists.length,
      sincePlaylistSamples: resolvedPlaylists.slice(0, 12).map((p) => `${p.name} (${p.songIds.length})`),
      topGenres,
    }, null, 2));
    return;
  }

  // ---- assemble final index.json, streaming songs back in from the ndjson ----
  const manifest = {
    source: 'Library.xml',
    generatedAt: new Date(maxDateAdded || Date.now()).toISOString(),
    schemaVersion: INDEX_SCHEMA_VERSION,
    sourceType: 'digital',
    sourceName: args.sourceName,
    counts: {
      albums: albumArr.length, songs: songCount,
      albumsMatched: 0, albumsUnmatched: albumArr.length,
      songsWithLyrics: 0, sentimentFromLyrics: 0, sentimentInferred: 0,
      lines: 0, vinylLines: 0,
    },
    deferredFields: ['lyrics', 'sentimentKeywords', 'bpm', 'key', 'camelot', 'coverArt'],
    incremental: since ? { since: new Date(since).toISOString() } : undefined,
    playlistsCount: resolvedPlaylists.length,
  };

  const outPath = resolve(expand(args.out));
  const out = createWriteStream(outPath);
  out.write('{\n"manifest":' + JSON.stringify(manifest) + ',\n');
  out.write('"albums":' + JSON.stringify(albumArr) + ',\n');
  out.write('"playlists":' + JSON.stringify(resolvedPlaylists) + ',\n');
  out.write('"songs":[\n');
  // stream the ndjson back out as a JSON array
  const songLines = createInterface({ input: createReadStream(songsFile, { encoding: 'utf8' }), crlfDelay: Infinity });
  let first = true;
  for await (const ln of songLines) {
    if (!ln) continue;
    out.write((first ? '' : ',\n') + ln);
    first = false;
  }
  out.write('\n]}\n');
  await new Promise((r) => out.end(r));

  if (args.state) {
    writeFileSync(expand(args.state), JSON.stringify({
      lastDateAdded: new Date(maxDateAdded || Date.now()).toISOString(),
      counts: manifest.counts, generatedAt: manifest.generatedAt,
    }, null, 2));
  }

  console.error(`✓ ${outPath}`);
  console.error(`  albums=${albumArr.length} songs=${songCount} playlists=${resolvedPlaylists.length} explicit=${explicitCount} localFiles=${withLocation}`);
}

if (import.meta.url === (process.argv[1] ? pathToFileURL(process.argv[1]).href : '')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
