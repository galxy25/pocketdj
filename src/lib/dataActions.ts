// High-level data actions used by the ImportExportBar and the window.__pdj debug
// handle. They touch storage then refresh the stores so the UI reflects changes.
import { importIndexJson, hydrateArt } from '../storage/importIndex';
import { importFile } from '../storage/importZip';
import { downloadExportZip } from '../storage/exportZip';
import type { IndexJson } from '../types/index-json';
import { useAppStore } from '../store/useAppStore';
import { useDataStore } from '../store/useDataStore';
import { getSources } from '../storage/repo';
import { clearAllStores } from '../storage/db';

async function refreshAll() {
  await useAppStore.getState().refreshSources();
  await useDataStore.getState().reload();
}

/** Load the bundled mock index (public/mock-index.json) — demo/dev data at scale. */
export async function loadMockData(onProgress?: (done: number, total: number) => void): Promise<{ albums: number; songs: number }> {
  const res = await fetch(`${import.meta.env.BASE_URL}mock-index.json`);
  if (!res.ok) throw new Error(`mock-index.json not found (${res.status}). Run: npm run gen:mock`);
  const index = (await res.json()) as IndexJson;
  const { source, counts } = await importIndexJson(index, { sourceName: 'Mock Vinyl' });
  await hydrateArt(source.id, onProgress);
  await refreshAll();
  return counts;
}

/** Load an arbitrary index.json by URL (e.g. the real indexer output). */
export async function loadIndexUrl(url: string, sourceName?: string, onProgress?: (done: number, total: number) => void) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`index not found (${res.status})`);
  const index = (await res.json()) as IndexJson;
  const { source, counts } = await importIndexJson(index, { sourceName });
  await hydrateArt(source.id, onProgress);
  await refreshAll();
  return counts;
}

/**
 * First-run seed: if the DB has no sources yet, load the bundled catalog
 * (public/current-index.json) so the deployed site shows data with no console /
 * manual import — used on app boot (mobile-friendly). No-op if data already exists.
 */
export async function seedIfEmpty(onProgress?: (done: number, total: number) => void): Promise<{ albums: number; songs: number } | null> {
  const sources = await getSources();
  if (sources.length > 0) {
    await refreshAll();
    return null;
  }
  const url = `${import.meta.env.BASE_URL}current-index.json`;
  // `cache: 'reload'` bypasses the browser HTTP cache so a fresh first-boot / force-refresh
  // always pulls the latest catalog — not a stale copy left over from when the seed was
  // (mistakenly) served immutable. The seed is fetched rarely (empty DB only), so the cost
  // is negligible.
  const res = await fetch(url, { cache: 'reload' });
  if (!res.ok) {
    await refreshAll();
    return null; // no seed file deployed — render empty rather than block
  }
  const index = (await res.json()) as IndexJson;
  const { source, counts } = await importIndexJson(index, { sourceName: 'My Vinyl' });
  await hydrateArt(source.id, onProgress);
  await refreshAll();
  return counts;
}

export async function importUserFile(file: File, onProgress?: (done: number, total: number) => void) {
  const r = await importFile(file, onProgress);
  await refreshAll();
  return r;
}

export async function exportData() {
  return downloadExportZip();
}

/**
 * Force a full refresh ON THIS DEVICE: drop the service-worker caches + the cached app
 * shell + the IndexedDB catalog, then reload so the newest app code AND the latest seed
 * data are pulled fresh from the server. This is the fix for "I'm still seeing old
 * data/UI on my phone" — the SW caches the shell, and auto-seed only runs on an empty DB,
 * so a previously-loaded catalog otherwise sticks across deploys.
 */
export async function forceRefreshCatalog(): Promise<void> {
  try {
    if ('serviceWorker' in navigator) {
      const regs = await navigator.serviceWorker.getRegistrations();
      await Promise.all(regs.map((r) => r.unregister().catch(() => {})));
    }
    if ('caches' in window) {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
    }
  } catch {
    /* best-effort cache clear; still wipe + reload below */
  }
  await clearAllStores();
  // Reload: with the SW gone the browser fetches the freshest shell, and seedIfEmpty
  // re-pulls current-index.json into a now-empty DB.
  window.location.reload();
}
