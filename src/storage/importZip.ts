// Import a .pocketdj.zip exported by exportZip.ts. Rehydrates sources + items +
// art blobs with ZERO network (art is bundled), so a fresh device is immediately
// offline-capable. Also sniffs a raw index.json (indexer/mock output) so the same
// file input handles both.
import { unzip, strFromU8 } from 'fflate';
import type { DataSource, MusicItem } from '../types/model';
import type { Pocket, Playlist, Setlist } from '../types/collections';
import { putSource, bulkPutItems, putArt, bulkPutPockets, bulkPutPlaylists, bulkPutSetlists } from './repo';
import { importIndexJson, hydrateArt } from './importIndex';
import type { IndexJson } from '../types/index-json';
import { txn } from '../lib/log';

interface Unzipped {
  [path: string]: Uint8Array;
}

function inflate(buf: Uint8Array): Promise<Unzipped> {
  return new Promise((resolve, reject) => {
    unzip(buf, (err, data) => (err ? reject(err) : resolve(data)));
  });
}

export interface ImportZipResult {
  sources: number;
  items: number;
  art: number;
  pockets: number;
  playlists: number;
  setlists: number;
}

/** Parse an optional collections JSON entry; tolerate absence (v1 zips) + malformed. */
function readJsonArray<T>(files: Unzipped, path: string): T[] {
  const raw = files[path];
  if (!raw) return [];
  try {
    const parsed = JSON.parse(strFromU8(raw));
    return Array.isArray(parsed) ? (parsed as T[]) : [];
  } catch {
    return [];
  }
}

/** Import a PocketDJ export zip (sources + items + art). */
export async function importExportZip(buf: ArrayBuffer): Promise<ImportZipResult> {
  const files = await inflate(new Uint8Array(buf));

  const sourcesRaw = files['sources.json'];
  const itemsRaw = files['items.json'];
  if (!sourcesRaw || !itemsRaw) throw new Error('Not a PocketDJ export (missing sources.json/items.json)');

  const sources = JSON.parse(strFromU8(sourcesRaw)) as DataSource[];
  const items = JSON.parse(strFromU8(itemsRaw)) as MusicItem[];

  for (const s of sources) await putSource(s);
  await bulkPutItems(items);

  // Cross-source collections (absent in v1 zips → empty arrays, no-op).
  const pockets = readJsonArray<Pocket>(files, 'pockets.json');
  const playlists = readJsonArray<Playlist>(files, 'playlists.json');
  const setlists = readJsonArray<Setlist>(files, 'setlists.json');
  if (pockets.length) await bulkPutPockets(pockets);
  if (playlists.length) await bulkPutPlaylists(playlists);
  if (setlists.length) await bulkPutSetlists(setlists);

  let art = 0;
  for (const [path, bytes] of Object.entries(files)) {
    const m = path.match(/^art\/(.+)\.webp$/);
    if (m) {
      const key = m[1];
      await putArt({ key, thumb: new Blob([bytes as BlobPart], { type: 'image/webp' }), status: 'ok' });
      art++;
    }
  }

  txn('import.zip', {
    sources: sources.length,
    items: items.length,
    art,
    pockets: pockets.length,
    playlists: playlists.length,
    setlists: setlists.length,
  });
  return {
    sources: sources.length,
    items: items.length,
    art,
    pockets: pockets.length,
    playlists: playlists.length,
    setlists: setlists.length,
  };
}

/**
 * Smart import: accept either a .pocketdj.zip OR a raw index.json. Returns a
 * human summary. For a raw index it also hydrates art (downloads/generates).
 */
export async function importFile(
  file: File,
  onProgress?: (done: number, total: number) => void,
): Promise<{ kind: 'zip' | 'index'; summary: string }> {
  const buf = await file.arrayBuffer();
  const isZip = file.name.endsWith('.zip') || isZipMagic(new Uint8Array(buf));
  if (isZip) {
    const r = await importExportZip(buf);
    return { kind: 'zip', summary: `${r.items} items, ${r.art} covers (offline)` };
  }
  const index = JSON.parse(new TextDecoder().decode(buf)) as IndexJson;
  const { source, counts } = await importIndexJson(index);
  await hydrateArt(source.id, onProgress);
  return { kind: 'index', summary: `${counts.albums} albums, ${counts.songs} songs` };
}

function isZipMagic(b: Uint8Array): boolean {
  return b.length > 3 && b[0] === 0x50 && b[1] === 0x4b && (b[2] === 0x03 || b[2] === 0x05);
}
