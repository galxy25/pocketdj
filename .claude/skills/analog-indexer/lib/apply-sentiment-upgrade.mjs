#!/usr/bin/env node
// Fold the sentiment-UPGRADE workflow output back into a built index (idempotent) —
// the output side of workflow/sentiment-upgrade.workflow.js.
//
// Reads every <dir>/out/out-*.jsonl line {songId, keywords:[...], source:"lyrics"|"inferred"}
// and updates the matching song's sentimentKeywords + sentimentSource IN PLACE.
//
//   node apply-sentiment-upgrade.mjs [--index index-out/current/index.json]
//     [--dir /tmp/sent-upgrade] [--out <same as index>]
//
// Metadata-ownership rule (load-bearing): this fold touches ONLY song-level sentiment
// fields. It never changes album status/tracks, and never overwrites lyrics. A result
// claiming source:"lyrics" is only honored when the song actually still has lyrics —
// otherwise it's downgraded to "inferred" (mirrors enrich-sentiment.mjs).
import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

function arg(f, d) {
  const i = process.argv.indexOf(f);
  return i >= 0 ? process.argv[i + 1] : d;
}
const indexPath = arg('--index', 'index-out/current/index.json');
const dir = arg('--dir', '/tmp/sent-upgrade');
const outPath = arg('--out', indexPath);

const outDir = join(dir, 'out');
function readResults() {
  if (!existsSync(outDir)) return [];
  const rows = [];
  for (const f of readdirSync(outDir)) {
    if (!f.endsWith('.jsonl')) continue;
    for (const line of readFileSync(join(outDir, f), 'utf8').split('\n')) {
      const t = line.trim();
      if (!t) continue;
      try {
        const o = JSON.parse(t);
        if (o && o.songId && Array.isArray(o.keywords)) rows.push(o);
      } catch {
        /* skip a malformed line rather than abort the whole fold */
      }
    }
  }
  return rows;
}

const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
const songById = new Map(idx.songs.map((s) => [s.id, s]));

const rows = readResults();
let upgradedLyrics = 0;
let inferred = 0;
let notFound = 0;
let empty = 0;
for (const r of rows) {
  const s = songById.get(r.songId);
  if (!s) {
    notFound++;
    continue;
  }
  const kw = r.keywords.map((k) => String(k).toLowerCase().trim()).filter(Boolean).slice(0, 7);
  if (!kw.length) {
    empty++;
    continue;
  }
  s.sentimentKeywords = kw;
  // honor "lyrics" only if the song still has lyrics to have derived them from
  if (r.source === 'lyrics' && s.lyrics && s.lyrics.length) {
    s.sentimentSource = 'lyrics';
    upgradedLyrics++;
  } else {
    s.sentimentSource = 'inferred';
    inferred++;
  }
}

writeFileSync(outPath, JSON.stringify(idx));
const lyricsSourced = idx.songs.filter((s) => s.sentimentSource === 'lyrics').length;
process.stderr.write(
  `apply-sentiment-upgrade: ${rows.length} results -> +${upgradedLyrics} lyrics-sourced, ${inferred} inferred` +
    `${notFound ? `, ${notFound} song(s) not found` : ''}${empty ? `, ${empty} empty` : ''}` +
    ` (index now ${lyricsSourced}/${idx.songs.length} lyrics-sourced) -> ${outPath}\n`,
);
