// Drives the zustand persist migrate/hydrate path against seeded localStorage blobs.
// The persist risk is the legacy `sort` shape (object | null) written by the previous
// UNVERSIONED store; bumping to version 1 must migrate those to `SortState[]` while
// preserving `filter`.
//
// The vitest env here is 'node' (see vitest.config.ts) and the project does NOT depend on
// jsdom/happy-dom, so there is no real `localStorage`. We install a minimal in-memory
// Storage shim on globalThis before importing the store (the store's
// `createJSONStorage(() => localStorage)` reads it lazily). Each test resets modules so a
// fresh store re-reads the seeded blob, then awaits the real configured migrate via
// `persist.rehydrate()` (a promise in zustand 5.x).
import { describe, it, expect, beforeEach, vi } from 'vitest';

const KEY = 'pocketdj-browser-prefs';

// Minimal in-memory Storage (getItem/setItem/removeItem is all createJSONStorage needs).
function installLocalStorage() {
  const map = new Map<string, string>();
  const store = {
    getItem: (k: string) => (map.has(k) ? map.get(k)! : null),
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k),
    clear: () => map.clear(),
  };
  (globalThis as any).localStorage = store;
  return store;
}

function seed(value: unknown) {
  localStorage.setItem(KEY, JSON.stringify(value));
}

// Fresh, hydrated store reading the currently-seeded blob.
async function freshStore() {
  vi.resetModules();
  const { useBrowserStore } = await import('./useBrowserStore');
  await useBrowserStore.persist.rehydrate();
  return useBrowserStore;
}

beforeEach(() => {
  installLocalStorage();
});

describe('useBrowserStore — persist migration (legacy sort shapes -> SortState[])', () => {
  it('1. legacy OBJECT sort (version 0) migrates to a single-wrapped array; filter preserved', async () => {
    seed({ state: { filter: { clauses: [] }, sort: { field: 'bpm', dir: 'asc' } }, version: 0 });
    const store = await freshStore();
    expect(store.getState().sort).toEqual([{ field: 'bpm', dir: 'asc' }]);
    expect(store.getState().filter).toEqual({ clauses: [] });
  });

  it('2. legacy NULL sort (version 0) migrates to []', async () => {
    seed({ state: { filter: { clauses: [] }, sort: null }, version: 0 });
    const store = await freshStore();
    expect(store.getState().sort).toEqual([]);
  });

  it('3. already-array sort at version 1 passes through unchanged (no migration)', async () => {
    seed({ state: { filter: { clauses: [] }, sort: [{ field: 'year', dir: 'desc' }] }, version: 1 });
    const store = await freshStore();
    expect(store.getState().sort).toEqual([{ field: 'year', dir: 'desc' }]);
  });

  it('4. migrate is idempotent — rehydrating twice keeps a single-wrapped array', async () => {
    seed({ state: { filter: { clauses: [] }, sort: { field: 'bpm', dir: 'asc' } }, version: 0 });
    const store = await freshStore();
    expect(store.getState().sort).toEqual([{ field: 'bpm', dir: 'asc' }]);
    // A second rehydrate re-reads persisted state; sort must stay single-wrapped (not [[…]]).
    await store.persist.rehydrate();
    expect(store.getState().sort).toEqual([{ field: 'bpm', dir: 'asc' }]);
  });

  it('5. filter is preserved through migration (not dropped) alongside the sort wrap', async () => {
    seed({
      state: {
        filter: { clauses: [{ id: 'c1', field: 'year', op: 'eq', value: 1999 }] },
        sort: { field: 'bpm', dir: 'asc' },
      },
      version: 0,
    });
    const store = await freshStore();
    expect(store.getState().filter.clauses).toHaveLength(1);
    expect(store.getState().sort).toEqual([{ field: 'bpm', dir: 'asc' }]);
  });
});
