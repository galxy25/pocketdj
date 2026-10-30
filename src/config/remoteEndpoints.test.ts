import blueDoc from '../../config/endpoints.blue.json';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  COMPILED_IN_ENDPOINTS,
  isAllowedEndpointHost,
  validateEndpointDoc,
} from './endpointSchema';
import {
  __resetEndpointsForTests,
  applyEndpointDoc,
  endpoint,
  endpointsSnapshot,
  refreshEndpoints,
  ENDPOINT_REFRESH_INTERVAL_MS,
} from './remoteEndpoints';

const GREEN = {
  v: 1,
  env: 'green',
  endpoints: {
    catalogBase: 'https://dgreen123.cloudfront.net',
    ripsBase: 'https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com',
    amPlaylistSyncBase: 'https://abc123.execute-api.us-west-2.amazonaws.com',
    recEngineBase: 'https://def456.execute-api.us-west-2.amazonaws.com',
    diagLogsBase: 'https://pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com',
  },
};

class MemStorage {
  private m = new Map<string, string>();
  getItem(k: string) { return this.m.has(k) ? this.m.get(k)! : null; }
  setItem(k: string, v: string) { this.m.set(k, String(v)); }
  removeItem(k: string) { this.m.delete(k); }
  clear() { this.m.clear(); }
}

const jsonResponse = (body: unknown, status = 200) =>
  new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });

beforeEach(() => {
  vi.stubGlobal('localStorage', new MemStorage());
  __resetEndpointsForTests();
});
afterEach(() => vi.unstubAllGlobals());

describe('endpoint schema v1', () => {
  it('committed config/endpoints.blue.json equals the compiled-in defaults', () => {
    const v = validateEndpointDoc(blueDoc);
    expect(v.ok).toBe(true);
    if (v.ok) expect(v.config).toEqual(COMPILED_IN_ENDPOINTS);
  });

  it('derives optional keys from the SAME doc, never from blue', () => {
    const v = validateEndpointDoc(GREEN);
    expect(v.ok).toBe(true);
    if (!v.ok) return;
    expect(v.config.endpoints.listeningPocketsBase).toBe(GREEN.endpoints.recEngineBase);
    expect(v.config.endpoints.catalogBaseDev).toBe(GREEN.endpoints.catalogBase);
    expect(v.config.endpoints.searchConfigURL).toBe('https://dgreen123.cloudfront.net/search-config.json');
  });

  it('profileSyncBase is optional, validated, and never derived', () => {
    const v0 = validateEndpointDoc(GREEN);
    expect(v0.ok && v0.config.endpoints.profileSyncBase).toBeUndefined();
    const ok = validateEndpointDoc({ ...GREEN, endpoints: { ...GREEN.endpoints, profileSyncBase: 'https://ps1.execute-api.us-west-2.amazonaws.com/' } });
    expect(ok.ok && ok.config.endpoints.profileSyncBase).toBe('https://ps1.execute-api.us-west-2.amazonaws.com');
    for (const bad of ['http://ps1.execute-api.us-west-2.amazonaws.com', 'https://evil.example.com'])
      expect(validateEndpointDoc({ ...GREEN, endpoints: { ...GREEN.endpoints, profileSyncBase: bad } }).ok).toBe(false);
  });

  it('capabilities.profileSyncEnroll is optional, validated, independent of recEngineEnroll (ANS-SYNC-1)', () => {
    const ok = validateEndpointDoc({ ...GREEN, capabilities: { profileSyncEnroll: 'sync-enroll-0123456789abcdef' } });
    expect(ok.ok && ok.config.capabilities).toEqual({ profileSyncEnroll: 'sync-enroll-0123456789abcdef' });
    const both = validateEndpointDoc({ ...GREEN, capabilities: { profileSyncEnroll: 'sync-enroll-0123456789abcdef', recEngineEnroll: 'rotated-secret-0123456789abcdef' } });
    expect(both.ok && both.config.capabilities?.recEngineEnroll).toBe('rotated-secret-0123456789abcdef');
    expect(validateEndpointDoc({ ...GREEN, capabilities: { profileSyncEnroll: 'short' } }, { strictCapabilities: true }).ok).toBe(false);
    const lenient = validateEndpointDoc({ ...GREEN, capabilities: { profileSyncEnroll: 'short' } });
    expect(lenient.ok && lenient.config.capabilities).toBeUndefined();
  });

  it('capabilities.recEngineEnroll is optional and validated (ANS-BRW-2)', () => {
    const v0 = validateEndpointDoc(GREEN);
    expect(v0.ok && v0.config.capabilities).toBeUndefined();
    const ok = validateEndpointDoc({ ...GREEN, capabilities: { recEngineEnroll: 'rotated-secret-0123456789abcdef' } });
    expect(ok.ok && ok.config.capabilities?.recEngineEnroll).toBe('rotated-secret-0123456789abcdef');
    for (const bad of ['short', 42, 'has space in it 0123456789'])
      expect(validateEndpointDoc({ ...GREEN, capabilities: { recEngineEnroll: bad } }, { strictCapabilities: true }).ok).toBe(false);
    expect(validateEndpointDoc({ ...GREEN, capabilities: [] }, { strictCapabilities: true }).ok).toBe(false);
    // RUNTIME (lenient, matches Android): malformed capability is dropped, doc still accepted
    for (const bad of ['short', 42, 'has space in it 0123456789']) {
      const r = validateEndpointDoc({ ...GREEN, capabilities: { recEngineEnroll: bad } });
      expect(r.ok && r.config.capabilities).toBeUndefined();
      expect(r.ok).toBe(true);
    }
    expect(validateEndpointDoc({ ...GREEN, capabilities: [] }).ok).toBe(true);
    // unknown capability keys are ignored (forward compatible)
    expect(validateEndpointDoc({ ...GREEN, capabilities: { somethingNew: true } }).ok).toBe(true);
  });

  it('host allowlist', () => {
    for (const ok of [
      'app.pocket-dj.com', 'pocket-dj.com', 'd2p4cubg6se03u.cloudfront.net',
      'n5ordrwfe9.execute-api.us-west-2.amazonaws.com', 'pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com',
    ]) expect(isAllowedEndpointHost(ok), ok).toBe(true);
    for (const bad of [
      'evil.com', 'pocket-dj.com.evil.com', 'evilpocket-dj.com', 'x.execute-api.us-east-1.amazonaws.com',
      'other-bucket.s3.us-west-2.amazonaws.com', 'pocketdj-rips.s3.us-east-1.amazonaws.com', 'cloudfront.net',
    ]) expect(isAllowedEndpointHost(bad), bad).toBe(false);
  });

  it.each([
    ['wrong version', { ...GREEN, v: 2 }],
    ['missing env', { ...GREEN, env: '' }],
    ['missing required key', { ...GREEN, endpoints: { ...GREEN.endpoints, ripsBase: undefined } }],
    ['http url', { ...GREEN, endpoints: { ...GREEN.endpoints, catalogBase: 'http://dgreen123.cloudfront.net' } }],
    ['foreign host', { ...GREEN, endpoints: { ...GREEN.endpoints, recEngineBase: 'https://api.evil.com' } }],
    ['foreign optional host', { ...GREEN, endpoints: { ...GREEN.endpoints, searchConfigURL: 'https://evil.com/x.json' } }],
    ['credentials in url', { ...GREEN, endpoints: { ...GREEN.endpoints, catalogBase: 'https://u:p@dgreen123.cloudfront.net' } }],
    ['query string', { ...GREEN, endpoints: { ...GREEN.endpoints, catalogBase: 'https://dgreen123.cloudfront.net/?x=1' } }],
    ['not an object', [1, 2]],
  ])('rejects %s', (_label, doc) => {
    expect(validateEndpointDoc(doc).ok).toBe(false);
  });
});

