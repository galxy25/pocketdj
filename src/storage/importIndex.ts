// Import an index.json (indexer output or mock) into a data source. Maps the
// on-disk shape (types/index-json.ts) onto the internal model, bulk-inserts, then
// hydrates cover art (download real URLs / generate placeholders) for offline use.
import type { IndexJson, IndexAlbum, IndexSong } from '../types/index-json';
import { INDEX_SCHEMA_MAJOR } from '../types/index-json';
import type { AlbumItem, AudioTrack, SongItem, DataSource, MusicItem, FileType } from '../types/model';
import type { Playlist, SongNode, SequenceNode } from '../types/collections';
import { newNodeId } from '../types/collections';
import { bulkPutItems, putSource, getAlbums, countItems, bulkPutPlaylists } from './repo';
import { cacheArtUrl, cacheArtSources, generatePlaceholder, artKeyFor } from './artCache';
import { categorize } from '../starmap/constellationMap';
import { pMap } from '../lib/concurrency';
import { hashKey } from '../lib/prng';
import { txn } from '../lib/log';

const FILETYPES: FileType[] = ['mp3', 'aiff', 'm4a', 'flac', 'wav', 'aac'];
const asFileType = (s?: string): FileType | undefined =>
  s && (FILETYPES as string[]).includes(s) ? (s as FileType) : undefined;

/** Deterministic source id so re-importing the same named source upserts it. */
export function sourceIdFor(sourceType: string, sourceName: string): string {
  return 'src_' + hashKey(`${sourceType}:${sourceName}`);
}

export interface ImportResult {
  source: DataSource;
  counts: { albums: number; songs: number };
}

export async function importIndexJson(index: IndexJson, opts: { sourceName?: string } = {}): Promise<ImportResult> {
  const major = parseInt(index.manifest.schemaVersion.split('.')[0], 10);
  if (major !== INDEX_SCHEMA_MAJOR) {
    throw new Error(`Index schemaVersion ${index.manifest.schemaVersion} incompatible with app major ${INDEX_SCHEMA_MAJOR}`);
  }
  const now = Date.now();
  const sourceName = opts.sourceName || index.manifest.sourceName || 'My Vinyl';
  const sourceId = sourceIdFor(index.manifest.sourceType, sourceName);

  const albums: AlbumItem[] = index.albums.map((a) => mapAlbum(a, sourceId, now));
  // Stamp each song with its album's TOP-LEVEL genre category (derived, not stored) so
  // songs are filterable/sortable by genre in the browser.
  const categoryByAlbum = new Map(index.albums.map((a) => [a.id, categorize(a.genre).category]));
  const songs: SongItem[] = index.songs.map((s) =>
    mapSong(s, sourceId, now, s.albumId ? categoryByAlbum.get(s.albumId) : undefined),
  );

  await bulkPutItems([...albums, ...songs]);

  // Import source-native playlists (e.g. iTunes) as MIRROR playlists attributed to
  // this source. Stable, source-scoped ids so re-import upserts (never duplicates,
  // never clobbers hand-built playlists). Refs to songs missing from this index are
  // still placed (sourceId-stamped) so the UI can degrade gracefully.
  let playlistsImported = 0;
  if (index.playlists?.length) {
    const present = new Set(songs.map((s) => s.id));
    const mirrors: Playlist[] = index.playlists.map((p) =>
      mapPlaylist(p, sourceId, sourceName, present, now),
    );
    await bulkPutPlaylists(mirrors);
    playlistsImported = mirrors.length;
  }

  const source: DataSource = {
    id: sourceId,
    type: index.manifest.sourceType,
    name: sourceName,
    createdAt: now,
    updatedAt: now,
    itemCount: { albums: albums.length, songs: songs.length },
  };
  await putSource(source);

  txn('import.index', {
    sourceId, albums: albums.length, songs: songs.length,
    playlists: playlistsImported, source: index.manifest.source,
  });
  return { source, counts: { albums: albums.length, songs: songs.length } };
}

