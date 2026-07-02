// Online-search state: the read-only OpenSearch (djpocketsearch) IAM key/secret the
// user enters in Settings, the online/offline mode, and an optional per-user search
// HOST override. Persisted to localStorage. Offline is the default; online mode is only
// usable once credentials are present.
//
// Host resolution (see esClient): user override (this store) → global /search-config.json
// → baked default. The override is a no-app-update migration path AND the seam for
// per-user PRIVATE search hosts (falling back to the global host when unset).
import { create } from 'zustand';
import type { SigV4Creds } from '../search/sigv4';
import { setSearchHostOverride } from '../search/esClient';

const LS_KEY = 'pdj.search.v1';

interface Persisted {
  creds: { accessKeyId: string; secretAccessKey: string } | null;
  online: boolean;
  hostOverride: string | null;
}

function load(): Persisted {
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) {
      const v = JSON.parse(raw);
      const creds = v?.creds?.accessKeyId && v?.creds?.secretAccessKey ? v.creds : null;
      const hostOverride = typeof v?.hostOverride === 'string' && v.hostOverride.trim() ? v.hostOverride.trim() : null;
      return { creds, online: !!v?.online && !!creds, hostOverride };
    }
  } catch {
    /* ignore */
  }
  return { creds: null, online: false, hostOverride: null };
}
function save(p: Persisted): void {
  try {
    localStorage.setItem(LS_KEY, JSON.stringify(p));
  } catch {
    /* ignore */
  }
}

interface SearchState {
  creds: { accessKeyId: string; secretAccessKey: string } | null;
  online: boolean;
  /** null = use the global host from /search-config.json; non-null = per-user override. */
  hostOverride: string | null;
  hasCreds: () => boolean;
  sigCreds: () => SigV4Creds | null;
  setCreds: (accessKeyId: string, secretAccessKey: string) => void;
  clearCreds: () => void;
  setOnline: (v: boolean) => void;
  setHostOverride: (h: string | null) => void;
}

export const useSearchStore = create<SearchState>((set, get) => {
  const init = load();
  // Push any persisted override into the search client on startup so it wins over the
  // global /search-config.json host for signing + routing.
  setSearchHostOverride(init.hostOverride);
  const persist = () => save({ creds: get().creds, online: get().online, hostOverride: get().hostOverride });
  return {
    creds: init.creds,
    online: init.online,
    hostOverride: init.hostOverride,
    hasCreds: () => !!get().creds,
    sigCreds: () => {
      const c = get().creds;
      return c ? { accessKeyId: c.accessKeyId, secretAccessKey: c.secretAccessKey } : null;
    },
    setCreds: (accessKeyId, secretAccessKey) => {
      set({ creds: { accessKeyId: accessKeyId.trim(), secretAccessKey: secretAccessKey.trim() } });
      persist();
    },
    clearCreds: () => {
      // dropping creds forces back to offline
      set({ creds: null, online: false });
      persist();
    },
    setOnline: (v) => {
      set({ online: v && !!get().creds });
      persist();
    },
    setHostOverride: (h) => {
      const clean = h && h.trim() ? h.trim() : null;
      set({ hostOverride: clean });
      setSearchHostOverride(clean); // apply immediately to the search client
      persist();
    },
  };
});