describe('resolver', () => {
  it('starts from compiled-in when nothing is cached', () => {
    expect(endpointsSnapshot().source).toBe('compiled-in');
    expect(endpoint('ripsBase')).toBe(COMPILED_IN_ENDPOINTS.endpoints.ripsBase);
  });

  it('accepts a valid remote doc, persists it, and a fresh launch resolves to the cached last-good', async () => {
    const fetchImpl = vi.fn(async () => jsonResponse(GREEN));
    expect(await refreshEndpoints({ force: true, fetchImpl: fetchImpl as unknown as typeof fetch })).toBe(true);
    expect(endpointsSnapshot().source).toBe('remote');
    expect(endpoint('ripsBase')).toBe(GREEN.endpoints.ripsBase);
    __resetEndpointsForTests(); // simulated relaunch, same storage
    expect(endpointsSnapshot().source).toBe('cached');
    expect(endpointsSnapshot().config.env).toBe('green');
  });

  it('a rejected doc keeps the last-good config (and does not overwrite the cache)', async () => {
    applyEndpointDoc(GREEN);
    const bad = { ...GREEN, env: 'evil', endpoints: { ...GREEN.endpoints, ripsBase: 'https://evil.com' } };
    const ok = await refreshEndpoints({ force: true, fetchImpl: (async () => jsonResponse(bad)) as unknown as typeof fetch });
    expect(ok).toBe(false);
    expect(endpointsSnapshot().config.env).toBe('green');
    __resetEndpointsForTests();
    expect(endpointsSnapshot().config.env).toBe('green');
  });

  it('SPA fallback HTML / http errors / network errors are ignored', async () => {
    for (const f of [
      async () => jsonResponse('<!doctype html><html></html>'),
      async () => jsonResponse({}, 503),
      async () => { throw new TypeError('offline'); },
    ]) {
      expect(await refreshEndpoints({ force: true, fetchImpl: f as unknown as typeof fetch })).toBe(false);
    }
    expect(endpointsSnapshot().source).toBe('compiled-in');
  });

  it('a corrupt cached doc falls back to compiled-in', () => {
    localStorage.setItem('pdj.endpoints.v1', '{"v":1,"env":"x","endpoints":{"catalogBase":"https://evil.com"}}');
    __resetEndpointsForTests();
    expect(endpointsSnapshot().source).toBe('compiled-in');
  });

  it('foreground refetch is throttled; force bypasses', async () => {
    const fetchImpl = vi.fn(async () => jsonResponse(GREEN));
    const f = fetchImpl as unknown as typeof fetch;
    await refreshEndpoints({ force: true, now: 1_000, fetchImpl: f });
    await refreshEndpoints({ now: 1_000 + ENDPOINT_REFRESH_INTERVAL_MS - 1, fetchImpl: f });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    await refreshEndpoints({ now: 1_000 + ENDPOINT_REFRESH_INTERVAL_MS + 1, fetchImpl: f });
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it('call sites read live: the rips store builds URLs on the swapped bucket', async () => {
    const { useRipsStore } = await import('../store/useRipsStore');
    useRipsStore.setState({ manifest: { s1: { key: 'rips/s1.mp3', ext: 'mp3', bytes: 1, source: 'analog', rippedAt: 0 } } });
    expect(useRipsStore.getState().urlFor('s1')).toBe(`${COMPILED_IN_ENDPOINTS.endpoints.ripsBase}/rips/s1.mp3`);
    applyEndpointDoc(GREEN);
    expect(useRipsStore.getState().urlFor('s1')).toBe(`${GREEN.endpoints.ripsBase}/rips/s1.mp3`);
  });
});
