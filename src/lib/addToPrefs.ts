// Remembers the last "Add to…" choice so the picker can default to it next time:
// the last playlist + the sequence chosen within each playlist, and the last
// pocket. Persisted to localStorage (best-effort; ignores quota/privacy errors).
const KEY = 'pdj.addToPrefs.v1';

export interface AddToPrefs {
  playlistId?: string;
  pocketId?: string;
  /** Last sequence chosen per playlist id. */
  sequenceByPlaylist?: Record<string, string>;
}

export function loadAddToPrefs(): AddToPrefs {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as AddToPrefs) : {};
  } catch {
    return {};
  }
}

function save(p: AddToPrefs): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(p));
  } catch {
    /* ignore */
  }
}

export function rememberPlaylist(playlistId: string, sequenceNodeId?: string): void {
  const p = loadAddToPrefs();
  p.playlistId = playlistId;
  if (sequenceNodeId) {
    p.sequenceByPlaylist = { ...(p.sequenceByPlaylist ?? {}), [playlistId]: sequenceNodeId };
  }
  save(p);
}

export function rememberPocket(pocketId: string): void {
  const p = loadAddToPrefs();
  p.pocketId = pocketId;
  save(p);
}

/** Stable sort putting the remembered id first (used to surface the last choice). */
export function lastFirst<T extends { id: string }>(list: T[], lastId?: string): T[] {
  if (!lastId) return list;
  const idx = list.findIndex((x) => x.id === lastId);
  if (idx <= 0) return list;
  return [list[idx], ...list.slice(0, idx), ...list.slice(idx + 1)];
}
