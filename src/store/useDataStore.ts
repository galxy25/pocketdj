// Data cache for the current (source, itemType) scope. Components derive the
// filtered+sorted view with useMemo from `items`. Reloads when scope changes.
import { create } from 'zustand';
import type { MusicItem, ItemType } from '../types/model';
import { getItems } from '../storage/repo';

interface DataState {
  items: MusicItem[];
  loading: boolean;
  scopeKey: string; // `${sourceId}:${itemType}` of the loaded set
  /** epoch bumped on any write so views re-derive after edits/imports. */
  rev: number;
  load: (sourceId: string, itemType: ItemType) => Promise<void>;
  reload: () => Promise<void>;
  bump: () => void;
}

export const useDataStore = create<DataState>((set, get) => ({
  items: [],
  loading: false,
  scopeKey: '',
  rev: 0,
  load: async (sourceId, itemType) => {
    const scopeKey = `${sourceId}:${itemType}`;
    set({ loading: true });
    const items = await getItems(sourceId, itemType);
    set({ items, loading: false, scopeKey });
  },
  reload: async () => {
    const key = get().scopeKey;
    if (!key) return;
    const [sourceId, itemType] = key.split(':');
    const items = await getItems(sourceId, itemType as ItemType);
    set({ items });
  },
  bump: () => set((s) => ({ rev: s.rev + 1 })),
}));
