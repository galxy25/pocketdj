// PWA remote-endpoint resolver (docs/design/remote-endpoints.md).
//
// Resolution order: last-good fetched doc (localStorage) → compiled-in defaults (blue).
// A fresh fetch of `<BASE_URL>config/endpoints.json` (same origin as the app shell, so no
// CORS and it follows whichever account currently serves app.pocket-dj.com) replaces the
// active config ONLY if it validates; it is then persisted as the new last-good.
// Never blocks launch: callers read `endpoint(key)` synchronously at REQUEST time, so a
// config that lands mid-session applies to the next request and in-flight work is untouched.
import {
  COMPILED_IN_ENDPOINTS,
  validateEndpointDoc,
  type EndpointConfig,
  type EndpointKey,
} from './endpointSchema';

export type EndpointSource = 'compiled-in' | 'cached' | 'remote';

const LS_KEY = 'pdj.endpoints.v1';
/** Foreground refetches are throttled to one per this window (launch always fetches). */
export const ENDPOINT_REFRESH_INTERVAL_MS = 15 * 60 * 1000;

interface State {
  config: EndpointConfig;
  source: EndpointSource;
  lastFetchAt: number | null;
  lastOutcome: string;
}

function safeStorage(): Storage | null {
  try {
    return typeof localStorage !== 'undefined' ? localStorage : null;
  } catch {
    return null;
  }
}

function loadInitial(): State {
  const ls = safeStorage();
  try {
    const raw = ls?.getItem(LS_KEY);
    if (raw) {
      const v = validateEndpointDoc(JSON.parse(raw));
      if (v.ok) return { config: v.config, source: 'cached', lastFetchAt: null, lastOutcome: 'not fetched' };
    }
  } catch {
    /* corrupt cache → compiled-in */
  }
  return { config: COMPILED_IN_ENDPOINTS, source: 'compiled-in', lastFetchAt: null, lastOutcome: 'not fetched' };
}

let state: State = loadInitial();
const listeners = new Set<() => void>();

/** The live URL for `key` (no trailing slash). Read at request time — never cache it. */
export function endpoint(key: EndpointKey): string {
  return state.config.endpoints[key];
}

export function endpointsSnapshot(): Readonly<State> {
  return state;
}

/** One-line summary for diag/debug readouts: `env=blue source=cached`. */
export function endpointsSummary(): string {
  return `env=${state.config.env} source=${state.source} fetch=${state.lastOutcome}`;
}

export function onEndpointsChange(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** Apply a parsed document. Returns true when accepted (and persisted). */
export function applyEndpointDoc(raw: unknown): boolean {
  const v = validateEndpointDoc(raw);
  if (!v.ok) {
    state = { ...state, lastOutcome: `rejected (${v.reason})` };
    return false;
  }
  try {
    safeStorage()?.setItem(LS_KEY, JSON.stringify(raw));
  } catch {
    /* quota / private mode: still apply for this session */
  }
  const changed = JSON.stringify(v.config) !== JSON.stringify(state.config);
  state = { ...state, config: v.config, source: 'remote', lastOutcome: 'accepted' };
  if (changed) listeners.forEach((fn) => fn());
  return true;
}

export function endpointsConfigUrl(): string {
  const base = (import.meta.env?.BASE_URL as string | undefined) ?? '/';
  return `${base}config/endpoints.json`;
}

let inflight: Promise<boolean> | null = null;

/** Fetch + apply the remote doc. Throttled unless `force`; never throws. */
export function refreshEndpoints(
  opts: { force?: boolean; now?: number; fetchImpl?: typeof fetch } = {},
): Promise<boolean> {
  const now = opts.now ?? Date.now();
  if (!opts.force && state.lastFetchAt !== null && now - state.lastFetchAt < ENDPOINT_REFRESH_INTERVAL_MS) {
    return Promise.resolve(false);
  }
  if (inflight) return inflight;
  state = { ...state, lastFetchAt: now };
  const f = opts.fetchImpl ?? fetch;
  inflight = (async () => {
    try {
      const r = await f(endpointsConfigUrl(), { cache: 'no-cache' });
      if (!r.ok) {
        state = { ...state, lastOutcome: `http ${r.status}` };
        return false;
      }
      // The SPA fallback answers a missing file with index.html (200) — JSON.parse rejects it.
      const text = await r.text();
      let parsed: unknown;
      try {
        parsed = JSON.parse(text);
      } catch {
        state = { ...state, lastOutcome: 'rejected (not json)' };
        return false;
      }
      return applyEndpointDoc(parsed);
    } catch {
      state = { ...state, lastOutcome: 'network error' };
      return false;
    } finally {
      inflight = null;
    }
  })();
  return inflight;
}

/** Launch fetch + throttled refetch whenever the tab returns to the foreground. */
export function installEndpointRefresh(): void {
  void refreshEndpoints({ force: true }).then(() => {
    console.info(`[endpoints] ${endpointsSummary()}`);
  });
  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') void refreshEndpoints();
    });
  }
}

/** Test seam: reset to a fresh load (re-reads localStorage). */
export function __resetEndpointsForTests(): void {
  state = loadInitial();
  inflight = null;
  listeners.clear();
}
