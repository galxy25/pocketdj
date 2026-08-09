#!/usr/bin/env node
// Build the Apple Music PLAY-COUNT CACHE from an exported Library.xml.
//
// Apple's play counts are the only large listening signal that exists for this library:
// PocketDJ's own on-device stats cover ~700 songs, Apple's cover ~56,000. Neither the
// Apple Music REST API nor any catalog endpoint exposes them (verified 2026-08-08), so the
// sources are Library.xml, MusicKit's `Song.playCount`, or Music.app over AppleScript.
// This script handles the first — the one that needs no device, no entitlement and no
// authorization prompt — and is the SEED for the on-device capture that follows.
//
// SET, NEVER ADD. The output is a snapshot keyed by song id, and re-running OVERWRITES it.
// That is deliberate and load-bearing: `PlayStatsStore.peerLastPlayedAt` documents why a
// counter fed from a re-mergeable source inflates on every replay (a re-pull, a restore, a
// backup import). An imported baseline is exactly such a source, so it must never be added
// into an accumulator — consumers sum it with local counts at READ time instead.
//
// Join: song ids are `sng_` + sha1(`digital|<source>|<Persistent ID>`) truncated to 12,
// mirroring scripts/index-apple-music.mjs:151-154 exactly. Do not "improve" this — a
// different derivation silently produces a cache that joins to nothing.
//
// Usage:
//   node scripts/build-playcount-cache.mjs [--xml ~/Downloads/Library.xml]
//        [--out index-out/apple-music/playcounts.json]
//        [--stats index-out/apple-music/playcount-stats.json]
//        [--source "Apple Music (Local)"]
import { createReadStream, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);
const sha1 = (s) => createHash('sha1').update(s).digest('hex');

function parseArgs(argv) {
  const a = {
    xml: '~/Downloads/Library.xml',
    out: 'index-out/apple-music/playcounts.json',
    stats: 'index-out/apple-music/playcount-stats.json',
    source: 'Apple Music (Local)',
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i], next = () => argv[++i];
    if (k === '--xml') a.xml = next();
    else if (k === '--out') a.out = next();
    else if (k === '--stats') a.stats = next();
    else if (k === '--source') a.source = next();
  }
  return a;
}

// Library.xml is ~164MB, so this is a line-oriented state machine rather than a plist load:
// a full parse costs seconds and gigabytes for data we read once.
const KEY_RE = /<key>([^<]+)<\/key>/;
const VAL_RE = /<(integer|string|date|true|false)\/?>([^<]*)/;

/// Decode the XML entities Music.app writes into text fields.
function unesc(s) {
  return String(s)
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(Number(d)))
    .replace(/&amp;/g, '&');   // last — an escaped & must not re-trigger the others
}

