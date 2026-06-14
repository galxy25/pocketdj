// Cover-art caching: download real cover URLs into IndexedDB thumbnail blobs
// (offline-first), or generate deterministic procedural placeholders for mock /
// missing art. Rendering uses an in-memory objectURL LRU so 1,366 stars don't
// pin a bitmap each.
import { getArt, putArt } from './repo';
import type { ArtRecord } from './db';
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

// ---- objectURL LRU for rendering ----
const MAX_LIVE = 400;
const live = new Map<string, string>(); // key -> objectURL (insertion-ordered LRU)

export async function artObjectURL(key: string | undefined): Promise<string | null> {
  if (!key) return null;
  const cached = live.get(key);
  if (cached) {
    // refresh LRU position
    live.delete(key);
    live.set(key, cached);
    return cached;
  }
  const rec: ArtRecord | undefined = await getArt(key);
  // Cached thumbnail blob (CORS-friendly sources + placeholders) -> object URL.
  if (rec?.thumb) {
    const url = URL.createObjectURL(rec.thumb);
    live.set(key, url);
    if (live.size > MAX_LIVE) {
      const oldest = live.keys().next().value as string | undefined;
      if (oldest) {
        const u = live.get(oldest)!;
        if (u.startsWith('blob:')) URL.revokeObjectURL(u);
        live.delete(oldest);
      }
    }
    return url;
  }
  // CORS-blocked source we couldn't thumbnail -> display the remote URL directly.
  if (rec?.url && rec.status === 'url') {
    live.set(key, rec.url);
    return rec.url;
  }
  return null;
}

/** Release all object URLs (e.g. on unmount of a big view). */
export function releaseArtURLs(): void {
  for (const u of live.values()) URL.revokeObjectURL(u);
  live.clear();
}
