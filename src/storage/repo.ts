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
  // Collect the item keys FIRST (one read), then delete in chunked transactions whose
  // ops are all issued synchronously. A `cursor.delete()` loop that awaits each step
  // makes iOS Safari auto-deactivate the transaction mid-loop, throwing "Attempt to
  // delete range from database without an in-progress transaction" — and a digital
  // source (Apple Music) can be ~90k items, so it trips every time. This pattern is
  // WebKit-safe at any scale.
  await db.delete('sources', sourceId);
  const keys = await db.getAllKeysFromIndex('items', 'by_source', sourceId);
  for (let i = 0; i < keys.length; i += CHUNK) {
    const slice = keys.slice(i, i + CHUNK);
    const tx = db.transaction('items', 'readwrite');
    const store = tx.objectStore('items');
    await Promise.all(slice.map((k) => store.delete(k)));
    await tx.done;
  }
  txn('db.deleteSource', { id: sourceId, items: keys.length });
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
 * Items for a scope. The scope may be:
 *   - undefined or ALL_SOURCE_ID  → the virtual "All" source (every item)
 *   - a single sourceId (string)  → that one source
 *   - an array of sourceIds       → the UNION of those sources ([] = none → no items)
 * The array form backs multi-source selection (show a chosen subset of sources).
 */
export async function getItems(
  scope: string | string[] | undefined,
  type?: ItemType,
): Promise<MusicItem[]> {
  const db = await getDB();

  // Multi-source subset (or explicit "none").
  if (Array.isArray(scope)) {
    const ids = scope.filter((id) => id && id !== ALL_SOURCE_ID);
    if (ids.length === 0) {
      txn('db.getItemsBySource', { sourceId: 'none', type: type ?? 'all', count: 0 });
      return [];
    }
    const batches = await Promise.all(
      ids.map((id) =>
        type
          ? (db.getAllFromIndex('items', 'by_source_type', [id, type]) as Promise<MusicItem[]>)
          : (db.getAllFromIndex('items', 'by_source', id) as Promise<MusicItem[]>),
      ),
    );
    const result = batches.flat();
    txn('db.getItemsBySource', { sourceId: ids.join(','), type: type ?? 'all', count: result.length });
    return result;
  }

  const all = scope == null || scope === ALL_SOURCE_ID;
  let result: MusicItem[];
  if (all) {
    result = type
      ? await db.getAllFromIndex('items', 'by_type', type)
      : await db.getAll('items');
    txn('db.getAllItems', { type: type ?? 'all', count: result.length });
  } else if (type) {
    result = (await db.getAllFromIndex('items', 'by_source_type', [scope, type])) as MusicItem[];
    txn('db.getItemsBySource', { sourceId: scope, type, count: result.length });
  } else {
    result = await db.getAllFromIndex('items', 'by_source', scope);
    txn('db.getItemsBySource', { sourceId: scope, type: 'all', count: result.length });
  }
  return result;
}

export async function getAlbums(scope?: string | string[]): Promise<AlbumItem[]> {
  return (await getItems(scope, 'album')) as AlbumItem[];
}

export async function getSongs(scope?: string | string[]): Promise<SongItem[]> {
  return (await getItems(scope, 'song')) as SongItem[];
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
  // Same WebKit-safe pattern as deleteSource: read the cascade keys, then delete with
  // synchronously-issued ops (no awaiting cursor loop, which iOS Safari aborts).
  await db.delete('playlists', id);
  const setlistKeys = await db.getAllKeysFromIndex('setlists', 'by_playlist', id);
  if (setlistKeys.length) {
    const tx = db.transaction('setlists', 'readwrite');
    const store = tx.objectStore('setlists');
    await Promise.all(setlistKeys.map((k) => store.delete(k)));
    await tx.done;
  }
  txn('playlist.delete', { id, setlists: setlistKeys.length });
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
