// Global app state: known data sources, the active source (incl. virtual "All"),
// the item type being browsed (album/song), and the current view.
import { create } from 'zustand';
import type { DataSource, ItemType } from '../types/model';
import { ALL_SOURCE_ID } from '../types/model';
import { getSources } from '../storage/repo';

export type ViewMode = 'browse' | 'map';

interface AppState {
  sources: DataSource[];
  activeSourceId: string; // ALL_SOURCE_ID for the virtual "All" source
  itemType: ItemType;
  view: ViewMode;
  refreshSources: () => Promise<void>;
  setActiveSource: (id: string) => void;
  setItemType: (t: ItemType) => void;
  setView: (v: ViewMode) => void;
}

export const useAppStore = create<AppState>((set) => ({
  sources: [],
  activeSourceId: ALL_SOURCE_ID,
  itemType: 'album',
  view: 'map',
  refreshSources: async () => {
    const sources = await getSources();
    set({ sources });
  },
  setActiveSource: (id) => set({ activeSourceId: id }),
  setItemType: (t) => set({ itemType: t }),
  setView: (v) => set({ view: v }),
}));
