// Turn the workflow's self-contained "enriched album" shards into canonical
// IndexAlbum[] + IndexSong[] with content-derived ids. Runs in the main loop
// (Node), so id hashing lives here — agents never generate ids.
//
// EnrichedAlbum (one per input candidate, produced by the enrich+sentiment
// pipeline) carries the original filename fields (attached by the workflow) plus
// the enrichment + nested tracks (+ per-track sentiment):
//   {
//     candidateIndex, originalFilename, fileLocation, fileType, dupIndex,
//     status, matchConfidence, score, itunesCollectionId, sources,
//     artist, name, coverArt, genre, year, country,
//     tracks: [ { discNumber, trackNumber, name, artist, year, lengthMs,
//                 explicit, lyrics, lyricsStatus, sentimentKeywords, sentimentSource } ]
//   }

import { albumId, songId } from './ids.js';

const FILETYPES = new Set(['mp3', 'aiff', 'm4a', 'flac', 'wav', 'aac']);
const cleanFileType = (ft) => (FILETYPES.has(String(ft)) ? String(ft) : undefined);

/** Assemble one shard of enriched albums into {albums, songs, log}. */
export function assembleShard(enrichedAlbums) {
  const albums = [];
  const songs = [];
  const log = [];

  for (const ea of enrichedAlbums || []) {
    const dup = ea.dupIndex ?? null;
    const id = albumId(ea.artist || '', ea.name || '', dup);
    const fileType = cleanFileType(ea.fileType);
    const tracks = Array.isArray(ea.tracks) ? ea.tracks : [];

    const trackList = [];
    for (const t of tracks) {
      const disc = t.discNumber ?? 1;
      const trackNumber = t.trackNumber ?? null;
      if (trackNumber == null) continue;
      const sid = songId(id, trackNumber, disc);
      trackList.push(sid);
      songs.push({
        id: sid,
        albumId: id,
        artist: t.artist || ea.artist || '',
        name: t.name || '',
        trackNumber,
        year: t.year ?? ea.year,
        lyrics: t.lyrics ?? null,
        lyricsStatus: t.lyricsStatus || (t.lyrics ? 'found' : 'notfound'),
        sentimentKeywords: Array.isArray(t.sentimentKeywords) ? t.sentimentKeywords : [],
        sentimentSource: t.sentimentSource || (t.sentimentKeywords?.length ? 'inferred' : 'failed'),
        explicit: !!t.explicit,
        bpm: null,
        key: null,
        length: t.lengthMs ?? undefined,
        fileType,
        pointer: {
          fileLocation: ea.fileLocation || undefined,
          filename: ea.originalFilename || undefined,
          disc,
          track: trackNumber,
          timestamps: null,
        },
      });
    }

    albums.push({
      id,
      artist: ea.artist || '',
      name: ea.name || '',
      coverArt: ea.coverArt || undefined,
      genre: ea.genre || undefined,
      year: ea.year ?? undefined,
      country: ea.country || undefined,
      trackList,
      fileType,
      pointer: {
        fileLocation: ea.fileLocation || undefined,
        originalFilename: ea.originalFilename || undefined,
      },
      enrichment: {
        status: ea.status === 'matched' ? 'matched' : 'unmatched',
        matchConfidence: ea.matchConfidence,
        itunesCollectionId: ea.itunesCollectionId,
        score: ea.score,
        sources: Array.isArray(ea.sources) ? ea.sources : undefined,
      },
    });

    log.push({
      candidateIndex: ea.candidateIndex,
      originalFilename: ea.originalFilename,
      albumId: id,
      status: ea.status,
      matchConfidence: ea.matchConfidence,
      score: ea.score,
      itunesCollectionId: ea.itunesCollectionId,
      sources: ea.sources,
      trackCount: trackList.length,
      lyricsFound: songs.filter((s) => s.albumId === id && s.lyricsStatus === 'found').length,
      calls: ea.calls,
    });
  }

  return { albums, songs, log };
}
