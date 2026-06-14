#!/usr/bin/env node
// TRACK-CLEANUP, pass 1 of 2: DEDUP duplicate tracks within an album (deterministic).
//
// Messy metadata merges leave albums with the SAME song listed 2+ times (e.g. Sade
// "Diamond Life" lists "Smooth Operator", "Cherry Pie", "Sally" twice — one copy carries
// bpm/key from the audio stage, the other is a bare metadata row). This fold collapses
// those true duplicates IN PLACE, keyed by the song's NORMALIZED EXACT name, SCOPED to the
// album. It does NOT merge distinct *versions* ("Between the Sheets" stays separate from
// "Between the Sheets (Instrumental Version)") — the normalized key keeps the parenthetical.
//
//   node dedup-tracks.mjs [--index index-out/current/index.json] [--out <same as index>]
//                         [--report path.json] [--dry-run]
//
// What it does, per album:
//   1. Group the album's songs by normSongName(name).
//   2. For any group with 2+ members, KEEP the one with the FULLEST set of info
//      (completeness score over populated fields; tie -> keep the first/earliest), and
//      DROP the rest: remove their songIds from album.trackList AND from index.songs
//      (no orphans). KEPT songs keep their original songId (a later lyrics/sentiment
//      backfold can still find them).
//
// Metadata-ownership rule (load-bearing): this fold only removes redundant song rows +
// the corresponding trackList entries. It NEVER touches coverArt(Sources), audioTracks,
// audio bpm/key/camelot ON THE KEPT SONG, enrichment/indexing status, or any album-level
// metadata. trackNumber repair is a SEPARATE pass (renumber-tracks.mjs) — dedup leaves
// trackNumbers as-is. Idempotent: a second run on already-deduped data is a no-op.
//
// Exports normSongName + dedupTracks(idx) for unit tests (no I/O when imported).
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * Normalize a song name for the WITHIN-ALBUM duplicate key: lowercase, strip surrounding
 * whitespace/punctuation, collapse internal whitespace. Crucially it KEEPS interior
 * punctuation/words (including parentheticals like "(Instrumental Version)") so distinct
 * versions never collapse into one another. Diacritics are folded so "Café" == "Cafe".
 */
export function normSongName(name) {
  if (!name) return '';
  return String(name)
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '') // strip combining diacritics
    .toLowerCase()
    .replace(/[’`]/g, "'") // unify apostrophes (keep them — interior, meaningful)
    .replace(/\s+/g, ' ') // collapse internal whitespace
    .trim()
    .replace(/^[\s\p{P}]+|[\s\p{P}]+$/gu, '') // strip ONLY leading/trailing punctuation+ws
    .trim();
}

/**
 * Completeness score for a song row — higher means "fuller", so it wins a duplicate
 * group. Weighted toward the hard-won audio-analysis fields (bpm/key/camelot/pointer
 * timestamps) and real lyrics, since those are exactly what distinguishes the good copy
 * from a bare metadata duplicate. Each populated field adds its weight.
 */
export function completeness(s) {
  if (!s) return -1;
  let score = 0;
  const has = (v) =>
    Array.isArray(v) ? v.length > 0 : typeof v === 'string' ? v.trim().length > 0 : v != null;
  // audio-derived (most valuable — only present on the "good" copy)
  if (s.bpm != null) score += 3;
  if (has(s.key)) score += 3;
  if (has(s.camelot)) score += 2;
  const p = s.pointer || {};
  if (p.startMs != null) score += 2;
  if (p.endMs != null) score += 2;
  if (p.timestamps != null) score += 1;
  // content
  if (has(s.lyrics)) score += 3;
  if (has(s.sentimentKeywords)) score += 1;
  if (s.sentimentSource === 'lyrics') score += 1; // derived from real lyrics > inferred
  // misc populated metadata
  if (s.lengthMs != null) score += 1;
  if (s.explicit != null) score += 0.5;
  if (s.lyricsStatus === 'found') score += 0.5;
  return score;
}

/**
 * Dedup tracks within every album IN PLACE. Mutates `idx` (idx.albums, idx.songs).
 * Returns a report: { albumsDeduped, tracksDropped, droppedSongIds:[], perAlbum:[...] }.
 */
export function dedupTracks(idx) {
  const songById = new Map(idx.songs.map((s) => [s.id, s]));
  const droppedSongIds = new Set();
  const perAlbum = [];

  for (const album of idx.albums) {
    const trackList = Array.isArray(album.trackList) ? album.trackList : [];
    // group this album's *resolvable* songs by normalized name, preserving order
    const groups = new Map(); // normName -> [{ songId, song, pos }]
    trackList.forEach((sid, pos) => {
      const song = songById.get(sid);
      if (!song) return; // dangling id — leave it for the orphan sweep below
      const key = normSongName(song.name);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push({ songId: sid, song, pos });
    });

    const dropped = [];
    for (const members of groups.values()) {
      if (members.length < 2) continue;
      // pick the keeper: highest completeness; tie -> earliest position (stable)
      let keeper = members[0];
      for (const m of members) {
        const ms = completeness(m.song);
        const ks = completeness(keeper.song);
        if (ms > ks || (ms === ks && m.pos < keeper.pos)) keeper = m;
      }
      for (const m of members) {
        if (m === keeper) continue;
        dropped.push(m.songId);
        droppedSongIds.add(m.songId);
      }
    }

    if (dropped.length) {
      const drop = new Set(dropped);
      album.trackList = trackList.filter((sid) => !drop.has(sid));
      perAlbum.push({
        albumId: album.id,
        artist: album.artist,
        name: album.name,
        dropped: dropped.length,
        keptTracks: album.trackList.length,
      });
    }
  }

  // remove the dropped SongItems from index.songs (no orphans)
  if (droppedSongIds.size) {
    idx.songs = idx.songs.filter((s) => !droppedSongIds.has(s.id));
  }

  return {
    albumsDeduped: perAlbum.length,
    tracksDropped: droppedSongIds.size,
    droppedSongIds: [...droppedSongIds],
    perAlbum,
  };
}

// ---- CLI ----
function arg(f, d) {
  const i = process.argv.indexOf(f);
  return i >= 0 ? process.argv[i + 1] : d;
}

function main() {
  const indexPath = arg('--index', 'index-out/current/index.json');
  const outPath = arg('--out', indexPath);
  const reportPath = arg('--report', null);
  const dryRun = process.argv.includes('--dry-run');

  const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
  const before = { albums: idx.albums.length, songs: idx.songs.length };
  const report = dedupTracks(idx);

  if (!dryRun) writeFileSync(outPath, JSON.stringify(idx));
  if (reportPath) writeFileSync(reportPath, JSON.stringify(report, null, 2));

  process.stderr.write(
    `dedup-tracks: ${report.albumsDeduped} album(s) deduped, ${report.tracksDropped} ` +
      `duplicate track(s) dropped (${before.songs} -> ${idx.songs.length} songs)` +
      `${dryRun ? ' [dry-run, not written]' : ` -> ${outPath}`}\n`,
  );
}

// only run as a script (not when imported by the test)
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
