// The ONLY IndexedDB access point. Every data op emits a PDJ_API transcript line
// so Playwright can verify behavior (proof-of-verification).
import { getDB, type ArtRecord, type MetaRecord } from './db';
import type { DataSource, MusicItem, AlbumItem, SongItem, ItemType } from '../types/model';
import type { Pocket, Playlist, Setlist } from '../types/collections';
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

// ---- pockets (cross-source user collections) ----
export async function getPockets(): Promise<Pocket[]> {
  const db = await getDB();
  return db.getAll('pockets');
}

export async function getPocket(id: string): Promise<Pocket | undefined> {
  const db = await getDB();
  return db.get('pockets', id);
}

export async function putPocket(p: Pocket): Promise<void> {
  const db = await getDB();
  p.updatedAt = Date.now();
  await db.put('pockets', p);
  txn('pocket.update', {
    id: p.id,
    name: p.name,
    songs: p.songIds.length,
    albums: p.albumIds.length,
    children: p.childPocketIds.length,
  });
}

export async function deletePocket(id: string): Promise<void> {
  const db = await getDB();
  await db.delete('pockets', id);
  txn('pocket.delete', { id });
}

export async function bulkPutPockets(pockets: Pocket[]): Promise<void> {
  const db = await getDB();
  for (let i = 0; i < pockets.length; i += CHUNK) {
    const slice = pockets.slice(i, i + CHUNK);
    const tx = db.transaction('pockets', 'readwrite');
    const store = tx.objectStore('pockets');
    await Promise.all(slice.map((p) => store.put(p)));
    await tx.done;
  }
  txn('db.bulkPutItems', { store: 'pockets', count: pockets.length });
}

// ---- playlists (templates) ----
export async function getPlaylists(): Promise<Playlist[]> {
  const db = await getDB();
  return db.getAll('playlists');
}

export async function getPlaylist(id: string): Promise<Playlist | undefined> {
  const db = await getDB();
  return db.get('playlists', id);
}

export async function putPlaylist(p: Playlist): Promise<void> {
  const db = await getDB();
  p.updatedAt = Date.now();
  await db.put('playlists', p);
  txn('playlist.update', { id: p.id, name: p.name, sequences: p.sequences.length });
}

/** Delete a playlist AND cascade-delete every setlist generated from it. */
export async function deletePlaylist(id: string): Promise<void> {
  const db = await getDB();
  const tx = db.transaction(['playlists', 'setlists'], 'readwrite');
  await tx.objectStore('playlists').delete(id);
  let cursor = await tx.objectStore('setlists').index('by_playlist').openCursor(id);
  let n = 0;
  while (cursor) {
    await cursor.delete();
    n++;
    cursor = await cursor.continue();
  }
  await tx.done;
  txn('playlist.delete', { id, setlists: n });
}

export async function bulkPutPlaylists(playlists: Playlist[]): Promise<void> {
  const db = await getDB();
  for (let i = 0; i < playlists.length; i += CHUNK) {
    const slice = playlists.slice(i, i + CHUNK);
    const tx = db.transaction('playlists', 'readwrite');
    const store = tx.objectStore('playlists');
    await Promise.all(slice.map((p) => store.put(p)));
    await tx.done;
  }
  txn('db.bulkPutItems', { store: 'playlists', count: playlists.length });
}

// ---- setlists (frozen performance instances) ----
/** All setlists for one playlist, newest first. */
export async function getSetlists(playlistId: string): Promise<Setlist[]> {
  const db = await getDB();
  const rows = (await db.getAllFromIndex('setlists', 'by_playlist', playlistId)) as Setlist[];
  rows.sort((a, b) => b.generatedAt - a.generatedAt);
  return rows;
}

export async function getAllSetlists(): Promise<Setlist[]> {
  const db = await getDB();
  return db.getAll('setlists');
}

export async function getSetlist(id: string): Promise<Setlist | undefined> {
  const db = await getDB();
  return db.get('setlists', id);
}

export async function putSetlist(s: Setlist): Promise<void> {
  const db = await getDB();
  await db.put('setlists', s);
  txn('setlist.create', { id: s.id, playlistId: s.playlistId, tracks: s.tracks.length, totalMs: s.totalMs });
}

export async function deleteSetlist(id: string): Promise<void> {
  const db = await getDB();
  await db.delete('setlists', id);
  txn('setlist.delete', { id });
}

export async function bulkPutSetlists(setlists: Setlist[]): Promise<void> {
  const db = await getDB();
  for (let i = 0; i < setlists.length; i += CHUNK) {
    const slice = setlists.slice(i, i + CHUNK);
    const tx = db.transaction('setlists', 'readwrite');
    const store = tx.objectStore('setlists');
    await Promise.all(slice.map((s) => store.put(s)));
    await tx.done;
  }
  txn('db.bulkPutItems', { store: 'setlists', count: setlists.length });
}
