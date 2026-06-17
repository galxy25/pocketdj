// Export / import a SINGLE playlist as a self-contained .playlist.pocketdj.zip:
// the playlist template plus every catalog item it references (songs + their
// albums, album tracks), the pockets it references (DAG-expanded), the cover-art
// blobs, and its set-list history. Reuses the same zip shape as the full export
// so it's portable across devices and offline-durable.
import { zip, unzip, strToU8, strFromU8, type AsyncZippable } from 'fflate';
import type { MusicItem } from '../types/model';
import { isAlbum, isSong } from '../types/model';
import type { Playlist, Pocket, Setlist, PlaylistNode } from '../types/collections';
import { isPocketNode, isSequenceNode, isSongNode, isAlbumNode, newPlaylistId, newSetlistId } from '../types/collections';
import {
  getPlaylist,
  getItem,
  getPocket,
  getSetlists,
  getArt,
  putArt,
  putPlaylist,
  bulkPutItems,
  bulkPutPockets,
  bulkPutSetlists,
} from './repo';
import { txn } from '../lib/log';

interface PlaylistManifest {
  app: 'pocketdj';
  kind: 'playlist';
  schemaVersion: 1;
  exportedAt: string;
  playlistName: string;
  counts: { items: number; pockets: number; setlists: number; art: number };
}

