import { useEffect, useState } from 'react';
import { acquireArtUrl, releaseArtUrl } from '../../storage/artCache';

/**
 * Resolve an art-cache key to a shared, reference-counted display URL — an IndexedDB
 * thumbnail blob (offline-durable) or a remote URL for un-thumbnailable sources. This is
 * the SINGLE image-loading path for every surface (browser grid, star-map stars, solar
 * system), so a cover is decoded once and the URL lives exactly as long as something is
 * rendering it. Returns null until resolved, or when no key is given.
 */
export function useArtUrl(key?: string): string | null {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    if (!key) {
      setUrl(null);
      return;
    }
    let cancelled = false;
    let held = false; // did we take a ref that must be released?
    acquireArtUrl(key).then((u) => {
      held = u != null;
      if (cancelled) {
        if (held) releaseArtUrl(key);
        return;
      }
      setUrl(u);
    });
    return () => {
      cancelled = true;
      setUrl(null);
      if (held) releaseArtUrl(key);
    };
  }, [key]);
  return url;
}