/**
 * Map a source-native playlist onto an app Playlist MIRROR. The app id is derived
 * from (sourceId, external id) so re-import is idempotent. Every song becomes a
 * SongNode stamped with sourceId; refs absent from this index are still added
 * (the UI shows them as out-of-source cues — graceful degradation).
 */
function mapPlaylist(
  p: { id: string; name: string; songIds: string[] },
  sourceId: string,
  _sourceName: string,
  present: Set<string>,
  now: number,
): Playlist {
  const id = 'pls_' + hashKey(`${sourceId}:${p.id}`);
  const children: SongNode[] = p.songIds.map((songId) => ({
    nodeId: newNodeId(),
    kind: 'song',
    songId,
    sourceId,
  }));
  const seq: SequenceNode = {
    nodeId: newNodeId(),
    kind: 'sequence',
    name: p.name,
    children,
  };
  void present; // referenced for intent; absence is handled at view time
  return {
    id,
    name: p.name,
    sequences: [seq],
    importedFrom: { sourceId, externalId: p.id },
    createdAt: now,
    updatedAt: now,
  };
}

function mapAlbum(a: IndexAlbum, sourceId: string, now: number): AlbumItem {
  const rollup = audioRollup(a.audioTracks);
  return {
    id: a.id,
    sourceId,
    type: 'album',
    artist: a.artist,
    name: a.name,
    coverArtUrl: a.coverArt,
    coverArtSources: a.coverArtSources,
    // Derived with no network so covers can resolve immediately; the actual thumbnail is
    // fetched lazily (on render) / warmed in the background — first paint never blocks on art.
    coverArtKey: artKeyFor({ coverArtSources: a.coverArtSources, coverArtUrl: a.coverArt, id: a.id }),
    genre: a.genre,
    year: a.year,
    country: a.country,
    trackIds: a.trackList ?? [],
    pointer: a.pointer
      ? { location: a.pointer.fileLocation, filename: a.pointer.originalFilename }
      : undefined,
    fileType: asFileType(a.fileType),
    enrichment: a.enrichment as AlbumItem['enrichment'],
    audioTracks: a.audioTracks,
    audioDurationSec: a.audioDurationSec,
    audioBpm: rollup.audioBpm,
    audioCamelot: rollup.audioCamelot,
    audioKey: rollup.audioKey,
    createdAt: now,
    updatedAt: now,
  };
}

