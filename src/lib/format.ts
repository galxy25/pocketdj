// Display formatting helpers. Storage is always canonical (ms, number); format
// only at the edge.

/** 286000 -> "4:46"; null/undefined -> "". */
export function msToClock(ms?: number | null): string {
  if (ms == null || !isFinite(ms)) return '';
  const total = Math.round(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}

/** "4:46" or "286" (seconds) or "286000" (ms-ish) -> ms. Best-effort parse for edit fields. */
export function clockToMs(text: string): number | undefined {
  const t = text.trim();
  if (!t) return undefined;
  if (t.includes(':')) {
    const [m, s] = t.split(':');
    const mins = parseInt(m, 10) || 0;
    const secs = parseInt(s, 10) || 0;
    return (mins * 60 + secs) * 1000;
  }
  const n = Number(t);
  if (!isFinite(n)) return undefined;
  // Heuristic: large numbers are already ms, small are seconds.
  return n > 6000 ? Math.round(n) : Math.round(n * 1000);
}

/** Truncate with ellipsis. */
export function truncate(s: string, n: number): string {
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
}