function inflate(buf: Uint8Array): Promise<Record<string, Uint8Array>> {
  return new Promise((resolve, reject) => unzip(buf, (err, data) => (err ? reject(err) : resolve(data))));
}
function deflate(files: AsyncZippable): Promise<Uint8Array> {
  return new Promise((resolve, reject) => zip(files, { level: 6 }, (err, data) => (err ? reject(err) : resolve(data))));
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------
export async function buildPlaylistZip(
  playlistId: string,
): Promise<{ blob: Blob; manifest: PlaylistManifest } | null> {
  const playlist = await getPlaylist(playlistId);
  if (!playlist) return null;

  // Pockets referenced by the playlist, DAG-expanded (nested children included).
  const rootPocketIds = new Set<string>();
  const itemIds = new Set<string>();
  const walk = (nodes: PlaylistNode[]) => {
    for (const n of nodes) {
      if (isSongNode(n)) itemIds.add(n.songId);
      else if (isAlbumNode(n)) itemIds.add(n.albumId);
      else if (isPocketNode(n)) rootPocketIds.add(n.pocketId);
      else if (isSequenceNode(n)) walk(n.children);
    }
  };
  for (const seq of playlist.sequences) walk(seq.children);

  const pockets: Pocket[] = [];
  const seenP = new Set<string>();
  const queue = [...rootPocketIds];
  while (queue.length) {
    const pid = queue.pop() as string;
    if (seenP.has(pid)) continue;
    seenP.add(pid);
    const p = await getPocket(pid);
    if (!p) continue;
    pockets.push(p);
    p.songIds.forEach((x) => itemIds.add(x));
    p.albumIds.forEach((x) => itemIds.add(x));
    p.childPocketIds.forEach((c) => queue.push(c));
  }

  // Resolve items, then expand: albums → their tracks, songs → their album (cover art).
  const items = new Map<string, MusicItem>();
  for (const it of await Promise.all([...itemIds].map((x) => getItem(x)))) if (it) items.set(it.id, it);
  for (let pass = 0; pass < 2; pass++) {
    const need = new Set<string>();
    for (const it of items.values()) {
      if (isAlbum(it)) it.trackIds.forEach((t) => !items.has(t) && need.add(t));
      else if (isSong(it) && it.albumId && !items.has(it.albumId)) need.add(it.albumId);
    }
    if (need.size === 0) break;
    for (const it of await Promise.all([...need].map((x) => getItem(x)))) if (it) items.set(it.id, it);
  }
  const itemList = [...items.values()];

  // Cover-art blobs for referenced albums.
  const artKeys = new Set<string>();
  for (const it of itemList) if (isAlbum(it) && it.coverArtKey) artKeys.add(it.coverArtKey);
  const arts = (await Promise.all([...artKeys].map((k) => getArt(k)))).filter((a) => a && a.thumb) as NonNullable<
    Awaited<ReturnType<typeof getArt>>
  >[];

  const setlists = await getSetlists(playlistId);

  const files: AsyncZippable = {};
  files['playlist.json'] = [strToU8(JSON.stringify(playlist)), { level: 6 }];
  files['items.json'] = [strToU8(JSON.stringify(itemList)), { level: 6 }];
  files['pockets.json'] = [strToU8(JSON.stringify(pockets)), { level: 6 }];
  files['setlists.json'] = [strToU8(JSON.stringify(setlists)), { level: 6 }];
  let artCount = 0;
  for (const a of arts) {
    files[`art/${a.key}.webp`] = [new Uint8Array(await a.thumb!.arrayBuffer()), { level: 0 }];
    artCount++;
  }
  const manifest: PlaylistManifest = {
    app: 'pocketdj',
    kind: 'playlist',
    schemaVersion: 1,
    exportedAt: new Date().toISOString(),
    playlistName: playlist.name,
    counts: { items: itemList.length, pockets: pockets.length, setlists: setlists.length, art: artCount },
  };
  files['manifest.json'] = strToU8(JSON.stringify(manifest));

  const bytes = await deflate(files);
  const blob = new Blob([bytes as BlobPart], { type: 'application/zip' });
  txn('export.playlist', { playlistId, ...manifest.counts, bytes: blob.size });
  return { blob, manifest };
}

export async function downloadPlaylistZip(playlistId: string): Promise<PlaylistManifest | null> {
  const built = await buildPlaylistZip(playlistId);
  if (!built) return null;
  const base = built.manifest.playlistName.replace(/[\\/:*?"<>|]+/g, '').trim() || 'playlist';
  const url = URL.createObjectURL(built.blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${base}.playlist.pocketdj.zip`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return built.manifest;
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------
export interface ImportPlaylistResult {
  playlistId: string;
  name: string;
  items: number;
  pockets: number;
  setlists: number;
  art: number;
}

/**
 * Import a single-playlist zip. The catalog items + cover art are upserted
 * (shared catalog). Referenced pockets are added only if absent (never clobber an
 * existing pocket of the same id). The playlist is imported under a FRESH id (so
 * it can't overwrite an existing one), and its set lists are re-pointed to it.
 */
export async function importPlaylistZip(buf: ArrayBuffer): Promise<ImportPlaylistResult> {
  const files = await inflate(new Uint8Array(buf));
  const manRaw = files['manifest.json'];
  const plRaw = files['playlist.json'];
  if (!plRaw) throw new Error('Not a PocketDJ playlist export (missing playlist.json)');
  if (manRaw) {
    const man = JSON.parse(strFromU8(manRaw)) as Partial<PlaylistManifest>;
    if (man.app !== 'pocketdj' || man.kind !== 'playlist') throw new Error('Not a PocketDJ playlist export');
  }

  const src = JSON.parse(strFromU8(plRaw)) as Playlist;
  const items = JSON.parse(strFromU8(files['items.json'] ?? strToU8('[]'))) as MusicItem[];
  const pockets = JSON.parse(strFromU8(files['pockets.json'] ?? strToU8('[]'))) as Pocket[];
  const setlists = JSON.parse(strFromU8(files['setlists.json'] ?? strToU8('[]'))) as Setlist[];

  if (items.length) await bulkPutItems(items);

  // Pockets: only add ones that don't already exist (don't overwrite the user's).
  const freshPockets: Pocket[] = [];
  for (const p of pockets) if (!(await getPocket(p.id))) freshPockets.push(p);
  if (freshPockets.length) await bulkPutPockets(freshPockets);

  let art = 0;
  for (const [path, bytes] of Object.entries(files)) {
    const m = path.match(/^art\/(.+)\.webp$/);
    if (m) {
      await putArt({ key: m[1], thumb: new Blob([bytes as BlobPart], { type: 'image/webp' }), status: 'ok' });
      art++;
    }
  }

  // Fresh playlist id (never clobber); name tagged so duplicates are obvious.
  const now = Date.now();
  const playlist: Playlist = { ...src, id: newPlaylistId(), name: `${src.name} (imported)`, createdAt: now, updatedAt: now };
  await putPlaylist(playlist);

  // Re-point set-list history to the new playlist with fresh ids.
  const reSetlists = setlists.map((s) => ({ ...s, id: newSetlistId(), playlistId: playlist.id }));
  if (reSetlists.length) await bulkPutSetlists(reSetlists);

  txn('import.playlist', { playlistId: playlist.id, items: items.length, pockets: freshPockets.length, setlists: reSetlists.length, art });
  return {
    playlistId: playlist.id,
    name: playlist.name,
    items: items.length,
    pockets: freshPockets.length,
    setlists: reSetlists.length,
    art,
  };
}
