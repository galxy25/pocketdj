// Cover-art caching: download real cover URLs into IndexedDB thumbnail blobs
// (offline-first), or generate deterministic procedural placeholders for mock /
// missing art. Rendering uses an in-memory objectURL LRU so 1,366 stars don't
// pin a bitmap each.
import { getArt, putArt } from './repo';
import type { ArtRecord } from './db';
import type { ArtSource } from '../types/model';
import { hashKey, seededRng } from '../lib/prng';
import { txn } from '../lib/log';

const THUMB = 256;

/** Stable cache key for a source URL. */
export function artKeyForUrl(url: string): string {
  return 'art_' + hashKey(url);
}

/** Stable cache key for a procedural placeholder seeded by an id. */
export function placeholderKey(seed: string): string {
  return 'ph_' + hashKey(seed);
}

/** Decode + downscale an image blob to a webp thumbnail (longest edge THUMB). */
async function toThumb(blob: Blob): Promise<{ thumb: Blob; w: number; h: number }> {
  const bitmap = await createImageBitmap(blob);
  const scale = Math.min(1, THUMB / Math.max(bitmap.width, bitmap.height));
  const w = Math.max(1, Math.round(bitmap.width * scale));
  const h = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = new OffscreenCanvas(w, h);
  const ctx = canvas.getContext('2d')!;
  ctx.drawImage(bitmap, 0, 0, w, h);
  bitmap.close();
  const thumb = await canvas.convertToBlob({ type: 'image/webp', quality: 0.82 });
  return { thumb, w, h };
}

/**
 * Ensure a cover URL is cached. Returns the art key (so the AlbumItem can store
 * coverArtKey). On failure, records status:'missing' so we don't retry forever.
 */
// Hosts known to send permissive CORS headers, so we can fetch + thumbnail them
// into an offline blob. Everything else (e.g. Discogs' i.discogs.com CDN) is
// displayed directly via <img> — fetching it would only log a CORS error.
const CORS_FRIENDLY_HOST = /(^|\.)mzstatic\.com$/i;
function isCorsFriendly(url: string): boolean {
  try {
    return CORS_FRIENDLY_HOST.test(new URL(url).hostname);
  } catch {
    return false;
  }
}

