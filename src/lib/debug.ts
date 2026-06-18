// Dev-only debug handle: window.__pdj. Lets Playwright assert DB state and drive
// data loading without scraping the UI.
import { countItems, getPockets, getPlaylists, getAllSetlists } from '../storage/repo';
import { clearAllStores } from '../storage/db';
import { loadMockData, loadIndexUrl, exportData } from './dataActions';
import { importIndexJson, hydrateArt } from '../storage/importIndex';
import type { IndexJson } from '../types/index-json';
import { useAppStore } from '../store/useAppStore';
import { useDataStore } from '../store/useDataStore';

export interface PdjDebug {
  counts: () => Promise<{ albums: number; songs: number }>;
  /** Collection-store tallies (pockets / playlists / setlists) for e2e assertions. */
  collections: () => Promise<{ pockets: number; playlists: number; setlists: number }>;
  loadMock: () => Promise<{ albums: number; songs: number }>;
  loadIndex: (index: IndexJson, sourceName?: string) => Promise<{ albums: number; songs: number }>;
  /** Fetch + import an index.json by URL (e.g. /apple-music-index.json). */
  loadIndexUrl: (url: string, sourceName?: string) => Promise<{ albums: number; songs: number }>;
  exportZip: () => Promise<unknown>;
  clear: () => Promise<void>;
}

export function installDebug() {
  const api: PdjDebug = {
    counts: () => countItems(),
    collections: async () => {
      const [pockets, playlists, setlists] = await Promise.all([
        getPockets(),
        getPlaylists(),
        getAllSetlists(),
      ]);
      return { pockets: pockets.length, playlists: playlists.length, setlists: setlists.length };
    },
    loadMock: () => loadMockData(),
    loadIndex: async (index, sourceName) => {
      const { source, counts } = await importIndexJson(index, { sourceName });
      await hydrateArt(source.id, undefined, { placeholders: source.type !== 'digital' });
      await useAppStore.getState().refreshSources();
      await useDataStore.getState().reload();
      return counts;
    },
    loadIndexUrl: (url, sourceName) => loadIndexUrl(url, sourceName),
    exportZip: () => exportData(),
    clear: async () => {
      await clearAllStores();
      await useAppStore.getState().refreshSources();
      await useDataStore.getState().reload();
    },
  };
  (window as unknown as { __pdj: PdjDebug }).__pdj = api;
}
