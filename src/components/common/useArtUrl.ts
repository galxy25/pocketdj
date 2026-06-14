import { useEffect, useState } from 'react';
import { acquireArtUrl, releaseArtUrl, subscribeArt } from '../../storage/artCache';

/**
 * Resolve an art-cache key to a shared, reference-counted display URL — an IndexedDB
 * thumbnail blob (offline-durable) or a remote URL for un-thumbnailable sources. This is
 * the SINGLE image-loading path for every surface (browser grid, star-map stars, solar
 * system), so a cover is decoded once and the URL lives exactly as long as something is
 * rendering it.
 *
 * Progressive: if the thumbnail isn't cached yet (the background warm pass hasn't reached
 * it), this returns null (placeholder) but subscribes — when the cover lands it re-acquires
 * and pops in. So the UI is interactive immediately and fills in over time.
 */
export function useArtUrl(key?: string): string | null {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    if (!key) {
      setUrl(null);
      return;
    }
    let cancelled = false;
    let done = false; // got a URL + took our single ref
    let unsubscribe = () => {};
    const tryAcquire = () => {
      if (done) return;
      acquireArtUrl(key).then((u) => {
        if (cancelled || !u) {
          if (u) releaseArtUrl(key); // cancelled mid-flight, or lost a race — release
          return;
        }
        if (done) {
          releaseArtUrl(key); // another tryAcquire already won — drop this extra ref
          return;
        }
        done = true;
        setUrl(u);
        unsubscribe(); // no need to listen once resolved
      });
    };
    // listen first so a notify between acquire-miss and subscribe isn't lost
    unsubscribe = subscribeArt(key, tryAcquire);
    tryAcquire();
    return () => {
      cancelled = true;
      unsubscribe();
      setUrl(null);
      if (done) releaseArtUrl(key);
    };
  }, [key]);
  return url;
}