/// Stream every track dict out of the `Tracks` section. Yields plain objects.
export async function* streamTracks(xmlPath) {
  const rl = createInterface({
    input: createReadStream(xmlPath, { encoding: 'utf8' }),
    crlfDelay: Infinity,
  });
  let inTracks = false, depth = 0, cur = null, pendingKey = null;
  for await (const raw of rl) {
    const line = raw.trim();
    if (!inTracks) {
      if (line === '<key>Tracks</key>') inTracks = true;
      continue;
    }
    // The Playlists section follows Tracks; once we reach it we are done.
    if (line === '<key>Playlists</key>') break;
    if (line === '<dict>') { depth++; if (depth === 2) cur = {}; continue; }
    if (line === '</dict>') {
      depth--;
      if (depth === 1 && cur) { yield cur; cur = null; }
      continue;
    }
    if (!cur) continue;
    const k = line.match(KEY_RE);
    if (k) {
      pendingKey = k[1];
      // <key>X</key><integer>1</integer> on ONE line is common in this export.
      const inline = line.slice(k[0].length).match(VAL_RE);
      if (inline) { cur[pendingKey] = inline[1] === 'true' ? true : inline[2]; pendingKey = null; }
      continue;
    }
    if (pendingKey) {
      const v = line.match(VAL_RE);
      if (v) { cur[pendingKey] = v[1] === 'true' ? true : v[2]; pendingKey = null; }
    }
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const xmlPath = resolve(expand(args.xml));
  if (!existsSync(xmlPath)) {
    console.error(`Library.xml not found: ${xmlPath}`);
    console.error('Export it from Music.app: File ▸ Library ▸ Export Library…');
    process.exit(1);
  }
  const ns = `digital|${args.source}`;
  const songIdFor = (pid) => 'sng_' + sha1(`${ns}|${pid}`).slice(0, 12);

  const counts = {};                  // songId -> { n, lastMs }
  const byYear = {};                  // year -> plays
  const byYearArtist = {};            // year -> artist -> plays
  const byYearGenre = {};             // year -> genre -> plays
  const artistTotals = {}, genreTotals = {};
  let tracks = 0, withCount = 0, totalPlays = 0, noPersistent = 0, undated = 0;

  for await (const t of streamTracks(xmlPath)) {
    tracks++;
    const pid = t['Persistent ID'];
    const n = parseInt(t['Play Count'] || '0', 10) || 0;
    if (!pid) { noPersistent++; continue; }
    // Music OMITS the key at zero, so "no key" IS the zero — don't store those.
    if (n <= 0) continue;
    withCount++;
    totalPlays += n;

    const played = t['Play Date UTC'] ? Date.parse(t['Play Date UTC']) : NaN;
    counts[songIdFor(pid)] = Number.isNaN(played) ? { n } : { n, lastMs: played };

    // ── Per-year attribution ────────────────────────────────────────────────────────
    // Apple stores ONE last-played date per track, not a play history. So a track's
    // WHOLE count is attributed to the year it was last played. This is an approximation
    // and the only one available; a track played 40 times across 2015-2020 lands entirely
    // in 2020. Anything reading these aggregates must say so.
    if (Number.isNaN(played)) { undated++; continue; }
    const year = new Date(played).getUTCFullYear();
    const artist = unesc(t['Album Artist'] || t['Artist'] || 'Unknown Artist');
    const genre = unesc(t['Genre'] || 'Unknown');
    byYear[year] = (byYear[year] || 0) + n;
    (byYearArtist[year] ||= {})[artist] = (byYearArtist[year]?.[artist] || 0) + n;
    (byYearGenre[year] ||= {})[genre] = (byYearGenre[year]?.[genre] || 0) + n;
    artistTotals[artist] = (artistTotals[artist] || 0) + n;
    genreTotals[genre] = (genreTotals[genre] || 0) + n;
  }

  mkdirSync(dirname(resolve(expand(args.out))), { recursive: true });
  const doc = {
    schemaVersion: 1,
    source: 'library-xml',
    sourceName: args.source,
    capturedAtMs: Date.now(),
    counts,
  };
  writeFileSync(resolve(expand(args.out)), JSON.stringify(doc));

  const topN = (obj, n) => Object.entries(obj).sort((a, b) => b[1] - a[1]).slice(0, n);
  writeFileSync(resolve(expand(args.stats)), JSON.stringify({
    capturedAtMs: doc.capturedAtMs,
    caveat: 'Apple stores only a LAST-PLAYED date per track, so each track\'s whole play count is attributed to the year it was last played.',
    totals: { tracks, withCount, totalPlays, undated },
    byYear,
    byYearArtist,
    byYearGenre,
    artistTotals: Object.fromEntries(topN(artistTotals, 500)),
    genreTotals,
  }));

  console.error(`✓ ${args.out}`);
  console.error(`  tracks ${tracks}  with plays ${withCount}  total plays ${totalPlays}`);
  console.error(`  no persistent id ${noPersistent}  played but undated ${undated}`);
  console.error(`  years ${Object.keys(byYear).sort().join(', ')}`);
}

if (import.meta.url === (process.argv[1] ? pathToFileURL(process.argv[1]).href : '')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
