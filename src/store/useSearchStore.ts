// Online-search state: the read-only OpenSearch (djpocketsearch) IAM key/secret the
// user enters in Settings, and the online/offline mode. Persisted to localStorage.
// Offline is the default; online mode is only usable once credentials are present.
import { create } from 'zustand';
import type { SigV4Creds } from '../search/sigv4';

const LS_KEY = 'pdj.search.v1';

interface Persisted {
  creds: { accessKeyId: string; secretAccessKey: string } | null;
  online: boolean;
}

function load(): Persisted {
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) {
      const v = JSON.parse(raw);
      const creds = v?.creds?.accessKeyId && v?.creds?.secretAccessKey ? v.creds : null;
      return { creds, online: !!v?.online && !!creds };
    }
  } catch {
    /* ignore */
  }
  return { creds: null, online: false };
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
  hasCreds: () => boolean;
  sigCreds: () => SigV4Creds | null;
  setCreds: (accessKeyId: string, secretAccessKey: string) => void;
  clearCreds: () => void;
  setOnline: (v: boolean) => void;
}

export const useSearchStore = create<SearchState>((set, get) => {
  const init = load();
  return {
    creds: init.creds,
    online: init.online,
    hasCreds: () => !!get().creds,
    sigCreds: () => {
      const c = get().creds;
      return c ? { accessKeyId: c.accessKeyId, secretAccessKey: c.secretAccessKey } : null;
    },
    setCreds: (accessKeyId, secretAccessKey) => {
      const creds = { accessKeyId: accessKeyId.trim(), secretAccessKey: secretAccessKey.trim() };
      save({ creds, online: get().online });
      set({ creds });
    },
    clearCreds: () => {
      // dropping creds forces back to offline
      save({ creds: null, online: false });
      set({ creds: null, online: false });
    },
    setOnline: (v) => {
      const online = v && !!get().creds;
      save({ creds: get().creds, online });
      set({ online });
    },
  };
});
