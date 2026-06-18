// Global app state: known data sources, the source SELECTION (all / none / a
// subset), the item type being browsed (album/song), and the current view.
//
// Multi-source selection: the user can show data for ALL sources, NONE, or a
// chosen subset (e.g. just vinyl, or vinyl + Apple Music). The selection is
// modelled as a mode + an explicit id list and persisted to localStorage so it
// survives refresh. `scope()` turns it into the scope getItems() understands.
import { create } from 'zustand';
import type { DataSource, ItemType } from '../types/model';
import { ALL_SOURCE_ID } from '../types/model';
import { getSources } from '../storage/repo';

export type ViewMode = 'browse' | 'map';
export type SourceMode = 'all' | 'subset';

const LS_KEY = 'pdj.sourceSelection.v1';

function loadSelection(): { mode: SourceMode; ids: string[] } {
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) {
      const v = JSON.parse(raw);
      if (v && (v.mode === 'all' || v.mode === 'subset') && Array.isArray(v.ids)) {
        return { mode: v.mode, ids: v.ids };
      }
    }
  } catch {
    /* ignore */
  }
  return { mode: 'all', ids: [] };
}

function saveSelection(mode: SourceMode, ids: string[]): void {
  try {
    localStorage.setItem(LS_KEY, JSON.stringify({ mode, ids }));
  } catch {
    /* ignore */
  }
}

/**
 * Resolve a selection into the scope getItems() takes:
 *   'all'    → ALL_SOURCE_ID (single fast path over every item)
 *   'subset' → the selected ids (filtered to known sources). [] means "none".
 *              If the subset covers every known source, collapse to ALL_SOURCE_ID.
 */
export function scopeFor(
  mode: SourceMode,
  ids: string[],
  sources: DataSource[],
): string | string[] {
  if (mode === 'all') return ALL_SOURCE_ID;
  const known = new Set(sources.map((s) => s.id));
  const sel = ids.filter((id) => known.has(id));
  if (sources.length > 0 && sel.length === sources.length) return ALL_SOURCE_ID;
  return sel;
}

/** Stable cache key for a scope (so the data store knows when to reload). */
export function scopeKeyOf(scope: string | string[]): string {
  return Array.isArray(scope) ? `[${[...scope].sort().join(',')}]` : scope;
}

interface AppState {
  sources: DataSource[];
  /** Source selection. mode 'all' = every (incl. future) source; 'subset' = `selectedSourceIds`. */
  sourceMode: SourceMode;
  selectedSourceIds: string[];
  itemType: ItemType;
  view: ViewMode;
  refreshSources: () => Promise<void>;
  selectAllSources: () => void;
  selectNoSources: () => void;
  toggleSource: (id: string) => void;
  setItemType: (t: ItemType) => void;
  setView: (v: ViewMode) => void;
  /** The resolved scope for the current selection (ALL_SOURCE_ID | id[] | []). */
  scope: () => string | string[];
}

export const useAppStore = create<AppState>((set, get) => {
  const init = loadSelection();
  return {
    sources: [],
    sourceMode: init.mode,
    selectedSourceIds: init.ids,
    itemType: 'album',
    view: 'map',
    refreshSources: async () => {
      const sources = await getSources();
      set({ sources });
    },
    selectAllSources: () => {
      saveSelection('all', []);
      set({ sourceMode: 'all', selectedSourceIds: [] });
    },
    selectNoSources: () => {
      saveSelection('subset', []);
      set({ sourceMode: 'subset', selectedSourceIds: [] });
    },
    toggleSource: (id) => {
      const { sourceMode, selectedSourceIds, sources } = get();
      // Toggling from 'all' starts an explicit subset seeded with every source,
      // then removes/keeps the toggled one — intuitive ("all, minus this").
      const base = sourceMode === 'all' ? sources.map((s) => s.id) : selectedSourceIds;
      const next = base.includes(id) ? base.filter((x) => x !== id) : [...base, id];
      saveSelection('subset', next);
      set({ sourceMode: 'subset', selectedSourceIds: next });
    },
    setItemType: (t) => set({ itemType: t }),
    setView: (v) => set({ view: v }),
    scope: () => {
      const { sourceMode, selectedSourceIds, sources } = get();
      return scopeFor(sourceMode, selectedSourceIds, sources);
    },
  };
});
