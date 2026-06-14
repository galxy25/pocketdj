#!/usr/bin/env node
// TRACK-CLEANUP, orphan sweep: RE-ATTACH songs whose albumId resolves to a real album but
// which are missing from that album's trackList (deterministic, no network).
//
// Messy merges can leave a SongItem pointing at the correct album (s.albumId === album.id)
// yet absent from album.trackList — e.g. Jay-Z "Vol. 3... Life and Times of S. Carter"
// listed 15 tracks but its two BONUS tracks "Jigga My Nigga" (#16) and "Girl's Best Friend"
// (#17) — scraped from a different source file — were left dangling (web-confirmed bonus
// tracks of that exact release). The app's getAlbumSongs() finds them by albumId, so they'd
// silently never render. This fold puts each such song back into its album's trackList.
//
//   node reattach-orphans.mjs [--index index-out/current/index.json] [--out <same>]
//                             [--report path.json] [--dry-run]
//
// Insertion: the orphan is placed at the position implied by its trackNumber (so a
// trackNumber-ordered trackList stays ordered); if trackNumber is missing/out of range it's
// appended at the end. trackNumbers are NOT rewritten here — run renumber-tracks.mjs after
// if numbering needs repair.
//
// Metadata-ownership rule (load-bearing): this fold ONLY adds an existing songId into the
// matching album.trackList. It never creates/deletes songs, never edits song fields, and
// never touches coverArt(Sources), audioTracks, audio bpm/key/camelot, lyrics, sentiment,
// or album-level metadata. Idempotent: a song already in its trackList is left alone.
//
// A song whose albumId does NOT resolve to any album (a TRUE orphan) is reported but left
// untouched — there's no album to attach it to.
//
// Exports reattachOrphans(idx) for unit tests (no I/O when imported).
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * Re-attach reattachable orphans IN PLACE. Mutates `idx`.
 * Returns { reattached, trueOrphans, perSong:[...] }.
 */
export function reattachOrphans(idx) {
  const albById = new Map(idx.albums.map((a) => [a.id, a]));
  // index each album's current trackList membership for O(1) checks
  const memberOf = new Map(); // albumId -> Set(songId)
  for (const a of idx.albums) {
    if (!Array.isArray(a.trackList)) a.trackList = [];
    memberOf.set(a.id, new Set(a.trackList));
  }

  const perSong = [];
  let reattached = 0;
  let trueOrphans = 0;

  for (const s of idx.songs) {
    const album = albById.get(s.albumId);
    if (!album) {
      trueOrphans++;
      continue; // no album to attach to
    }
    const members = memberOf.get(album.id);
    if (members.has(s.id)) continue; // already attached

    // resolve each current member's trackNumber so we can insert in order
    const songById = perSong._songById || (perSong._songById = new Map(idx.songs.map((x) => [x.id, x])));
    const list = album.trackList;
    const tn = typeof s.trackNumber === 'number' ? s.trackNumber : null;
    let insertAt = list.length; // default: append
    if (tn != null) {
      insertAt = 0;
      while (
        insertAt < list.length &&
        (songById.get(list[insertAt])?.trackNumber ?? Infinity) <= tn
      ) {
        insertAt++;
      }
    }
    list.splice(insertAt, 0, s.id);
    members.add(s.id);
    reattached++;
    perSong.push({
      songId: s.id,
      name: s.name,
      albumId: album.id,
      albumName: album.name,
      insertedAt: insertAt,
      trackNumber: tn,
    });
  }
  delete perSong._songById;

  return { reattached, trueOrphans, perSong };
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
  const report = reattachOrphans(idx);

  if (!dryRun) writeFileSync(outPath, JSON.stringify(idx));
  if (reportPath) writeFileSync(reportPath, JSON.stringify(report, null, 2));

  process.stderr.write(
    `reattach-orphans: ${report.reattached} song(s) re-attached to their album` +
      `${report.trueOrphans ? `, ${report.trueOrphans} true orphan(s) left (no matching album)` : ''}` +
      `${dryRun ? ' [dry-run, not written]' : ` -> ${outPath}`}\n`,
  );
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
