// Remote endpoint config — schema v1 (docs/design/remote-endpoints.md).
//
// PURE module: no fetch, no storage, no React. It is the canonical validator for the
// TypeScript side and is shared by the PWA resolver (remoteEndpoints.ts) AND the deploy-time
// check (scripts/validate-endpoints.ts), so a document deploy.sh publishes is exactly a
// document the PWA accepts. The Swift (EndpointConfig) and Kotlin (RemoteEndpoints) clients
// implement the SAME rules; the cross-client fixture tests pin them.

export const ENDPOINT_SCHEMA_VERSION = 1;

/** Keys a document MUST carry (each an https URL on an allowlisted host). */
export const REQUIRED_ENDPOINT_KEYS = [
  'catalogBase',
  'ripsBase',
  'amPlaylistSyncBase',
  'recEngineBase',
  'diagLogsBase',
] as const;

/** Keys a document MAY carry; when absent they DERIVE from the same document (never from
 *  the compiled-in blue values — a green doc must never half-fall-back to blue). */
export const OPTIONAL_ENDPOINT_KEYS = ['catalogBaseDev', 'listeningPocketsBase', 'searchConfigURL', 'profileSyncBase'] as const;

export type RequiredEndpointKey = (typeof REQUIRED_ENDPOINT_KEYS)[number];
export type OptionalEndpointKey = (typeof OPTIONAL_ENDPOINT_KEYS)[number];
export type EndpointKey = RequiredEndpointKey | OptionalEndpointKey;

export interface EndpointConfig {
  v: 1;
  env: string;
  /** Every key resolved (optional keys already derived). No trailing slash. `profileSyncBase`
   *  (Android profile sync) has no derivation: absent stays absent => sync disabled. */
  endpoints: Record<Exclude<EndpointKey, 'profileSyncBase'>, string> & { profileSyncBase?: string };
  /** Extra catalog hosts whose persisted URLs rebase onto this doc's catalog bases. */
  aliases: { catalogBase: string[]; catalogBaseDev: string[] };
  /** Optional capabilities (ANS-BRW-2). Present only when the doc carries a valid one; the PWA
   *  ignores it. `recEngineEnroll` = the rotatable rec-engine enrollment secret the native
   *  clients read at request time (Android adopts it; iOS ignores unknown keys). */
  capabilities?: { recEngineEnroll?: string };
}

/** Enroll-secret shape the native clients accept (mirrors Kotlin EndpointConfig.normalizeEnroll). */
export const ENROLL_SECRET_RE = /^[A-Za-z0-9._~+/=-]{16,256}$/;

/** Today's values (the blue account, 011183829623) — the last-resort fallback. Must equal
 *  config/endpoints.blue.json (a vitest pins that). */
export const COMPILED_IN_ENDPOINTS: EndpointConfig = {
  v: 1,
  env: 'blue',
  endpoints: {
    catalogBase: 'https://d2p4cubg6se03u.cloudfront.net',
    catalogBaseDev: 'https://djictbz9w796r.cloudfront.net',
    ripsBase: 'https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com',
    amPlaylistSyncBase: 'https://ynwdaa8vh2.execute-api.us-west-2.amazonaws.com',
    recEngineBase: 'https://n5ordrwfe9.execute-api.us-west-2.amazonaws.com',
    listeningPocketsBase: 'https://n5ordrwfe9.execute-api.us-west-2.amazonaws.com',
    diagLogsBase: 'https://pocketdj-logs-011183829623.s3.us-west-2.amazonaws.com',
    searchConfigURL: 'https://d2p4cubg6se03u.cloudfront.net/search-config.json',
  },
  aliases: { catalogBase: [], catalogBaseDev: [] },
};

/** Host allowlist (lower-cased host, no port):
 *   pocket-dj.com and *.pocket-dj.com · *.cloudfront.net · <id>.execute-api.us-west-2.amazonaws.com
 *   · pocketdj-<name>.s3.us-west-2.amazonaws.com (virtual-hosted S3, our bucket prefix only). */
export function isAllowedEndpointHost(host: string): boolean {
  const h = host.toLowerCase();
  if (h === 'pocket-dj.com' || /^[a-z0-9-]+(\.[a-z0-9-]+)*\.pocket-dj\.com$/.test(h)) return true;
  if (/^[a-z0-9]+\.cloudfront\.net$/.test(h)) return true;
  if (/^[a-z0-9]+\.execute-api\.us-west-2\.amazonaws\.com$/.test(h)) return true;
  if (/^pocketdj-[a-z0-9-]+\.s3\.us-west-2\.amazonaws\.com$/.test(h)) return true;
  return false;
}

