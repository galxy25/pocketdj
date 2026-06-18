// Data cache for the current (source-scope, itemType). Components derive the
// filtered+sorted view with useMemo from `items`. Reloads when scope changes.
// The scope may be a single sourceId, ALL_SOURCE_ID, or an array of sourceIds
// (multi-source subset; [] = none).
import { create } from 'zustand';
import type { MusicItem, ItemType } from '../types/model';
import { getItems } from '../storage/repo';
import { scopeKeyOf } from './useAppStore';

type Scope = string | string[];

interface DataState {
  items: MusicItem[];
  loading: boolean;
  scopeKey: string; // `${scopeKeyOf(scope)}:${itemType}` of the loaded set
  /** epoch bumped on any write so views re-derive after edits/imports. */
  rev: number;
  _scope: Scope;
  _itemType: ItemType;
  load: (scope: Scope, itemType: ItemType) => Promise<void>;
  reload: () => Promise<void>;
  bump: () => void;
}

export const useDataStore = create<DataState>((set, get) => ({
  items: [],
  loading: false,
  scopeKey: '',
  rev: 0,
  _scope: '__all__',
  _itemType: 'album',
  load: async (scope, itemType) => {
    const scopeKey = `${scopeKeyOf(scope)}:${itemType}`;
    set({ loading: true, _scope: scope, _itemType: itemType });
    const items = await getItems(scope, itemType);
    set({ items, loading: false, scopeKey });
  },
  reload: async () => {
    const { _scope, _itemType, scopeKey } = get();
    if (!scopeKey) return;
    const items = await getItems(_scope, _itemType);
    set({ items });
  },
  bump: () => set((s) => ({ rev: s.rev + 1 })),
}));
