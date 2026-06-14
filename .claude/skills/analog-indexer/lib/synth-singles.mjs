#!/usr/bin/env node
// SINGLES synthesizer — the last metadata step. Albums that are still `unmatched`
// after the first pass AND the web-search backfill are almost always 12" vinyl
// SINGLES / individual tracks, which have no album tracklist to match. Rather than
// drop them, turn each into a one-track album: name = "<single name> Single", with a
// single track = the single itself. They then flow through lyrics + sentiment like any
// matched album and appear in the catalog.
//
//   node synth-singles.mjs --dir index-out/shards-pw
//
// Operates on the streaming shard dir: converts the still-unmatched records in
// enriched.jsonl IN PLACE (backs up enriched.jsonl.bak first), and drops those
// candidateIndexes from lyrics.jsonl + sentiment.jsonl so the streaming workers
// re-process them (scrape the single's lyrics, tag its sentiment). Idempotent: an
// album already converted (sources includes 'single-synth') is left alone.

import { readFileSync, writeFileSync, renameSync, existsSync, copyFileSync } from 'node:fs';
import { join } from 'node:path';

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}
const dir = arg('--dir', 'index-out/shards-pw');

function readJsonl(path) {
  if (!existsSync(path)) return [];
  const out = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      /* skip */
    }
  }
  return out;
}
function writeJsonl(path, recs) {
  const tmp = path + '.tmp';
  writeFileSync(tmp, recs.map((r) => JSON.stringify(r)).join('\n') + (recs.length ? '\n' : ''));
  renameSync(tmp, path);
}

const enrichedPath = join(dir, 'enriched.jsonl');
const lyricsPath = join(dir, 'lyrics.jsonl');
const sentimentPath = join(dir, 'sentiment.jsonl');

// candidateIndexes recovered by the web / google backfills — DON'T turn these into
// singles (they got a real album).
const recovered = new Set();
for (const f of ['web.jsonl', 'google.jsonl']) {
  for (const r of readJsonl(join(dir, f))) {
    if (r.status === 'matched' && typeof r.candidateIndex === 'number') recovered.add(r.candidateIndex);
  }
}

// Turn an unmatched record into a one-track single-album.
function toSingle(rec) {
  const nm = String(rec.name || '').trim();
  const base = nm || String(rec.artist || '').trim() || 'Untitled';
  const albumName = /\bsingle\b/i.test(base) ? base : base + ' Single';
  return {
    ...rec,
    status: 'matched',
    matchConfidence: 'single',
    sources: [...(rec.sources || []), 'single-synth'],
    name: albumName,
    tracks: [
      {
        discNumber: 1,
        trackNumber: 1,
        name: base,
        artist: rec.artist || '',
        lyrics: null,
        lyricsStatus: 'notfound',
        sentimentKeywords: [],
        sentimentSource: 'inferred',
      },
    ],
  };
}

const enriched = readJsonl(enrichedPath);
const convertedCi = new Set();
const out = enriched.map((rec) => {
  const ci = rec.candidateIndex;
  const already = (rec.sources || []).includes('single-synth');
  if (rec.status === 'unmatched' && !recovered.has(ci) && !already) {
    convertedCi.add(ci);
    return toSingle(rec);
  }
  return rec;
});

if (!convertedCi.size) {
  process.stderr.write('synth-singles: no still-unmatched albums to convert\n');
  process.exit(0);
}

// Back up + rewrite enriched.jsonl with the synthesized singles.
copyFileSync(enrichedPath, enrichedPath + '.bak');
writeJsonl(enrichedPath, out);

// Drop the converted candidateIndexes from the downstream shards so the streaming
// lyrics + sentiment workers re-process them (they were trackless pass-throughs).
let lyrDropped = 0;
let sentDropped = 0;
if (existsSync(lyricsPath)) {
  const keep = readJsonl(lyricsPath).filter((r) => {
    if (convertedCi.has(r.candidateIndex)) {
      lyrDropped++;
      return false;
    }
    return true;
  });
  writeJsonl(lyricsPath, keep);
}
if (existsSync(sentimentPath)) {
  const keep = readJsonl(sentimentPath).filter((r) => {
    if (convertedCi.has(r.candidateIndex)) {
      sentDropped++;
      return false;
    }
    return true;
  });
  writeJsonl(sentimentPath, keep);
}

process.stderr.write(
  `synth-singles: converted ${convertedCi.size} unmatched -> single-albums; ` +
    `dropped ${lyrDropped} from lyrics.jsonl + ${sentDropped} from sentiment.jsonl for re-processing\n`,
);
