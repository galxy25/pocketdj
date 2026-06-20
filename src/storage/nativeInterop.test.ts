// Proves the PWA reads the native apps' import/export formats and that the PWA's
// own exports still round-trip. Native-shaped zips are constructed in-memory with
// fflate (the same lib the importers use). The repo (IndexedDB) is mocked with
// in-memory stores so these run in the pure `node` vitest environment.
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { zip, strToU8 } from 'fflate';
import type { MusicItem } from '../types/model';
import type { Pocket, Playlist, Setlist } from '../types/collections';

// ---------------------------------------------------------------------------
// In-memory repo mock (captures everything the importers write).
// ---------------------------------------------------------------------------
const stores = {
  sources: [] as unknown[],
  items: [] as MusicItem[],
  pockets: [] as Pocket[],
  playlists: [] as Playlist[],
  setlists: [] as Setlist[],
  art: [] as { key: string }[],
  meta: new Map<string, unknown>(),
};

function resetStores() {
  stores.sources = [];
  stores.items = [];
  stores.pockets = [];
  stores.playlists = [];
  stores.setlists = [];
  stores.art = [];
  stores.meta = new Map();
}

vi.mock('./repo', () => ({
  putSource: vi.fn(async (s: unknown) => void stores.sources.push(s)),
  bulkPutItems: vi.fn(async (xs: MusicItem[]) => void stores.items.push(...xs)),
  putArt: vi.fn(async (a: { key: string }) => void stores.art.push(a)),
  bulkPutPockets: vi.fn(async (xs: Pocket[]) => void stores.pockets.push(...xs)),
  bulkPutPlaylists: vi.fn(async (xs: Playlist[]) => void stores.playlists.push(...xs)),
  bulkPutSetlists: vi.fn(async (xs: Setlist[]) => void stores.setlists.push(...xs)),
  getPocket: vi.fn(async (id: string) => stores.pockets.find((p) => p.id === id)),
  getMeta: vi.fn(async (k: string) => stores.meta.get(k)),
  setMeta: vi.fn(async (k: string, v: unknown) => void stores.meta.set(k, v)),
  // Used by exportZip (not exercised here beyond round-trip).
  getSources: vi.fn(async () => stores.sources),
  getItems: vi.fn(async () => stores.items),
  getAllArt: vi.fn(async () => stores.art),
  getPockets: vi.fn(async () => stores.pockets),
  getPlaylists: vi.fn(async () => stores.playlists),
  getAllSetlists: vi.fn(async () => stores.setlists),
  getPlaylist: vi.fn(async (id: string) => stores.playlists.find((p) => p.id === id)),
  getItem: vi.fn(async (id: string) => stores.items.find((i) => i.id === id)),
  getArt: vi.fn(async () => undefined),
  getSetlists: vi.fn(async () => []),
  putPlaylist: vi.fn(async (p: Playlist) => void stores.playlists.push(p)),
}));

// Imported AFTER the mock is registered.
const { importExportZip, importFile } = await import('./importZip');
const { buildExportZip } = await import('./exportZip');
const { getEditsDocument } = await import('./edits');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function makeZip(files: Record<string, string>): Promise<ArrayBuffer> {
  const z: Record<string, Uint8Array> = {};
  for (const [k, v] of Object.entries(files)) z[k] = strToU8(v);
  return new Promise((resolve, reject) =>
    zip(z, { level: 6 }, (err, data) =>
      err ? reject(err) : resolve(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)),
    ),
  );
}

function fileFrom(buf: ArrayBuffer, name: string): File {
  // Minimal File polyfill (node's File may lack arrayBuffer in some versions).
  return {
    name,
    arrayBuffer: async () => buf,
  } as unknown as File;
}

const pocket = (over: Partial<Pocket>): Pocket => ({
  id: 'pkt_1',
  name: 'Warmup',
  kind: 'harmonic',
  songIds: ['sng_a'],
  albumIds: [],
  childPocketIds: [],
  createdAt: 1,
  updatedAt: 1,
  ...over,
});

beforeEach(resetStores);

// ===========================================================================
// 1. Native full backup (sources.json + collections + edits.json, NO items.json)
// ===========================================================================
describe('native full backup import (non-portable)', () => {
  it('imports collections + edits, skips the catalog, and adopts no native sources', async () => {
    const nativeSources = JSON.stringify([{ name: 'My Vinyl', urlString: 'https://x/index.json', enabled: true }]);
    const pockets = JSON.stringify([pocket({})]);
    const playlists = JSON.stringify([
      { id: 'pls_1', name: 'Party', sequences: [{ nodeId: 'n', kind: 'sequence', name: 'Default', children: [] }], createdAt: 1, updatedAt: 1 },
    ]);
    const setlists = JSON.stringify([]);
    const edits = JSON.stringify({
      schemaVersion: 2,
      albums: { alb_a: { name: 'Renamed Album', year: 1999 } },
      songs: { sng_a: { bpm: 128, explicit: true } },
    });
    const manifest = JSON.stringify({
      app: 'pocketdj',
      kind: 'backup',
      schemaVersion: 2,
      portable: false,
      exportedAt: '2026-01-01T00:00:00Z',
      counts: { sources: 1, items: 0, art: 0, pockets: 1, playlists: 1, setlists: 0 },
    });

    const buf = await makeZip({
      'manifest.json': manifest,
      'sources.json': nativeSources,
      'pockets.json': pockets,
      'playlists.json': playlists,
      'setlists.json': setlists,
      'edits.json': edits,
    });

    const r = await importExportZip(buf);

    // Collections landed.
    expect(stores.pockets).toHaveLength(1);
    expect(stores.playlists).toHaveLength(1);
    expect(r.pockets).toBe(1);
    expect(r.playlists).toBe(1);

    // Catalog skipped, non-portable.
    expect(stores.items).toHaveLength(0);
    expect(stores.art).toHaveLength(0);
    expect(r.items).toBe(0);
    expect(r.art).toBe(0);
    expect(r.portable).toBe(false);

    // Native sources tolerated but NOT adopted (no clean DataSource mapping).
    expect(stores.sources).toHaveLength(0);
    expect(r.sources).toBe(0);

    // Edits merged (2 overrides: 1 album + 1 song).
    expect(r.edits).toBe(2);
    const doc = await getEditsDocument();
    expect(doc.albums['alb_a']).toEqual({ name: 'Renamed Album', year: 1999 });
    expect(doc.songs['sng_a']).toEqual({ bpm: 128, explicit: true });
  });

  it('importFile routes a kind:"backup" zip and summarizes the non-portable case', async () => {
    const buf = await makeZip({
      'manifest.json': JSON.stringify({ app: 'pocketdj', kind: 'backup', schemaVersion: 2, portable: false, exportedAt: 'x', counts: {} }),
      'pockets.json': JSON.stringify([pocket({})]),
      'edits.json': JSON.stringify({ schemaVersion: 2, albums: {}, songs: { sng_a: { bpm: 90 } } }),
    });
    const r = await importFile(fileFrom(buf, 'backup.pocketdj.zip'));
    expect(r.kind).toBe('zip');
    expect(r.summary).toContain('catalog skipped');
    expect(stores.pockets).toHaveLength(1);
  });
});

