// High-level data actions used by the ImportExportBar and the window.__pdj debug
// handle. They touch storage then refresh the stores so the UI reflects changes.
import { importIndexJson, hydrateArt } from '../storage/importIndex';
import { importFile } from '../storage/importZip';
import { downloadExportZip } from '../storage/exportZip';
import type { IndexJson } from '../types/index-json';
import { useAppStore } from '../store/useAppStore';
import { useDataStore } from '../store/useDataStore';
import { getSources } from '../storage/repo';

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
  const res = await fetch(url);
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