/** Median of a non-empty numeric list (lower-middle of the two for even counts). */
function median(nums: number[]): number {
  const sorted = [...nums].sort((x, y) => x - y);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/**
 * Most-common value in a list of strings. Ties are broken deterministically by
 * the value's FIRST appearance order (stable), so re-imports are idempotent.
 */
function mostCommon(values: string[]): string | null {
  if (values.length === 0) return null;
  const counts = new Map<string, number>();
  const firstSeen = new Map<string, number>();
  values.forEach((v, i) => {
    counts.set(v, (counts.get(v) ?? 0) + 1);
    if (!firstSeen.has(v)) firstSeen.set(v, i);
  });
  let best: string | null = null;
  let bestCount = -1;
  for (const [v, c] of counts) {
    if (c > bestCount || (c === bestCount && firstSeen.get(v)! < firstSeen.get(best!)!)) {
      best = v;
      bestCount = c;
    }
  }
  return best;
}

/**
 * Derive the album-level audio rollup from its detected segments. Used to group
 * + sort albums on the star map without re-scanning every track. All three are
 * `null` when there are no audioTracks (audio stage hasn't run yet).
 *   audioBpm     = MEDIAN of the segment BPMs, rounded.
 *   audioCamelot = most-common segment camelot.
 *   audioKey     = most-common segment key.
 */
export function audioRollup(
  tracks: Pick<AudioTrack, 'bpm' | 'key' | 'camelot'>[] | undefined | null,
): { audioBpm: number | null; audioCamelot: string | null; audioKey: string | null } {
  if (!tracks || tracks.length === 0) {
    return { audioBpm: null, audioCamelot: null, audioKey: null };
  }
  const bpms = tracks.map((t) => t.bpm).filter((b): b is number => typeof b === 'number' && isFinite(b));
  const camelots = tracks.map((t) => t.camelot).filter((c): c is string => typeof c === 'string' && c.length > 0);
  const keys = tracks.map((t) => t.key).filter((k): k is string => typeof k === 'string' && k.length > 0);
  return {
    audioBpm: bpms.length ? Math.round(median(bpms)) : null,
    audioCamelot: mostCommon(camelots),
    audioKey: mostCommon(keys),
  };
}

function mapSong(s: IndexSong, sourceId: string, now: number, genre?: string): SongItem {
  return {
    id: s.id,
    sourceId,
    type: 'song',
    albumId: s.albumId,
    trackNumber: s.trackNumber,
    year: s.year,
    artist: s.artist,
    name: s.name,
    genre,
    lyrics: s.lyrics ?? undefined,
    lyricsStatus: s.lyricsStatus,
    sentimentKeywords: s.sentimentKeywords ?? [],
    sentimentSource: s.sentimentSource,
    explicit: !!s.explicit,
    bpm: s.bpm ?? null,
    key: s.key ?? null,
    camelot: s.camelot ?? null,
    lengthMs: s.length,
    pointer: s.pointer
      ? {
          location: s.pointer.fileLocation,
          filename: s.pointer.filename ?? s.pointer.originalFilename,
          disc: s.pointer.disc,
          track: s.pointer.track,
          // apply-audio.mjs writes startMs/endMs flat on the pointer; fall back
          // to the nested `timestamps` shape for older index files.
          startMs: s.pointer.startMs ?? s.pointer.timestamps?.startMs ?? null,
          endMs: s.pointer.endMs ?? s.pointer.timestamps?.endMs ?? null,
        }
      : undefined,
    fileType: asFileType(s.fileType),
    createdAt: now,
    updatedAt: now,
  };
}

/**
 * WARM the cover-art cache for all albums in a source: download real URLs into blobs (or
 * generate a deterministic placeholder), keyed by the same key already on each album
 * (artKeyFor, set at import). This is idempotent and meant to run in the BACKGROUND —
 * it never blocks first paint. As each thumbnail lands it notifies subscribers
 * (useArtUrl), so mounted covers pop in progressively. Bounded concurrency.
 *
 * Albums no longer need a putItem here (their coverArtKey was assigned at import), so a
 * fresh device caches everything for offline use without a write storm.
 */
export async function hydrateArt(
  sourceId: string,
  onProgress?: (done: number, total: number) => void,
  opts: { placeholders?: boolean } = {},
): Promise<{ cached: number; placeholders: number }> {
  // Digital sources (e.g. Apple Music) carry no art and there can be tens of
  // thousands of albums — generating a placeholder blob for each would be a huge,
  // pointless write storm. Callers pass { placeholders: false } there; art-less
  // tiles fall back to the CSS night-sky cell at render time. (Per product: cover
  // art for digital is only added later via a rip/burn.)
  const makePlaceholders = opts.placeholders !== false;
  const albums = await getAlbums(sourceId);
  let cached = 0;
  let placeholders = 0;
  await pMap(
    albums,
    async (a: AlbumItem) => {
      if (a.coverArtSources && a.coverArtSources.length) {
        await cacheArtSources(a.coverArtSources);
        cached++;
      } else if (a.coverArtUrl) {
        await cacheArtUrl(a.coverArtUrl);
        cached++;
      } else if (makePlaceholders) {
        await generatePlaceholder(a.id);
        placeholders++;
      }
    },
    6,
    onProgress,
  );
  return { cached, placeholders };
}

/** Convenience: current global counts (for window.__pdj.counts()). */
export async function getCounts(): Promise<{ albums: number; songs: number }> {
  return countItems();
}

export type { MusicItem };
