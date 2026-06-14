// The ONLY IndexedDB access point. Every data op emits a PDJ_API transcript line
// so Playwright can verify behavior (proof-of-verification).
import { getDB, type ArtRecord, type MetaRecord } from './db';
import type { DataSource, MusicItem, AlbumItem, SongItem, ItemType } from '../types/model';
import { ALL_SOURCE_ID } from '../types/model';
import { txn } from '../lib/log';

const CHUNK = 500;

// ---- sources ----
export async function getSources(): Promise<DataSource[]> {
  const db = await getDB();
  return db.getAll('sources');
}

export async function putSource(src: DataSource): Promise<void> {
  const db = await getDB();
  await db.put('sources', src);
  txn('db.putSource', { id: src.id, name: src.name, type: src.type });
}

export async function deleteSource(sourceId: string): Promise<void> {
  const db = await getDB();
  const tx = db.transaction(['sources', 'items'], 'readwrite');
  await tx.objectStore('sources').delete(sourceId);
  let cursor = await tx.objectStore('items').index('by_source').openCursor(sourceId);
  let n = 0;
  while (cursor) {
    await cursor.delete();
    n++;
    cursor = await cursor.continue();
  }
  await tx.done;
  txn('db.deleteSource', { id: sourceId, items: n });
}

// ---- items ----
export async function getItem(id: string): Promise<MusicItem | undefined> {
  const db = await getDB();
  return db.get('items', id);
}

export async function putItem(item: MusicItem): Promise<void> {
  const db = await getDB();
  item.updatedAt = Date.now();
  await db.put('items', item);
  txn('db.putItem', { id: item.id, type: item.type, sourceId: item.sourceId });
}

/** Delete a song from the index: removes the item AND drops it from its album's trackIds. */
export async function deleteSong(songId: string): Promise<void> {
  const db = await getDB();
  const song = (await db.get('items', songId)) as SongItem | undefined;
  await db.delete('items', songId);
  if (song?.albumId) {
    const album = (await db.get('items', song.albumId)) as AlbumItem | undefined;
    if (album && Array.isArray(album.trackIds)) {
      album.trackIds = album.trackIds.filter((id) => id !== songId);
      await db.put('items', album);
    }
  }
  txn('db.deleteSong', { id: songId, album: song?.albumId });
}

/** Bulk insert in chunked transactions (never one txn per record at 15k scale). */
export async function bulkPutItems(items: MusicItem[]): Promise<void> {
  const db = await getDB();
  for (let i = 0; i < items.length; i += CHUNK) {
    const slice = items.slice(i, i + CHUNK);
    const tx = db.transaction('items', 'readwrite');
    const store = tx.objectStore('items');
    await Promise.all(slice.map((it) => store.put(it)));
    await tx.done;
  }
  txn('db.bulkPutItems', { store: 'items', count: items.length });
}

/**
 * Items for a scope. `sourceId === ALL_SOURCE_ID` (or undefined) = the virtual
 * "All" source: every item, no source predicate.
 */
export async function getItems(sourceId: string | undefined, type?: ItemType): Promise<MusicItem[]> {
  const db = await getDB();
  const all = sourceId == null || sourceId === ALL_SOURCE_ID;
  let result: MusicItem[];
  if (all) {
    result = type
      ? await db.getAllFromIndex('items', 'by_type', type)
      : await db.getAll('items');
    txn('db.getAllItems', { type: type ?? 'all', count: result.length });
  } else if (type) {
    result = (await db.getAllFromIndex('items', 'by_source_type', [sourceId, type])) as MusicItem[];
    txn('db.getItemsBySource', { sourceId, type, count: result.length });
  } else {
    result = await db.getAllFromIndex('items', 'by_source', sourceId);
    txn('db.getItemsBySource', { sourceId, type: 'all', count: result.length });
  }
  return result;
}

export async function getAlbums(sourceId?: string): Promise<AlbumItem[]> {
  return (await getItems(sourceId, 'album')) as AlbumItem[];
}

export async function getSongs(sourceId?: string): Promise<SongItem[]> {
  return (await getItems(sourceId, 'song')) as SongItem[];
}

/** Songs of one album, ordered by trackNumber. */
export async function getAlbumSongs(albumId: string): Promise<SongItem[]> {
  const db = await getDB();
  const songs = (await db.getAllFromIndex('items', 'by_album', albumId)) as SongItem[];
  songs.sort((a, b) => (a.trackNumber ?? 0) - (b.trackNumber ?? 0));
  return songs;
}

export async function countItems(): Promise<{ albums: number; songs: number }> {
  const db = await getDB();
  const albums = await db.countFromIndex('items', 'by_type', 'album');
  const songs = await db.countFromIndex('items', 'by_type', 'song');
  return { albums, songs };
}

// ---- art ----
export async function getArt(key: string): Promise<ArtRecord | undefined> {
  const db = await getDB();
  return db.get('art', key);
}

export async function putArt(rec: ArtRecord): Promise<void> {
  const db = await getDB();
  await db.put('art', rec);
  txn('art.cache', { key: rec.key, status: rec.status });
}

export async function getAllArt(): Promise<ArtRecord[]> {
  const db = await getDB();
  return db.getAll('art');
}

// ---- meta ----
export async function getMeta<T = unknown>(key: string): Promise<T | undefined> {
  const db = await getDB();
  const rec = (await db.get('meta', key)) as MetaRecord | undefined;
  return rec?.value as T | undefined;
}

export async function setMeta(key: string, value: unknown): Promise<void> {
  const db = await getDB();
  await db.put('meta', { key, value });
}
