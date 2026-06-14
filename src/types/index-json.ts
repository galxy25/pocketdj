// The on-disk index JSON shape produced by the analog-indexer skill and
// consumed by the app loader (src/storage/importIndex.ts).
//
// This is the CONTRACT between the indexer and the app. It is intentionally
// decoupled from the internal model (./model.ts) so the importer can normalize
// and migrate. The canonical JSON Schema lives at
// .claude/skills/analog-indexer/schema/index.schema.json and must stay in sync.
//
// Stable, content-derived ids make re-runs idempotent:
//   albumId = "alb_" + sha1(normArtist|normAlbum|dupIndex)[:12]
//   songId  = "sng_" + sha1(albumId|track|disc)[:12]

export const INDEX_SCHEMA_MAJOR = 1;
export const INDEX_SCHEMA_VERSION = '1.0.0';

export interface IndexJson {
  manifest: IndexManifest;
  albums: IndexAlbum[];
  songs: IndexSong[];
}

export interface IndexManifest {
  /** Source file the index was built from, e.g. "Vinyl.md". */
  source: string;
  /** ISO timestamp. */
  generatedAt: string;
  /** SemVer; the app asserts the MAJOR matches INDEX_SCHEMA_MAJOR. */
  schemaVersion: string;
  sourceType: 'analog';
  /** Suggested data-source name when importing, e.g. "My Vinyl". */
  sourceName?: string;
  counts: IndexCounts;
  /** Fields intentionally left null this iteration (need the audio file). */
  deferredFields: string[];
  batches?: { size: number; count: number; completed: number };
}

export interface IndexCounts {
  lines: number;
  vinylLines: number;
  albums: number;
  songs: number;
  albumsMatched: number;
  albumsUnmatched: number;
  songsWithLyrics: number;
  sentimentFromLyrics: number;
  sentimentInferred: number;
}

export interface IndexAlbum {
  id: string;
  artist: string;
  name: string;
  /** Cacheable cover-art URL (e.g. iTunes 600x600). May be absent. */
  coverArt?: string;
  genre?: string;
  year?: number;
  country?: string;
  /** Ordered refs to IndexSong.id. */
  trackList: string[];
  fileType?: string;
  pointer?: IndexPointer;
  enrichment?: {
    status: 'matched' | 'unmatched';
    matchConfidence?: 'strong' | 'weak';
    itunesCollectionId?: number;
    score?: number;
    sources?: string[];
  };
}

export interface IndexSong {
  id: string;
  albumId?: string;
  artist: string;
  name: string;
  trackNumber?: number;
  year?: number;
  lyrics?: string | null;
  lyricsStatus?: 'found' | 'notfound' | 'error';
  sentimentKeywords?: string[];
  sentimentSource?: 'lyrics' | 'inferred' | 'failed';
  explicit?: boolean;
  /** DEFERRED: always null. */
  bpm?: null;
  /** DEFERRED: always null. */
  key?: null;
  /** Length in milliseconds. */
  length?: number;
  fileType?: string;
  pointer?: IndexPointer;
}

export interface IndexPointer {
  fileLocation?: string;
  filename?: string;
  originalFilename?: string;
  disc?: number;
  track?: number;
  timestamps?: null | { startMs: number; endMs: number };
}