export async function cacheArtUrl(url: string): Promise<string> {
  const key = artKeyForUrl(url);
  const existing = await getArt(key);
  if (existing && existing.status !== 'pending') return key;
  // Skip the doomed CORS fetch for non-friendly hosts — display the URL directly.
  if (!isCorsFriendly(url)) {
    await putArt({ key, url, status: 'url' });
    return key;
  }
  try {
    const res = await fetch(url, { mode: 'cors' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const blob = await res.blob();
    const { thumb, w, h } = await toThumb(blob);
    await putArt({ key, thumb, url, status: 'ok', w, h });
  } catch (error) {
    // CORS-blocked sources (e.g. Discogs CDN sends no Access-Control-Allow-Origin)
    // can't be fetched/thumbnailed for an offline blob — but the browser can still
    // DISPLAY them via <img>/<image src=url>. Keep the URL for direct display.
    await putArt({ key, url, status: 'url' });
    txn('art.cache', { key, status: 'url', error: String(error) });
  }
  return key;
}

/**
 * Can we fetch this URL cross-origin and draw it to a canvas (→ offline blob)?
 * True for same-origin URLs (root-relative `/art/...` or matching origin — e.g. our
 * CDN behind the same CloudFront) and for known CORS-friendly hosts. `src.cors === true`
 * forces it. Anything else can only be displayed via a live <img src> (online only).
 */
function isSourceCacheable(src: ArtSource): boolean {
  if (src.cors === true) return true;
  if (src.url.startsWith('/')) return true; // root-relative ⇒ same origin as the app
  try {
    const u = new URL(src.url, typeof location !== 'undefined' ? location.href : 'https://x/');
    if (typeof location !== 'undefined' && u.origin === location.origin) return true;
    return isCorsFriendly(src.url);
  } catch {
    return false;
  }
}

/**
 * Progressive cover resolution over an ordered source list (CDN default + remote backup).
 * Tries every CACHEABLE source first (fetch → thumbnail → durable IndexedDB blob, so it
 * survives offline + restart); only if none can be cached does it fall back to displaying
 * the first source's URL directly (online-only). Idempotent: a source list that already
 * resolved to a blob is reused. Keyed by the ordered URLs so re-mirroring (a new CDN
 * source appears) re-caches into a fresh durable blob.
 */
export async function cacheArtSources(sources: ArtSource[]): Promise<string> {
  if (!sources.length) throw new Error('cacheArtSources: empty sources');
  const key = artKeyForUrl(sources.map((s) => `${s.type}:${s.url}`).join('|'));
  const existing = await getArt(key);
  if (existing && existing.status === 'ok') return key; // already a durable blob
  // cacheable sources first (preserve relative order within each group)
  const ordered = sources
    .map((s, i) => ({ s, i, cacheable: isSourceCacheable(s) }))
    .sort((a, b) => Number(b.cacheable) - Number(a.cacheable) || a.i - b.i);
  for (const { s, cacheable } of ordered) {
    if (!cacheable) continue;
    try {
      const res = await fetch(s.url, { mode: 'cors' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const blob = await res.blob();
      const { thumb, w, h } = await toThumb(blob);
      await putArt({ key, thumb, url: s.url, status: 'ok', w, h });
      return key;
    } catch (error) {
      txn('art.cache', { key, source: s.url, miss: String(error) });
    }
  }
  // No cacheable source resolved (e.g. offline at first load, only a remote backup) —
  // keep the first source's URL for direct <img> display when online.
  await putArt({ key, url: sources[0].url, status: 'url' });
  return key;
}

/**
 * Ask the browser to keep our IndexedDB/Cache storage from being evicted under pressure.
 * Important on iOS so cover-art blobs survive app/phone restart. Best-effort + idempotent.
 */
export async function requestPersistentStorage(): Promise<boolean> {
  try {
    if (navigator.storage?.persisted && (await navigator.storage.persisted())) return true;
    if (navigator.storage?.persist) {
      const granted = await navigator.storage.persist();
      txn('storage.persist', { granted });
      return granted;
    }
  } catch {
    /* not supported — ignore */
  }
  return false;
}

/** Deterministic gradient placeholder thumbnail (offline, no network). */
export async function generatePlaceholder(seed: string): Promise<string> {
  const key = placeholderKey(seed);
  const existing = await getArt(key);
  if (existing) return key;

  const rng = seededRng(seed);
  const hue = Math.floor(rng() * 360);
  const hue2 = (hue + 40 + Math.floor(rng() * 120)) % 360;
  const size = THUMB;
  const canvas = new OffscreenCanvas(size, size);
  const ctx = canvas.getContext('2d')!;
  const grad = ctx.createLinearGradient(0, 0, size, size);
  grad.addColorStop(0, `hsl(${hue} 55% 38%)`);
  grad.addColorStop(1, `hsl(${hue2} 50% 18%)`);
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, size, size);
  // a few scattered "stars" so placeholders read as part of the night-sky theme
  ctx.fillStyle = 'rgba(255,255,255,0.55)';
  for (let i = 0; i < 14; i++) {
    const x = rng() * size;
    const y = rng() * size;
    const r = rng() * 1.6 + 0.4;
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fill();
  }
  const thumb = await canvas.convertToBlob({ type: 'image/webp', quality: 0.8 });
  await putArt({ key, thumb, status: 'ok', w: size, h: size });
  txn('art.generate', { key, seed });
  return key;
}

// ---- reference-counted objectURL registry ------------------------------------
// One display URL per art key, SHARED across every surface that renders it (browser
// grid, star-map stars, solar-system sun). A blob URL is created on first acquire and
// revoked only when the LAST consumer releases it — so rendering ~1,361 covers at once
// (the star map) never revokes a URL that's still on screen. This replaced a fixed-size
// LRU (cap 400) that revoked in-use URLs, leaving most star-map covers broken.
// Use the `useArtUrl` hook (components/common/useArtUrl) rather than calling these directly.
type ArtEntry = { url: string; refs: number; blob: boolean };
const registry = new Map<string, ArtEntry>();
const inflight = new Map<string, Promise<ArtEntry | null>>();

async function loadArtEntry(key: string): Promise<ArtEntry | null> {
  const rec: ArtRecord | undefined = await getArt(key);
  // Cached thumbnail blob (CORS-friendly sources + placeholders) -> revocable object URL.
  if (rec?.thumb) return { url: URL.createObjectURL(rec.thumb), refs: 0, blob: true };
  // Un-thumbnailable source we kept as a URL -> display it directly (not revocable).
  if (rec?.url && rec.status === 'url') return { url: rec.url, refs: 0, blob: false };
  return null;
}

/**
 * Acquire the shared display URL for an art key, incrementing its ref count. Every
 * NON-NULL result must be paired with exactly one `releaseArtUrl(key)`. Returns null
 * when the key has no art record (then no ref was taken — do not release).
 */
export async function acquireArtUrl(key: string | undefined): Promise<string | null> {
  if (!key) return null;
  const hit = registry.get(key);
  if (hit) {
    hit.refs++;
    return hit.url;
  }
  let p = inflight.get(key);
  if (!p) {
    p = loadArtEntry(key);
    inflight.set(key, p);
  }
  const loaded = await p;
  inflight.delete(key);
  if (!loaded) return null;
  // Another consumer may have registered this key while we awaited.
  const existing = registry.get(key);
  if (existing) {
    existing.refs++;
    if (loaded.blob && loaded.url !== existing.url) URL.revokeObjectURL(loaded.url);
    return existing.url;
  }
  loaded.refs = 1;
  registry.set(key, loaded);
  return loaded.url;
}

/** Release one reference to an art key's URL; revokes the blob URL when refs reach 0. */
export function releaseArtUrl(key: string | undefined): void {
  if (!key) return;
  const e = registry.get(key);
  if (!e) return;
  if (--e.refs <= 0) {
    if (e.blob) URL.revokeObjectURL(e.url);
    registry.delete(key);
  }
}
