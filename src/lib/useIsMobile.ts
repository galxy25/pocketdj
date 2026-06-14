import { useEffect, useState } from 'react';

/** True on narrow (phone) viewports. Matches the app's 680px mobile breakpoint. */
export function useIsMobile(maxWidth = 680): boolean {
  const query = `(max-width:${maxWidth}px)`;
  const [mobile, setMobile] = useState(
    () => typeof window !== 'undefined' && window.matchMedia(query).matches,
  );
  useEffect(() => {
    const mq = window.matchMedia(query);
    const on = () => setMobile(mq.matches);
    on();
    mq.addEventListener('change', on);
    return () => mq.removeEventListener('change', on);
  }, [query]);
  return mobile;
}
