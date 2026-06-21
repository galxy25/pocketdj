// Export all PocketDJ state to a .pocketdj.zip (sources + items + cover-art
// blobs). This is the portability story: move the zip to another device, import,
// and the star map works fully offline (art travels with the data).
import { zip, strToU8, type AsyncZippable } from 'fflate';
import { getSources, getItems, getAllArt, getPockets, getPlaylists, getAllSetlists } from './repo';
import { buildEditsJson, getEditsDocument } from './edits';
import { txn } from '../lib/log';

export interface ExportManifest {
  app: 'pocketdj';
  /** Disambiguates the zip family for the native router (backup | playlist | pocket). */
  kind: 'backup';
  // v2 added pockets/playlists/setlists (additive — v1 zips still import).
  schemaVersion: 1 | 2;
  /** True: the catalog (items.json + art/) travels too, so it imports on an empty device. */
  portable: boolean;
  exportedAt: string;
  counts: { sources: number; items: number; art: number; pockets: number; playlists: number; setlists: number; edits: number };
}

/** Build the export zip as a Blob (no DOM side effects — testable). */
export async function buildExportZip(): Promise<{ blob: Blob; manifest: ExportManifest }> {
  const [sources, items, art, pockets, playlists, setlists] = await Promise.all([
    getSources(),
    getItems(undefined),
    getAllArt(),
    getPockets(),
    getPlaylists(),
    getAllSetlists(),
  ]);

  // User metadata edits — the same `edits.json` the native apps write, so a PWA
  // backup carries its overrides forward (and the merge tool / native can read them).
  const editsDoc = await getEditsDocument();
  const editsCount = Object.keys(editsDoc.albums).length + Object.keys(editsDoc.songs).length;

  const files: AsyncZippable = {};
  files['sources.json'] = [strToU8(JSON.stringify(sources)), { level: 6 }];
  files['items.json'] = [strToU8(JSON.stringify(items)), { level: 6 }];
  files['pockets.json'] = [strToU8(JSON.stringify(pockets)), { level: 6 }];
  files['playlists.json'] = [strToU8(JSON.stringify(playlists)), { level: 6 }];
  files['setlists.json'] = [strToU8(JSON.stringify(setlists)), { level: 6 }];
  files['edits.json'] = [strToU8(await buildEditsJson()), { level: 6 }];

  let artCount = 0;
  for (const a of art) {
    if (a.thumb) {
      const buf = new Uint8Array(await a.thumb.arrayBuffer());
      files[`art/${a.key}.webp`] = [buf, { level: 0 }]; // already compressed
      artCount++;
    }
  }

  const manifest: ExportManifest = {
    app: 'pocketdj',
    kind: 'backup',
    schemaVersion: 2,
    // The PWA export bundles the catalog → portable (imports on an empty device).
    // The native backup omits it → non-portable (see importZip.ts).
    portable: true,
    exportedAt: new Date().toISOString(),
    counts: {
      sources: sources.length,
      items: items.length,
      art: artCount,
      pockets: pockets.length,
      playlists: playlists.length,
      setlists: setlists.length,
      edits: editsCount,
    },
  };
  files['manifest.json'] = strToU8(JSON.stringify(manifest));

  const bytes = await new Promise<Uint8Array>((resolve, reject) => {
    zip(files, { level: 6 }, (err, data) => (err ? reject(err) : resolve(data)));
  });

  const blob = new Blob([bytes as BlobPart], { type: 'application/zip' });
  txn('export.zip', {
    bytes: blob.size,
    sources: sources.length,
    items: items.length,
    art: artCount,
    pockets: pockets.length,
    playlists: playlists.length,
    setlists: setlists.length,
    edits: editsCount,
  });
  return { blob, manifest };
}

/** Build and trigger a browser download. */
export async function downloadExportZip(filename = 'pocketdj-export.zip'): Promise<ExportManifest> {
  const { blob, manifest } = await buildExportZip();
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return manifest;
}
