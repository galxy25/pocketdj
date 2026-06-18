// OpenSearch (Serverless, "aoss") search client for the app's ONLINE mode.
// Signs each query with the user's read-only djpocketsearch key/secret (SigV4) and
// hits a SAME-ORIGIN proxy path that CloudFront forwards to the aoss collection
// (which has no CORS of its own). Maps hits to the app's MusicItem shape so the
// existing grid renders them.
import { signRequest, type SigV4Creds } from './sigv4';
import type { MusicItem, AlbumItem, SongItem } from '../types/model';

/** Fixed (non-secret) backend config. The user only supplies the key/secret. */
export const SEARCH_CFG = {
  host: 'zxvkpgoc5ivtrbqp37s5.us-west-2.aoss.amazonaws.com',
  region: 'us-west-2',
  service: 'aoss',
  index: 'pocketdj',
  /** Same-origin path a CloudFront behavior forwards to the aoss origin. Must
   *  equal `/<index>` so the signed path matches what aoss receives. */
  proxyBase: '/pocketdj',
};

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
  const path = `${SEARCH_CFG.proxyBase}/_search`; // e.g. /pocketdj/_search
  const body = JSON.stringify(buildQuery(params));
  const headers = await signRequest({
    method: 'POST',
    host: SEARCH_CFG.host,
    path,
    body,
    region: SEARCH_CFG.region,
    service: SEARCH_CFG.service,
    creds,
  });
  headers['Content-Type'] = 'application/json';
  const t0 = performance.now();
  const res = await fetch(path, { method: 'POST', headers, body });
  const text = await res.text();
  if (!res.ok) throw new Error(`Search failed (${res.status}): ${text.slice(0, 200)}`);
  const json = JSON.parse(text);
  const hits = json.hits?.hits ?? [];
  return {
    items: hits.map((h: { _source: EsHitSource }) => hitToItem(h._source)),
    total: typeof json.hits?.total === 'object' ? json.hits.total.value : json.hits?.total ?? hits.length,
    tookMs: Math.round(performance.now() - t0),
  };
}
