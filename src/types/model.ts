// PocketDJ internal data model.
//
// This is the canonical in-app representation, stored in IndexedDB. It is a
// discriminated union on `type` ('album' | 'song'). The importer maps the
// on-disk index JSON shape (see ./index-json.ts) onto these types.
//
// Design notes:
// - Numeric fields that support the "between" filter operator are stored as
//   plain numbers on a single axis: `year` (number) and `lengthMs` (ms).
//   Display formatting (mm:ss) happens at the edge, never in storage.
// - `bpm` and `key` are DEFERRED this iteration (need the audio file). They are
//   always `null`, never `undefined`, so "pending audio analysis" is explicit.

export type ItemType = 'album' | 'song';

/** The only data-source type implemented this iteration. Future: 'digital', 'streaming'. */
export type DataSourceType = 'analog';

/** File container of the underlying recording. `unknown` for items with no file yet. */
export type FileType = 'mp3' | 'aiff' | 'm4a' | 'flac' | 'wav' | 'aac' | 'unknown';

/** Sentinel id for the virtual "All" data source (browse across every source). */
export const ALL_SOURCE_ID = '__all__';

/**
 * Where the physical/recorded thing lives. For analog vinyl this is the crate/
 * shelf location + the original recording filename, plus disc/side/track and
 * (deferred) per-track timestamps within a recorded side.
 */
export interface Pointer {
  /** Free-form physical or filesystem location (crate, shelf, folder). */
  location?: string;
  /** Original recording filename, e.g. "ABBAGreatestHitsRaw.mp3". */
  filename?: string;
  disc?: number;
  track?: number;
  /** Deferred: per-track start/end within a recorded side (needs audio splitting). */
  startMs?: number | null;
  endMs?: number | null;
}

interface BaseItem {
  /** Stable id. Reuses the indexer's content-derived id (alb_… / sng_…) when imported. */
  id: string;
  /** Owning DataSource id. */
  sourceId: string;
  type: ItemType;
  createdAt: number;
  updatedAt: number;
}

export interface AlbumItem extends BaseItem {
  type: 'album';
  artist: string;
  name: string;
  /** Blob cache key in the `art` store (set after the cover is downloaded/generated). */
  coverArtKey?: string;
  /** Original cover-art URL (kept for re-fetch / repair). */
  coverArtUrl?: string;
  genre?: string;
  year?: number;
  country?: string;
  /** Ordered refs to SongItem.id. */
  trackIds: string[];
  pointer?: Pointer;
  fileType?: FileType;
  /** Provenance of the enrichment (match confidence etc.) — informational. */
  enrichment?: AlbumEnrichment;
}

export interface AlbumEnrichment {
  status: 'matched' | 'unmatched';
  matchConfidence?: 'strong' | 'weak';
  itunesCollectionId?: number;
  score?: number;
  sources?: string[];
}

export type SentimentSource = 'lyrics' | 'inferred' | 'failed';
export type LyricsStatus = 'found' | 'notfound' | 'error';

export interface SongItem extends BaseItem {
  type: 'song';
  /** Ref to AlbumItem.id. */
  albumId?: string;
  trackNumber?: number;
  year?: number;
  artist: string;
  name: string;
  lyrics?: string;
  lyricsStatus?: LyricsStatus;
  /** Mood/theme keywords from Haiku sentiment analysis. */
  sentimentKeywords: string[];
  sentimentSource?: SentimentSource;
  explicit: boolean;
  /** DEFERRED (needs audio file). Always null this iteration. */
  bpm: number | null;
  /** DEFERRED (needs audio file). Always null this iteration. */
  key: string | null;
  /** Track length in milliseconds (between-filterable). */
  lengthMs?: number;
  pointer?: Pointer;
  fileType?: FileType;
}

export type MusicItem = AlbumItem | SongItem;

export interface DataSource {
  id: string;
  type: DataSourceType;
  name: string;
  createdAt: number;
  updatedAt: number;
  itemCount: { albums: number; songs: number };
}

/** Type guards. */
export const isAlbum = (i: MusicItem): i is AlbumItem => i.type === 'album';
export const isSong = (i: MusicItem): i is SongItem => i.type === 'song';
