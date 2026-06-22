// Import a .pocketdj.zip exported by exportZip.ts. Rehydrates sources + items +
// art blobs with ZERO network (art is bundled), so a fresh device is immediately
// offline-capable. Also sniffs a raw index.json (indexer/mock output) so the same
// file input handles both.
//
// Interoperates with the NATIVE full backup (apple BackupZip.swift). Native writes
// the same envelope but OMITS the catalog (`items.json` / `art/`) because both ends
// auto-seed the same read-only index — collections reference songs/albums by id and
// resolve at display. So a native backup is a NON-PORTABLE backup: collections +
// `edits.json` (user metadata overrides), no catalog. This importer accepts both:
// a portable PWA export (catalog bundled) AND a native non-portable backup.
import { unzip, strFromU8 } from 'fflate';
import type { DataSource, MusicItem } from '../types/model';
import type { Pocket, Playlist, Setlist } from '../types/collections';
import { putSource, bulkPutItems, putArt, bulkPutPockets, bulkPutPlaylists, bulkPutSetlists } from './repo';
import { importIndexJson, hydrateArt } from './importIndex';
import { mergeEditsDocument, parseEditsDocument } from './edits';
import { importPocketZip } from './pocketTransfer';
import { importPlaylistZip } from './playlistTransfer';
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
  /** Number of metadata edits merged from `edits.json` (album + song overrides). */
  edits: number;
  /** True when no catalog travelled (native-style backup): collections only, catalog skipped. */
  portable: boolean;
}

