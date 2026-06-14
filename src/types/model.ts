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
// - `bpm`, `key` and `camelot` come from the AUDIO stage (apply-audio.mjs). When
//   audio has not been analyzed they are `null`, never `undefined`, so "pending
//   audio analysis" stays explicit.

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

/**
 * One detected audio segment for an album — the AUDIO ground truth produced by
 * the analog-indexer audio stage (apply-audio.mjs). The segmentation is
 * independent of the metadata tracklist, so `audioTracks.length` MAY DIFFER from
 * `AlbumItem.trackIds.length` by design. Order is the playback/segment order.
 */
export interface AudioTrack {
  /** 1-based audio segment order (not necessarily the metadata track number). */
  trackNumber: number;
  /** Segment start within the recorded side, in ms. */
  startMs: number;
  /** Segment end within the recorded side, in ms. */
  endMs: number;
  /** Segment duration in ms (endMs - startMs). */
  durationMs: number;
  /** Beats per minute. */
  bpm: number;
  /** Musical key, e.g. "F# major". */
  key: string;
  /** Camelot-wheel notation, e.g. "2B" (<1-12><A|B>; A=minor, B=major). */
  camelot: string;
  /** Optional key-detection confidence (0..1). */
  keyStrength?: number;
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

/**
 * One album-art source in a progressive (ordered, most-preferred-first) list.
 * `cdn` = our own CORS-friendly origin (cacheable into an offline blob — the default);
 * `remote` = a third-party service URL (online-only backup). The app prefers the first
 * cacheable source and falls back to the next on miss, so art can migrate to the CDN
 * incrementally without breaking albums that only have a remote URL yet.
 */
export interface ArtSource {
  type: 'cdn' | 'remote';
  url: string;
  /** Hint: may we fetch+thumbnail it into an offline blob (same-origin / CORS-ok)? */
  cors?: boolean;
}

export interface AlbumItem extends BaseItem {
  type: 'album';
  artist: string;
  name: string;
  /** Blob cache key in the `art` store (set after the cover is downloaded/generated). */
  coverArtKey?: string;
  /** Original cover-art URL (kept for re-fetch / repair). */
  coverArtUrl?: string;
  /** Progressive art sources (ordered; CDN default + remote backup). Preferred over coverArtUrl. */
  coverArtSources?: ArtSource[];
  genre?: string;
  year?: number;
  country?: string;
  /** Ordered refs to SongItem.id. */
  trackIds: string[];
  pointer?: Pointer;
  fileType?: FileType;
  /** Provenance of the enrichment (match confidence etc.) — informational. */
  enrichment?: AlbumEnrichment;
  /**
   * AUDIO ground truth: detected segments (bpm/key/camelot/bounds). Present once
   * the audio stage has run. Count may differ from `trackIds` — see AudioTrack.
   */
  audioTracks?: AudioTrack[];
  /** Total analyzed audio duration of the recording, in seconds. */
  audioDurationSec?: number;
  /**
   * ALBUM-LEVEL AUDIO ROLLUP — derived from `audioTracks` at import time so the
   * star map can group/sort albums by audio without re-scanning every track.
   * `null` when the album has no `audioTracks` (audio stage hasn't run); never
   * `undefined` once an album with tracks is imported, so "no audio" stays
   * explicit (mirrors SongItem.bpm/key). Recomputed in importIndex.ts:
   *   audioBpm     = MEDIAN of audioTracks[].bpm, rounded.
   *   audioCamelot = most-common camelot value (e.g. "8A").
   *   audioKey     = most-common key value (e.g. "A minor").
   */
  audioBpm?: number | null;
  audioCamelot?: string | null;
  audioKey?: string | null;
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
  /** Top-level genre CATEGORY of the owning album (derived at import via categorize) —
   *  so songs are filterable/sortable by genre, e.g. "soul songs with BPM 80–90". */
  genre?: string;
  lyrics?: string;
  lyricsStatus?: LyricsStatus;
  /** Mood/theme keywords from Haiku sentiment analysis. */
  sentimentKeywords: string[];
  sentimentSource?: SentimentSource;
  explicit: boolean;
  /** From AUDIO stage (best-effort, by segment order). Null until analyzed. */
  bpm: number | null;
  /** From AUDIO stage, e.g. "F# major". Null until analyzed. */
  key: string | null;
  /** From AUDIO stage, Camelot notation e.g. "2B". Null/absent until analyzed. */
  camelot?: string | null;
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
