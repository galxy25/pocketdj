#!/usr/bin/env node
// Fold the AUDIO stage (index-out/shards-pw/audio.jsonl) into the index:
//   - album.audioTracks  = the detected segments (track#, start/end ms, bpm, key, camelot)
//     — the AUDIO ground truth, shown in the solar-system "sun" popup. May differ in count
//     from the metadata tracklist (the audio segmentation is independent), by design.
//   - per-song bpm / key / camelot / pointer.startMs/endMs — best-effort by ORDER
//     (segment i -> trackList[i]) so songs are sortable by bpm/key.
//
//   node apply-audio.mjs [--index index-out/current/index.json]
//     [--audio index-out/shards-pw/audio.jsonl] [--out <same as index>]
// Idempotent: re-applying overwrites with the latest audio.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

function arg(f, d) {
  const i = process.argv.indexOf(f);
  return i >= 0 ? process.argv[i + 1] : d;
}
const indexPath = arg('--index', 'index-out/current/index.json');
const audioPath = arg('--audio', 'index-out/shards-pw/audio.jsonl');
const outPath = arg('--out', indexPath);

const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
const audio = new Map();
if (existsSync(audioPath)) {
  for (const l of readFileSync(audioPath, 'utf8').split('\n')) {
    const t = l.trim();
    if (!t) continue;
    try {
      const r = JSON.parse(t);
      if (r.ok && r.albumId && (r.segments || []).length) audio.set(r.albumId, r);
    } catch {
      /* skip */
    }
  }
}

const songById = new Map(idx.songs.map((s) => [s.id, s]));
let albumsUpdated = 0;
let songsUpdated = 0;
for (const a of idx.albums) {
  const au = audio.get(a.id);
  if (!au) continue;
  a.audioTracks = au.segments.map((s) => ({
    trackNumber: s.i + 1,
    startMs: s.startMs,
    endMs: s.endMs,
    durationMs: s.durationMs,
    bpm: s.bpm,
    key: s.key,
    camelot: s.camelot,
    keyStrength: s.keyStrength,
  }));
  a.audioDurationSec = au.durationSec;
  albumsUpdated++;
  // Best-effort per-song bpm/key by order (for sorting). Audio segment count may not
  // match the tracklist; align up to the shorter of the two.
  const tl = a.trackList || [];
  const n = Math.min(tl.length, au.segments.length);
  for (let i = 0; i < n; i++) {
    const s = songById.get(tl[i]);
    if (!s) continue;
    const seg = au.segments[i];
    s.bpm = Math.round(seg.bpm);
    s.key = seg.key;
    s.camelot = seg.camelot;
    s.pointer = s.pointer || {};
    s.pointer.startMs = seg.startMs;
    s.pointer.endMs = seg.endMs;
    songsUpdated++;
  }
}

writeFileSync(outPath, JSON.stringify(idx));
process.stderr.write(
  `applied audio: ${albumsUpdated} albums (audioTracks), ${songsUpdated} songs (bpm/key) -> ${outPath}\n`,
);
