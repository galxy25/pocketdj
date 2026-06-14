#!/usr/bin/env node
// TRACK-CLEANUP, pass 2 of 2: TRACK-NUMBER REPAIR (run AFTER dedup-tracks.mjs).
//
// Some albums survive dedup with their track NUMBERS still wrong — e.g. the Isley Brothers
// "Between the Sheets" lists 15 DISTINCT tracks all mis-numbered (1,1,1,2,2,2,…,5,5,5).
// These aren't duplicates (nothing for dedup to drop); they just need renumbering.
//
// An album is flagged "still wrong" after dedup when EITHER:
//   - duplicate trackNumbers remain among its songs, OR
//   - its trackList length differs a lot from its audio-segment count (album.audioTracks)
//     — the audio count is a GUIDE for the expected track count, not gospel (segmentation
//     can be off), so the threshold is loose (default: differs by > 40% AND by >= 3).
//
// For each flagged album we assign trackNumber from a CANONICAL order:
//   - CANONICAL (web-search): if --canonical <file.jsonl> supplies the real release's
//     ordered titles for this albumId, match the album's songs to that order by fuzzy
//     name (Dice over normalized tokens) and number them by canonical position. Unmatched
//     survivors are appended after, in their current order.
//   - SEQUENTIAL fallback: if no canonical entry (or it's too sparse to be useful), just
//     renumber the survivors 1..N in their CURRENT trackList order.
// trackList order is rewritten to match the new numbering so the app (which sorts by
// trackNumber) renders 1..N cleanly.
//
//   node renumber-tracks.mjs [--index index-out/current/index.json] [--out <same>]
//     [--canonical web-tracklists.jsonl] [--report path.json] [--dry-run]
//
// --canonical file: one JSON object per line, EITHER keyed by albumId or by artist+name:
//   {"albumId":"alb_...","tracks":["Title 1","Title 2", ...]}
//   {"artist":"the Isley Brothers","album":"Between the Sheets","tracks":[...]}
// (the second form is what the parallel Claude WebSearch agents emit; see SKILL.md).
//
// Metadata-ownership rule (load-bearing): this fold writes ONLY song.trackNumber and the
// ORDER of album.trackList. It never adds/removes songs, never touches coverArt(Sources),
// audioTracks, audio bpm/key/camelot, lyrics, sentiment, explicit, or album-level
// metadata. Idempotent: re-running on already-repaired data leaves it unchanged.
//
// Exports flagAlbum + renumberTracks(idx, canonicalIndex) for unit tests (no I/O on import).
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { diceTokens, normalize } from './normalize.js';

const COUNT_FRAC = 0.4; // trackList vs audioTracks must differ by > this fraction ...
const COUNT_ABS = 3; //    ... AND by at least this many to count as a "count mismatch"
const MATCH_MIN = 0.5; // min Dice to accept a song<->canonical-title match

/** Does this album still look wrong after dedup? Returns {dupNumbers, countMismatch}. */
export function flagAlbum(album, songs) {
  const nums = songs.map((s) => s.trackNumber).filter((n) => n != null);
  const dupNumbers = nums.length !== new Set(nums).size;
  const audioCount = Array.isArray(album.audioTracks) ? album.audioTracks.length : 0;
  let countMismatch = false;
  if (audioCount > 0 && songs.length > 0) {
    const diff = Math.abs(songs.length - audioCount);
    countMismatch = diff >= COUNT_ABS && diff / Math.max(songs.length, audioCount) > COUNT_FRAC;
  }
  return { dupNumbers, countMismatch, flagged: dupNumbers || countMismatch };
}

/** Build a lookup from a parsed canonical-tracklist array -> Map keyed by albumId and by
 *  normalized "artist::album". Each value is { tracks:[titles] }. */
export function buildCanonicalIndex(rows) {
  const byAlbumId = new Map();
  const byArtistAlbum = new Map();
  for (const r of rows || []) {
    if (!r || !Array.isArray(r.tracks) || !r.tracks.length) continue;
    const tracks = r.tracks.map((t) => String(t || '').trim()).filter(Boolean);
    if (!tracks.length) continue;
    if (r.albumId) byAlbumId.set(r.albumId, { tracks });
    if (r.artist && r.album) {
      byArtistAlbum.set(`${normalize(r.artist)}::${normalize(r.album)}`, { tracks });
    }
  }
  return { byAlbumId, byArtistAlbum };
}

function lookupCanonical(canon, album) {
  if (!canon) return null;
  return (
    canon.byAlbumId.get(album.id) ||
    canon.byArtistAlbum.get(`${normalize(album.artist)}::${normalize(album.name)}`) ||
    null
  );
}

