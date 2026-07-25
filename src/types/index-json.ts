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
  /**
   * Optional source-native playlists (e.g. iTunes/Apple Music user playlists).
   * Imported into app Playlists, attributed to this index's data source, and
   * degrade gracefully when a referenced song isn't in the loaded catalog.
   */
  playlists?: IndexPlaylist[];
}

/** A source-native playlist: an ordered list of song refs (IndexSong.id). */
export interface IndexPlaylist {
  /** Stable, source-scoped id (e.g. "pl_" + hash of the source persistent id). */
  id: string;
  name: string;
  /** Ordered refs to IndexSong.id. Refs not present in `songs` are kept as cues. */
  songIds: string[];
}

export interface IndexManifest {
  /** Source file the index was built from, e.g. "Vinyl.md". */
  source: string;
  /** ISO timestamp. */
  generatedAt: string;
  /** SemVer; the app asserts the MAJOR matches INDEX_SCHEMA_MAJOR. */
  schemaVersion: string;
  sourceType: 'analog' | 'digital';
  /** Suggested data-source name when importing, e.g. "My Vinyl" or "Apple Music (Local)". */
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

/** One album-art source in a progressive (ordered) list. See model.ArtSource. */
export interface IndexArtSource {
  type: 'cdn' | 'remote';
  url: string;
  cors?: boolean;
}

export interface IndexAlbum {
  id: string;
  artist: string;
  name: string;
  /** Cacheable cover-art URL (e.g. iTunes 600x600). May be absent. The remote/backup source. */
  coverArt?: string;
  /**
   * Progressive art sources, ordered most-preferred-first: our CDN-hosted thumbnail
   * (CORS-friendly, cacheable offline) as the default + the original remote URL as a
   * backup. When present, the app prefers this over `coverArt`. Populated incrementally
   * by the art-mirror step (lib/mirror-art.mjs); absent until an album is mirrored.
   */
  coverArtSources?: IndexArtSource[];
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
  /** AUDIO stage: detected segments (apply-audio.mjs). Count may differ from trackList. */
  audioTracks?: IndexAudioTrack[];
  /** AUDIO stage: total analyzed audio duration, in seconds. */
  audioDurationSec?: number;
  /** Apple Music album store id (iTunes `collectionId`); see IndexSong.appleMusicId. */
  appleMusicId?: string;
  /**
   * F3 "Sharing" canonical deep-links. `appleMusicUrl` is derived from `appleMusicId`
   * (`https://music.apple.com/album/<id>`, scripts/fold-apple-music-links.mjs);
   * `spotifyUrl` / `youtubeUrl` are resolved by the headless-browser worker
   * (scripts/resolve-streaming-links.mjs). Absent until the pipeline stamps them.
   */
  appleMusicUrl?: string;
  spotifyUrl?: string;
  youtubeUrl?: string;
}

/** One detected audio segment, on disk. Mirrors model.AudioTrack 1:1. */
export interface IndexAudioTrack {
  /** 1-based audio segment order. */
  trackNumber: number;
  startMs: number;
  endMs: number;
  durationMs: number;
  bpm: number;
  /** e.g. "F# major". */
  key: string;
  /** Camelot notation, e.g. "2B". */
  camelot: string;
  keyStrength?: number;
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
  /** AUDIO stage: best-effort BPM by segment order. Null/absent until analyzed. */
  bpm?: number | null;
  /** AUDIO stage: best-effort key, e.g. "F# major". Null/absent until analyzed. */
  key?: string | null;
  /** AUDIO stage: best-effort Camelot, e.g. "2B". Null/absent until analyzed. */
  camelot?: string | null;
  /** Length in milliseconds. */
  length?: number;
  fileType?: string;
  pointer?: IndexPointer;
  /**
   * Apple Music catalog store id ("adam id"), resolved via the iTunes Search API
   * (scripts/resolve-apple-music-catalog.mjs). A bare numeric string; absent when unresolved.
   */
  appleMusicId?: string;
  /**
   * F3 "Sharing" canonical deep-links. `appleMusicUrl` is derived from `appleMusicId`
   * (`https://music.apple.com/song/<id>`, scripts/fold-apple-music-links.mjs);
   * `spotifyUrl` / `youtubeUrl` are resolved by the headless-browser worker
   * (scripts/resolve-streaming-links.mjs). Absent until the pipeline stamps them.
   */
  appleMusicUrl?: string;
  spotifyUrl?: string;
  youtubeUrl?: string;
}

export interface IndexPointer {
  fileLocation?: string;
  filename?: string;
  originalFilename?: string;
  disc?: number;
  track?: number;
  timestamps?: null | { startMs: number; endMs: number };
  /** AUDIO stage writes these flat on the pointer (apply-audio.mjs). */
  startMs?: number | null;
  endMs?: number | null;
}
