// Dev-only debug handle: window.__pdj. Lets Playwright assert DB state and drive
// data loading without scraping the UI.
import { countItems } from '../storage/repo';
import { clearAllStores } from '../storage/db';
import { loadMockData, exportData } from './dataActions';
import { importIndexJson, hydrateArt } from '../storage/importIndex';
import type { IndexJson } from '../types/index-json';
import { useAppStore } from '../store/useAppStore';
import { useDataStore } from '../store/useDataStore';

export interface PdjDebug {
  counts: () => Promise<{ albums: number; songs: number }>;
  loadMock: () => Promise<{ albums: number; songs: number }>;
  loadIndex: (index: IndexJson, sourceName?: string) => Promise<{ albums: number; songs: number }>;
  exportZip: () => Promise<unknown>;
  clear: () => Promise<void>;
}

export function installDebug() {
  const api: PdjDebug = {
    counts: () => countItems(),
    loadMock: () => loadMockData(),
    loadIndex: async (index, sourceName) => {
      const { source, counts } = await importIndexJson(index, { sourceName });
      await hydrateArt(source.id);
      await useAppStore.getState().refreshSources();
      await useDataStore.getState().reload();
      return counts;
    },
    exportZip: () => exportData(),
    clear: async () => {
      await clearAllStores();
      await useAppStore.getState().refreshSources();
      await useDataStore.getState().reload();
    },
  };
  (window as unknown as { __pdj: PdjDebug }).__pdj = api;
}
