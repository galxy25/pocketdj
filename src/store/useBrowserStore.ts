// Browser query prefs (filter + sort). Persisted to localStorage — the DATA lives
// in IndexedDB; only these lightweight UI prefs are persisted.
import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import type { FilterClause, FilterState, SortState, SortDir, FilterOp } from '../types/filter';

let clauseSeq = 0;
const newClauseId = () => `c${Date.now().toString(36)}_${clauseSeq++}`;

interface BrowserState {
  filter: FilterState;
  sort: SortState[];
  addClause: (field: string, op?: FilterOp) => void;
  updateClause: (id: string, patch: Partial<FilterClause>) => void;
  removeClause: (id: string) => void;
  clearFilter: () => void;
  setSort: (index: number, patch: Partial<SortState>) => void; // updates an EXISTING index only
  addSort: (field: string, dir?: SortDir) => void; // appends a new key
  removeSort: (index: number) => void;
  clearSort: () => void;
}

export const useBrowserStore = create<BrowserState>()(
  persist(
    (set) => ({
      filter: { clauses: [] },
      sort: [],
      addClause: (field, op = 'eq') =>
        set((s) => ({ filter: { clauses: [...s.filter.clauses, { id: newClauseId(), field, op }] } })),
      updateClause: (id, patch) =>
        set((s) => ({
          filter: { clauses: s.filter.clauses.map((c) => (c.id === id ? { ...c, ...patch } : c)) },
        })),
      removeClause: (id) =>
        set((s) => ({ filter: { clauses: s.filter.clauses.filter((c) => c.id !== id) } })),
      clearFilter: () => set({ filter: { clauses: [] } }),
      // setSort is a PURE index updater — NO append magic; all creation goes through addSort,
      // which always supplies a concrete dir so every stored SortState has a defined dir.
      setSort: (index, patch) =>
        set((s) =>
          index < 0 || index >= s.sort.length
            ? s
            : { sort: s.sort.map((k, j) => (j === index ? { ...k, ...patch } : k)) },
        ),
      addSort: (field, dir = 'asc') => set((s) => ({ sort: [...s.sort, { field, dir }] })),
      removeSort: (index) => set((s) => ({ sort: s.sort.filter((_, j) => j !== index) })),
      clearSort: () => set({ sort: [] }),
    }),
    {
      name: 'pocketdj-browser-prefs',
      storage: createJSONStorage(() => localStorage),
      version: 1,
      partialize: (s) => ({ filter: s.filter, sort: s.sort }),
      // zustand 5.x persist runs `migrate` only when
      // `typeof persisted.version === 'number' && persisted.version !== options.version`.
      // Existing on-disk blobs already carry `version: 0` (persist's default written by
      // setItem), so bumping to `version: 1` makes 0 !== 1 fire migrate for old data.
      // migrate is written version-RANGE-AGNOSTIC and idempotent (does not switch on the
      // version int): a non-array `sort` becomes `[sort]` (or `[]` if falsy), an already-array
      // `sort` passes through unchanged, and `filter` (and any other key) is preserved via the
      // spread. The engine's `Array.isArray` guard is the belt-and-suspenders that also covers
      // the rare case migrate is skipped (truly version-less blob, or a stale PWA
      // service-worker build reading a v1 blob — that older build has no migrate fn, logs an
      // error, and resets sort to default; ACCEPTED as out of scope).
      migrate: (persisted) =>
        persisted && typeof persisted === 'object'
          ? {
              ...(persisted as any),
              sort: Array.isArray((persisted as any).sort)
                ? (persisted as any).sort
                : (persisted as any).sort
                  ? [(persisted as any).sort]
                  : [],
            }
          : persisted,
    },
  ),
);
