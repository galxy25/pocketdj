// Merge enrichment shards into the canonical index.json + coverage report.
// Pure (no I/O); the CLI passes shard objects in and writes the results out.
//
// Shard shape (returned by the workflow, one per batch):
//   { batchIndex, albums: IndexAlbum[], songs: IndexSong[], log: AlbumLog[] }

import { INDEX_SCHEMA_VERSION } from './schema-version.js';

const DEFERRED = ['song.bpm', 'song.key', 'song.pointer.timestamps'];

/**
 * @param {object[]} shards  per-batch {albums, songs, log}
 * @param {object} meta      { source, generatedAt, sourceName, parseLines, parseVinyl, batchSize }
 */
export function mergeShards(shards, meta = {}) {
  const albumsById = new Map();
  const songsById = new Map();
  const runLog = [];

  for (const shard of shards) {
    if (!shard) continue;
    for (const a of shard.albums || []) albumsById.set(a.id, a);
    for (const s of shard.songs || []) songsById.set(s.id, s);
    for (const l of shard.log || []) runLog.push(l);
  }

  const albums = [...albumsById.values()];
  const songs = [...songsById.values()];

  // Counts
  const albumsMatched = albums.filter((a) => a.enrichment?.status === 'matched').length;
  const albumsUnmatched = albums.length - albumsMatched;
  const songsWithLyrics = songs.filter((s) => s.lyricsStatus === 'found').length;
  const sentimentFromLyrics = songs.filter((s) => s.sentimentSource === 'lyrics').length;
  const sentimentInferred = songs.filter((s) => s.sentimentSource === 'inferred').length;
  const sentimentFailed = songs.filter((s) => s.sentimentSource === 'failed').length;

  const counts = {
    lines: meta.parseLines ?? null,
    vinylLines: meta.parseVinyl ?? albums.length,
    albums: albums.length,
    songs: songs.length,
    albumsMatched,
    albumsUnmatched,
    songsWithLyrics,
    sentimentFromLyrics,
    sentimentInferred,
  };

  const index = {
    manifest: {
      source: meta.source ?? 'Vinyl.md',
      generatedAt: meta.generatedAt ?? new Date().toISOString(),
      schemaVersion: INDEX_SCHEMA_VERSION,
      sourceType: 'analog',
      sourceName: meta.sourceName ?? 'My Vinyl',
      counts,
      deferredFields: DEFERRED,
      batches: meta.batchSize
        ? { size: meta.batchSize, count: shards.length, completed: shards.filter(Boolean).length }
        : undefined,
    },
    albums,
    songs,
  };

  // Coverage scorecard
  const strong = albums.filter((a) => a.enrichment?.matchConfidence === 'strong').length;
  const weak = albums.filter((a) => a.enrichment?.matchConfidence === 'weak').length;
  const dupGroups = countDupGroups(albums);
  const coverageReport = {
    generatedAt: index.manifest.generatedAt,
    source: index.manifest.source,
    albums: {
      total: albums.length,
      matchedStrong: strong,
      matchedWeak: weak,
      unmatched: albumsUnmatched,
      matchRate: ratio(albumsMatched, albums.length),
    },
    songs: {
      total: songs.length,
      withLyrics: songsWithLyrics,
      lyricsRate: ratio(songsWithLyrics, songs.length),
      sentimentFromLyrics,
      sentimentInferred,
      sentimentFailed,
    },
    fields: {
      withCover: albums.filter((a) => a.coverArt).length,
      withYear: albums.filter((a) => a.year != null).length,
      withGenre: albums.filter((a) => a.genre).length,
      withCountry: albums.filter((a) => a.country).length,
      deferred: DEFERRED,
    },
    duplicates: { rawDupGroups: dupGroups },
    flags: {
      variousArtists: albums.filter((a) => /various/i.test(a.artist || '')).length,
      weakMatchesToReview: albums
        .filter((a) => a.enrichment?.matchConfidence === 'weak')
        .map((a) => a.id)
        .slice(0, 50),
    },
  };

  return { index, coverageReport, runLog };
}

function ratio(n, d) {
  return d ? Number((n / d).toFixed(3)) : 0;
}

function countDupGroups(albums) {
  const groups = new Map();
  for (const a of albums) {
    const key = `${(a.artist || '').toLowerCase()}|${(a.name || '').toLowerCase()}`;
    groups.set(key, (groups.get(key) || 0) + 1);
  }
  let dup = 0;
  for (const v of groups.values()) if (v > 1) dup++;
  return dup;
}