/** https, allowlisted host, no credentials / port / query / fragment. Returns the URL with any
 *  trailing slash trimmed, or null. */
export function normalizeEndpointUrl(raw: unknown): string | null {
  if (typeof raw !== 'string' || !raw) return null;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:') return null;
  if (u.username || u.password || u.port || u.search || u.hash) return null;
  if (!isAllowedEndpointHost(u.hostname)) return null;
  return u.toString().replace(/\/+$/, '');
}

export type ValidationResult = { ok: true; config: EndpointConfig } | { ok: false; reason: string };

function hostList(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((h): h is string => typeof h === 'string' && isAllowedEndpointHost(h)).map((h) => h.toLowerCase());
}

/** Validate a parsed JSON document. Unknown top-level / endpoint keys are ignored (forward
 *  compatible); ANY invalid URL among known keys rejects the whole document. */
export function validateEndpointDoc(raw: unknown, opts: { strictCapabilities?: boolean } = {}): ValidationResult {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ok: false, reason: 'not an object' };
  const doc = raw as Record<string, unknown>;
  if (doc.v !== ENDPOINT_SCHEMA_VERSION) return { ok: false, reason: `unsupported v=${String(doc.v)}` };
  const env = typeof doc.env === 'string' && doc.env.trim() ? doc.env.trim() : null;
  if (!env) return { ok: false, reason: 'missing env' };
  const eps = doc.endpoints;
  if (!eps || typeof eps !== 'object' || Array.isArray(eps)) return { ok: false, reason: 'missing endpoints' };
  const e = eps as Record<string, unknown>;
  const out: Partial<Record<EndpointKey, string>> = {};
  for (const k of REQUIRED_ENDPOINT_KEYS) {
    if (e[k] === undefined) return { ok: false, reason: `missing ${k}` };
    const n = normalizeEndpointUrl(e[k]);
    if (!n) return { ok: false, reason: `rejected ${k}` };
    out[k] = n;
  }
  for (const k of OPTIONAL_ENDPOINT_KEYS) {
    if (e[k] === undefined) continue;
    const n = normalizeEndpointUrl(e[k]);
    if (!n) return { ok: false, reason: `rejected ${k}` };
    out[k] = n;
  }
  // Derive absent optional keys from THIS document.
  out.catalogBaseDev ??= out.catalogBase;
  out.listeningPocketsBase ??= out.recEngineBase;
  out.searchConfigURL ??= `${out.catalogBase}/search-config.json`;
  const al = (doc.aliases && typeof doc.aliases === 'object' ? doc.aliases : {}) as Record<string, unknown>;
  // Optional capabilities. At RUNTIME (PWA, matching Android) a malformed capability is DROPPED and
  // the rest of the doc is still accepted: rejecting the whole doc would strand clients on stale or
  // dead compiled-in endpoints. The deploy-time gate (scripts/validate-endpoints.ts) passes
  // `strictCapabilities` so a typo is REJECTED before it ships.
  const strict = opts.strictCapabilities === true;
  let capabilities: EndpointConfig['capabilities'];
  if (doc.capabilities !== undefined) {
    if (!doc.capabilities || typeof doc.capabilities !== 'object' || Array.isArray(doc.capabilities)) {
      if (strict) return { ok: false, reason: 'rejected capabilities' };
    } else {
      const c = doc.capabilities as Record<string, unknown>;
      if (c.recEngineEnroll !== undefined) {
        if (typeof c.recEngineEnroll === 'string' && ENROLL_SECRET_RE.test(c.recEngineEnroll.trim())) {
          capabilities = { recEngineEnroll: c.recEngineEnroll.trim() };
        } else if (strict) {
          return { ok: false, reason: 'rejected capabilities.recEngineEnroll' };
        }
      }
    }
  }
  return {
    ok: true,
    config: {
      v: 1,
      env,
      endpoints: out as EndpointConfig['endpoints'],
      aliases: { catalogBase: hostList(al.catalogBase), catalogBaseDev: hostList(al.catalogBaseDev) },
      ...(capabilities ? { capabilities } : {}),
    },
  };
}
