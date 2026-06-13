// Browser query prefs (filter + sort). Persisted to localStorage — the DATA lives
// in IndexedDB; only these lightweight UI prefs are persisted.
import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import type { FilterClause, FilterState, SortState, FilterOp } from '../types/filter';

let clauseSeq = 0;
const newClauseId = () => `c${Date.now().toString(36)}_${clauseSeq++}`;

interface BrowserState {
  filter: FilterState;
  sort: SortState | null;
  addClause: (field: string, op?: FilterOp) => void;
  updateClause: (id: string, patch: Partial<FilterClause>) => void;
  removeClause: (id: string) => void;
  clearFilter: () => void;
  setSort: (sort: SortState | null) => void;
}

export const useBrowserStore = create<BrowserState>()(
  persist(
    (set) => ({
      filter: { clauses: [] },
      sort: null,
      addClause: (field, op = 'eq') =>
        set((s) => ({ filter: { clauses: [...s.filter.clauses, { id: newClauseId(), field, op }] } })),
      updateClause: (id, patch) =>
        set((s) => ({
          filter: { clauses: s.filter.clauses.map((c) => (c.id === id ? { ...c, ...patch } : c)) },
        })),
      removeClause: (id) =>
        set((s) => ({ filter: { clauses: s.filter.clauses.filter((c) => c.id !== id) } })),
      clearFilter: () => set({ filter: { clauses: [] } }),
      setSort: (sort) => set({ sort }),
    }),
    {
      name: 'pocketdj-browser-prefs',
      storage: createJSONStorage(() => localStorage),
    },
  ),
);