// ===========================================================================
// 2. Native .pocket.pocketdj.zip
// ===========================================================================
describe('native pocket import', () => {
  it('imports a pocket + DAG-expanded children under fresh ids (refs remapped)', async () => {
    const root = pocket({ id: 'pkt_root', name: 'Sunset', childPocketIds: ['pkt_child'] });
    const child = pocket({ id: 'pkt_child', name: 'Deep', songIds: ['sng_b'], childPocketIds: [] });
    const buf = await makeZip({
      'manifest.json': JSON.stringify({
        app: 'pocketdj',
        kind: 'pocket',
        schemaVersion: 1,
        portable: false,
        exportedAt: 'x',
        pocketName: 'Sunset',
        counts: { pockets: 2, art: 0 },
      }),
      'pocket.json': JSON.stringify(root),
      'pockets.json': JSON.stringify([child]),
    });

    const r = await importFile(fileFrom(buf, 'Sunset.pocket.pocketdj.zip'));
    expect(r.kind).toBe('pocket');
    expect(stores.pockets).toHaveLength(2);

    const newRoot = stores.pockets.find((p) => p.name === 'Sunset')!;
    const newChild = stores.pockets.find((p) => p.name === 'Deep')!;
    // Fresh ids (never clobber an existing pkt_root/pkt_child).
    expect(newRoot.id).not.toBe('pkt_root');
    expect(newChild.id).not.toBe('pkt_child');
    // Root's child ref remapped to the child's new id.
    expect(newRoot.childPocketIds).toEqual([newChild.id]);
    // Catalog membership preserved (resolved by id at display).
    expect(newChild.songIds).toEqual(['sng_b']);
  });
});

// ===========================================================================
// 3. The PWA's own portable full export still round-trips
// ===========================================================================
describe('PWA portable export round-trip', () => {
  it('exports catalog + collections + edits and re-imports them losslessly', async () => {
    // Seed the mocked stores.
    stores.items = [
      { id: 'sng_a', sourceId: 's1', type: 'song', artist: 'A', name: 'Track', sentimentKeywords: [], explicit: false, bpm: null, key: null, createdAt: 1, updatedAt: 1 } as MusicItem,
    ];
    stores.pockets = [pocket({})];
    stores.playlists = [];
    stores.setlists = [];
    stores.sources = [{ id: 's1', type: 'analog', name: 'Vinyl', createdAt: 1, updatedAt: 1, itemCount: { albums: 0, songs: 1 } }];
    // A pre-existing edit so the export carries edits.json with content.
    stores.meta.set('edits', { schemaVersion: 2, albums: {}, songs: { sng_a: { year: 2020 } } });

    const { blob, manifest } = await buildExportZip();
    expect(manifest.kind).toBe('backup');
    expect(manifest.portable).toBe(true);
    expect(manifest.counts.edits).toBe(1);

    // Wipe & re-import.
    const buf = await blob.arrayBuffer();
    resetStores();
    const r = await importExportZip(buf);

    expect(r.portable).toBe(true);
    expect(r.items).toBe(1);
    expect(r.sources).toBe(1); // PWA DataSource[] adopted
    expect(r.pockets).toBe(1);
    expect(r.edits).toBe(1);
    expect(stores.items).toHaveLength(1);
    const doc = await getEditsDocument();
    expect(doc.songs['sng_a']).toEqual({ year: 2020 });
  });
});

// ===========================================================================
// 4. Guards
// ===========================================================================
describe('import guards', () => {
  it('rejects a zip that is not PocketDJ and carries no recognizable entries', async () => {
    const buf = await makeZip({ 'manifest.json': JSON.stringify({ app: 'somethingelse' }), 'random.txt': 'hi' });
    await expect(importExportZip(buf)).rejects.toThrow();
  });

  it('accepts a bare edits-only backup (no manifest, no items)', async () => {
    const buf = await makeZip({
      'edits.json': JSON.stringify({ schemaVersion: 2, albums: { alb_x: { genre: 'Soul' } }, songs: {} }),
    });
    const r = await importExportZip(buf);
    expect(r.edits).toBe(1);
    expect(r.portable).toBe(false);
  });
});