/** Heuristic: a PWA DataSource always has `id` + `type`; a native SourceConfig does not. */
function isPwaDataSource(s: unknown): s is DataSource {
  return !!s && typeof s === 'object' && typeof (s as DataSource).id === 'string' && typeof (s as DataSource).type === 'string';
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

/**
 * Import a PocketDJ full backup zip. Accepts BOTH shapes:
 *   • PORTABLE (PWA export): sources.json (DataSource[]) + items.json + art/ + collections.
 *   • NON-PORTABLE (native backup): collections + edits.json, NO items.json/art and a
 *     native-shaped sources.json ({name,urlString,enabled}[]). The catalog is the same
 *     auto-seeded index on both ends, so collections resolve by id; we import the
 *     collections + edits and skip the catalog.
 *
 * A zip is a valid backup if it self-identifies via a `pocketdj` manifest, OR carries
 * any collections/sources/edits entry — items.json is no longer required.
 */
export async function importExportZip(buf: ArrayBuffer): Promise<ImportZipResult> {
  const files = await inflate(new Uint8Array(buf));

  // Manifest, if present, must self-identify as PocketDJ (rejects arbitrary zips).
  const manRaw = files['manifest.json'];
  let manifestOk = false;
  if (manRaw) {
    try {
      const man = JSON.parse(strFromU8(manRaw)) as { app?: string };
      if (man.app && man.app !== 'pocketdj') throw new Error('Not a PocketDJ export');
      manifestOk = man.app === 'pocketdj';
    } catch {
      /* malformed manifest → fall through to entry-presence check */
    }
  }

  const sourcesRaw = files['sources.json'];
  const itemsRaw = files['items.json'];
  const hasCollections = !!(files['pockets.json'] || files['playlists.json'] || files['setlists.json']);
  const hasEdits = !!files['edits.json'];

  // Without a self-identifying manifest, require at least one recognizable payload.
  if (!manifestOk && !sourcesRaw && !itemsRaw && !hasCollections && !hasEdits) {
    throw new Error('Not a PocketDJ export (no manifest/sources/items/collections/edits)');
  }

  // Sources: adopt only PWA DataSource[] entries. A native sources.json
  // ({name,urlString,enabled}[]) is tolerated but NOT adopted (no clean mapping to a
  // PWA DataSource, whose items come from an indexed catalog) — it's ignored, not fatal.
  let sourceCount = 0;
  if (sourcesRaw) {
    try {
      const parsed = JSON.parse(strFromU8(sourcesRaw)) as unknown;
      const arr = Array.isArray(parsed) ? parsed : [];
      const pwa = arr.filter(isPwaDataSource);
      for (const s of pwa) await putSource(s);
      sourceCount = pwa.length;
      const native = arr.length - pwa.length;
      if (native > 0) txn('import.zip.nativeSources', { skipped: native });
    } catch {
      /* malformed sources.json → skip */
    }
  }

  // Catalog (portable only). Absent in a native backup → skip, mark non-portable.
  let itemCount = 0;
  if (itemsRaw) {
    try {
      const items = JSON.parse(strFromU8(itemsRaw)) as MusicItem[];
      if (Array.isArray(items) && items.length) await bulkPutItems(items);
      itemCount = Array.isArray(items) ? items.length : 0;
    } catch {
      /* malformed items.json → skip catalog */
    }
  }

  // Cross-source collections (absent in v1 zips → empty arrays, no-op).
  const pockets = readJsonArray<Pocket>(files, 'pockets.json');
  const playlists = readJsonArray<Playlist>(files, 'playlists.json');
  const setlists = readJsonArray<Setlist>(files, 'setlists.json');
  if (pockets.length) await bulkPutPockets(pockets);
  if (playlists.length) await bulkPutPlaylists(playlists);
  if (setlists.length) await bulkPutSetlists(setlists);

  // Metadata edits (native-only entry; merge into the PWA edits store, imported wins).
  let edits = 0;
  if (files['edits.json']) {
    const doc = parseEditsDocument(strFromU8(files['edits.json']));
    edits = Object.keys(doc.albums).length + Object.keys(doc.songs).length;
    if (edits) await mergeEditsDocument(doc);
  }

  // Art blobs (portable only).
  let art = 0;
  for (const [path, bytes] of Object.entries(files)) {
    const m = path.match(/^art\/(.+)\.webp$/);
    if (m) {
      const key = m[1];
      await putArt({ key, thumb: new Blob([bytes as BlobPart], { type: 'image/webp' }), status: 'ok' });
      art++;
    }
  }

  const portable = itemCount > 0 || art > 0;
  txn('import.zip', {
    sources: sourceCount,
    items: itemCount,
    art,
    pockets: pockets.length,
    playlists: playlists.length,
    setlists: setlists.length,
    edits,
    portable,
  });
  return {
    sources: sourceCount,
    items: itemCount,
    art,
    pockets: pockets.length,
    playlists: playlists.length,
    setlists: setlists.length,
    edits,
    portable,
  };
}

/** Read a zip's manifest `kind` (if any) without fully importing — routes import. */
function manifestKind(files: Unzipped): string | undefined {
  const raw = files['manifest.json'];
  if (!raw) return undefined;
  try {
    const man = JSON.parse(strFromU8(raw)) as { app?: string; kind?: string };
    return man.app === 'pocketdj' ? man.kind : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Smart import: accept a .pocketdj.zip (full backup, single playlist, OR single
 * pocket) OR a raw index.json. The manifest `kind` disambiguates the three zip
 * flavors; entry presence is the fallback (pocket.json ⇒ pocket, playlist.json ⇒
 * playlist, else backup). Returns a human summary. For a raw index it also hydrates
 * art (downloads/generates).
 */
export async function importFile(
  file: File,
  onProgress?: (done: number, total: number) => void,
): Promise<{ kind: 'zip' | 'index' | 'playlist' | 'pocket'; summary: string }> {
  const buf = await file.arrayBuffer();
  const isZip = file.name.endsWith('.zip') || isZipMagic(new Uint8Array(buf));
  if (isZip) {
    const files = await inflate(new Uint8Array(buf));
    const kind = manifestKind(files);

    // Pocket transfer (manifest kind OR a bare pocket.json with no backup manifest).
    if (kind === 'pocket' || (!kind && files['pocket.json'] && !files['playlist.json'])) {
      const r = await importPocketZip(buf);
      return { kind: 'pocket', summary: `Pocket "${r.name}" (${r.pockets} pockets)` };
    }
    // Playlist transfer.
    if (kind === 'playlist' || (!kind && files['playlist.json'])) {
      const r = await importPlaylistZip(buf);
      return { kind: 'playlist', summary: `Playlist "${r.name}" (${r.items} items, ${r.pockets} pockets)` };
    }
    // Full backup (portable PWA export OR non-portable native backup).
    const r = await importExportZip(buf);
    const summary = r.portable
      ? `${r.items} items, ${r.art} covers (offline)`
      : `${r.pockets} pockets, ${r.playlists} playlists, ${r.setlists} set lists, ${r.edits} edits (catalog skipped)`;
    return { kind: 'zip', summary };
  }
  const index = JSON.parse(new TextDecoder().decode(buf)) as IndexJson;
  const { source, counts } = await importIndexJson(index);
  await hydrateArt(source.id, onProgress, { placeholders: source.type !== 'digital' });
  return { kind: 'index', summary: `${counts.albums} albums, ${counts.songs} songs` };
}

function isZipMagic(b: Uint8Array): boolean {
  return b.length > 3 && b[0] === 0x50 && b[1] === 0x4b && (b[2] === 0x03 || b[2] === 0x05);
}
