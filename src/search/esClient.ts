// OpenSearch (Serverless, "aoss") search client for the app's ONLINE mode.
// Signs each query with the user's read-only djpocketsearch key/secret (SigV4) and
// hits a SAME-ORIGIN proxy path that CloudFront forwards to the aoss collection
// (which has no CORS of its own). Maps hits to the app's MusicItem shape so the
// existing grid renders them.
import { signRequest, type SigV4Creds } from './sigv4';
import type { MusicItem, AlbumItem, SongItem } from '../types/model';

/** Backend config (non-secret; the user only supplies the key/secret). The `host`
 *  is a DEFAULT — it's overridden at launch by `/search-config.json` (see
 *  `loadSearchConfig`) so the aoss collection can be swapped (e.g. a scale-to-zero
 *  rebuild) WITHOUT shipping a new client. The baked value is the current prod host
 *  so search still works if the config fetch fails. */
export const SEARCH_CFG = {
  host: 'mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws',
  region: 'us-west-2',
  service: 'aoss',
  index: 'pocketdj',
  /** Same-origin path a CloudFront behavior forwards to the aoss origin. Must
   *  equal `/<index>` so the signed path matches what aoss receives. */
  proxyBase: '/pocketdj',
};

/** Fetch `/search-config.json` (served by the app's CloudFront) once and overlay it
 *  onto SEARCH_CFG. Memoized so concurrent searches share one fetch. On any failure
 *  the baked defaults stand. Called at app launch AND awaited before each search, so
 *  the first query can't race ahead of the config. */
let searchConfigPromise: Promise<void> | null = null;
export function loadSearchConfig(): Promise<void> {
  if (!searchConfigPromise) {
    const url = `${import.meta.env.BASE_URL}search-config.json`;
    searchConfigPromise = fetch(url, { cache: 'no-cache' })
      .then((r) => (r.ok ? r.json() : null))
      .then((cfg) => {
        if (cfg && typeof cfg.host === 'string' && cfg.host) SEARCH_CFG.host = cfg.host;
        if (cfg && typeof cfg.region === 'string' && cfg.region) SEARCH_CFG.region = cfg.region;
        if (cfg && typeof cfg.index === 'string' && cfg.index) SEARCH_CFG.index = cfg.index;
      })
      .catch(() => { /* keep baked defaults */ });
  }
  return searchConfigPromise;
}

/** Per-user host override (set from Settings via useSearchStore). When present it wins
 *  over the global SEARCH_CFG.host for BOTH signing and routing — a no-app-update
 *  migration path and the seam for a private search host. Null → global host. */
let hostOverride: string | null = null;
export function setSearchHostOverride(h: string | null): void {
  hostOverride = h && h.trim() ? h.trim() : null;
}
/** The host the next search signs for: user override → global config → baked default. */
export function effectiveSearchHost(): string {
  return hostOverride ?? SEARCH_CFG.host;
}

export interface SearchParams {
  q: string;
  type?: 'album' | 'song';
  /** Restrict to these source names (DataSource.name). Empty/undefined = all. */
  sources?: string[];
  size?: number;
}

interface EsHitSource {
  id: string;
  type: 'album' | 'song';
  title?: string;
  artist?: string;
  album?: string;
  albumId?: string;
  genre?: string;
  year?: number;
  bpm?: number;
  key?: string;
  camelot?: string;
  explicit?: boolean;
  sourceType?: 'analog' | 'digital';
  source?: string;
  trackNumber?: number;
}

function buildQuery(p: SearchParams) {
  const filter: unknown[] = [];
  if (p.type) filter.push({ term: { type: p.type } });
  if (p.sources && p.sources.length) filter.push({ terms: { source: p.sources } });
  const must = p.q.trim()
    ? [
        {
          multi_match: {
            query: p.q,
            // search across titles (song + album), artist, album, lyrics, sentiment
            fields: ['title^3', 'artist^2', 'album^1.5', 'lyrics', 'sentiment^2'],
            type: 'best_fields',
            fuzziness: 'AUTO',
            operator: 'and',
          },
        },
      ]
    : [{ match_all: {} }];
  return { size: p.size ?? 60, query: { bool: { must, filter } } };
}

/** Map an aoss hit to a (partial) MusicItem the grid can render. */
function hitToItem(src: EsHitSource): MusicItem {
  const base = {
    id: src.id,
    sourceId: '', // unknown from ES; not needed for display
    createdAt: 0,
    updatedAt: 0,
    artist: src.artist ?? '',
    name: src.title ?? '',
    genre: src.genre,
    year: src.year,
  };
  if (src.type === 'album') {
    return { ...base, type: 'album', trackIds: [] } as AlbumItem;
  }
  return {
    ...base,
    type: 'song',
    albumId: src.albumId,
    trackNumber: src.trackNumber,
    bpm: src.bpm ?? null,
    key: src.key ?? null,
    camelot: src.camelot ?? null,
    explicit: !!src.explicit,
    sentimentKeywords: [],
  } as SongItem;
}

export interface SearchResult {
  items: MusicItem[];
  total: number;
  tookMs: number;
}

/** Run a signed search. Throws on auth/transport errors (caller surfaces it). */
export async function esSearch(params: SearchParams, creds: SigV4Creds): Promise<SearchResult> {
  await loadSearchConfig(); // ensure SEARCH_CFG.host reflects /search-config.json before signing
  const host = effectiveSearchHost(); // user override → global config → baked
  const path = `${SEARCH_CFG.proxyBase}/_search`; // e.g. /pocketdj/_search
  const body = JSON.stringify(buildQuery(params));
  const headers = await signRequest({
    method: 'POST',
    host,
    path,
    body,
    region: SEARCH_CFG.region,
    service: SEARCH_CFG.service,
    creds,
  });
  headers['Content-Type'] = 'application/json';
  // Global host → same-origin CloudFront proxy (aoss has no CORS of its own). A user
  // override is a private host the user configured → fetch it directly (it must serve
  // CORS headers, e.g. a private collection fronted for the browser).
  const url = hostOverride ? `https://${host}${path}` : path;
  const t0 = performance.now();
  const res = await fetch(url, { method: 'POST', headers, body });
  const text = await res.text();
  if (!res.ok) throw new Error(`Search failed (${res.status}): ${text.slice(0, 200)}`);
  const json = JSON.parse(text);
  const hits = json.hits?.hits ?? [];
  return {
    // `_id` is authoritative for the item id (robust even if _source.id is absent).
    items: hits.map((h: { _id: string; _source: EsHitSource }) => hitToItem({ ...h._source, id: h._id })),
    total: typeof json.hits?.total === 'object' ? json.hits.total.value : json.hits?.total ?? hits.length,
    tookMs: Math.round(performance.now() - t0),
  };
}