/**
 * Match an album's songs to a canonical ordered title list. Returns an ordered array of
 * songs (canonical-matched first in canonical order, then any unmatched survivors in their
 * original order), or null if too few matched to trust the canonical order.
 */
function orderByCanonical(songs, canonTracks) {
  const used = new Set();
  const ordered = [];
  for (const title of canonTracks) {
    let best = null;
    let bestScore = MATCH_MIN;
    for (const s of songs) {
      if (used.has(s.id)) continue;
      const score = diceTokens(s.name, title);
      if (score > bestScore) {
        bestScore = score;
        best = s;
      }
    }
    if (best) {
      used.add(best.id);
      ordered.push(best);
    }
  }
  // need a decent fraction matched for the canonical order to be trustworthy
  if (ordered.length < Math.min(songs.length, canonTracks.length) * 0.6) return null;
  // append leftover survivors in their current order
  for (const s of songs) if (!used.has(s.id)) ordered.push(s);
  return ordered;
}

/**
 * Repair track numbers IN PLACE for every flagged album. Mutates `idx`.
 * Returns { albumsRenumbered, viaCanonical, viaSequential, perAlbum:[...] }.
 */
export function renumberTracks(idx, canon) {
  const songById = new Map(idx.songs.map((s) => [s.id, s]));
  const perAlbum = [];
  let viaCanonical = 0;
  let viaSequential = 0;

  for (const album of idx.albums) {
    const trackList = Array.isArray(album.trackList) ? album.trackList : [];
    const songs = trackList.map((sid) => songById.get(sid)).filter(Boolean);
    if (songs.length < 2) continue;

    const flag = flagAlbum(album, songs);
    if (!flag.flagged) continue;

    // Already clean? If the songs are exactly 1..N in trackList order there is nothing to
    // repair — an album flagged ONLY by an audio-count mismatch (its numbering is fine; the
    // segmentation just disagreed) falls here and is left untouched. Keeps the op minimal +
    // idempotent and keeps the "renumbered" count honest.
    const alreadyClean =
      !flag.dupNumbers && songs.every((s, i) => s.trackNumber === i + 1);
    if (alreadyClean) continue;

    let ordered = null;
    let method = 'sequential';
    const canonEntry = lookupCanonical(canon, album);
    if (canonEntry) {
      ordered = orderByCanonical(songs, canonEntry.tracks);
      if (ordered) method = 'canonical';
    }
    if (!ordered) ordered = songs; // sequential fallback: keep current order

    // assign 1..N and rewrite trackList in the new order
    ordered.forEach((s, i) => {
      s.trackNumber = i + 1;
    });
    // keep any dangling (unresolved) ids at the end, undisturbed
    const orderedIds = ordered.map((s) => s.id);
    const resolved = new Set(orderedIds);
    const dangling = trackList.filter((sid) => !songById.has(sid) || !resolved.has(sid));
    album.trackList = [...orderedIds, ...dangling];

    if (method === 'canonical') viaCanonical++;
    else viaSequential++;
    perAlbum.push({
      albumId: album.id,
      artist: album.artist,
      name: album.name,
      method,
      tracks: ordered.length,
      dupNumbers: flag.dupNumbers,
      countMismatch: flag.countMismatch,
    });
  }

  return {
    albumsRenumbered: perAlbum.length,
    viaCanonical,
    viaSequential,
    perAlbum,
  };
}

// ---- CLI ----
function arg(f, d) {
  const i = process.argv.indexOf(f);
  return i >= 0 ? process.argv[i + 1] : d;
}

function readCanonicalFile(path) {
  if (!path || !existsSync(path)) return null;
  const rows = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      rows.push(JSON.parse(t));
    } catch {
      /* skip malformed line */
    }
  }
  return buildCanonicalIndex(rows);
}

function main() {
  const indexPath = arg('--index', 'index-out/current/index.json');
  const outPath = arg('--out', indexPath);
  const canonPath = arg('--canonical', null);
  const reportPath = arg('--report', null);
  const dryRun = process.argv.includes('--dry-run');

  const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
  const canon = readCanonicalFile(canonPath);
  const report = renumberTracks(idx, canon);

  if (!dryRun) writeFileSync(outPath, JSON.stringify(idx));
  if (reportPath) writeFileSync(reportPath, JSON.stringify(report, null, 2));

  process.stderr.write(
    `renumber-tracks: ${report.albumsRenumbered} album(s) renumbered ` +
      `(${report.viaCanonical} via web-search canonical, ${report.viaSequential} sequential fallback)` +
      `${dryRun ? ' [dry-run, not written]' : ` -> ${outPath}`}\n`,
  );
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
