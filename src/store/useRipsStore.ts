// Rip-on-demand client state: the public S3 rips manifest (what's already ripped),
// the iMac rip-server config (base URL + token), per-song job state during a rip,
// and the "now playing" handoff to the mini player.
//
// The manifest is PUBLIC (fetched straight from S3), so we know what's cached even
// when the rip server is offline — the server is only needed to CREATE a rip.
import { create } from 'zustand';

const PUBLIC_BASE = 'https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com';
const MANIFEST_URL = `${PUBLIC_BASE}/rips/manifest.json`;
const LS_KEY = 'pdj.rip.v1';

export interface ManifestEntry {
  key: string; ext: string; bytes: number;
  source: 'analog' | 'digital'; albumId?: string;
  startMs?: number | null; durationMs?: number | null; rippedAt: number;
}
export type RipPhase = 'queued' | 'searching' | 'ripping' | 'uploading' | 'ready' | 'error';
export interface JobView {
  jobId: string | null; songId: string; phase: RipPhase;
  message?: string | null; url?: string | null; error?: string | null;
  progress?: { elapsedMs?: number; totalMs?: number; pct?: number; indeterminate?: boolean };
}
export interface NowPlaying { songId: string; title: string; artist: string; url: string; startMs?: number | null; }

interface Persisted { serverUrl: string; token: string; }
function load(): Persisted {
  try { const v = JSON.parse(localStorage.getItem(LS_KEY) || '{}'); return { serverUrl: v.serverUrl || '', token: v.token || '' }; }
  catch { return { serverUrl: '', token: '' }; }
}
function save(p: Persisted) { try { localStorage.setItem(LS_KEY, JSON.stringify(p)); } catch { /* ignore */ } }

const authHeaders = (token: string): Record<string, string> => (token ? { Authorization: `Bearer ${token}` } : {});
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface RipState {
  serverUrl: string;
  token: string;
  serverOk: boolean | null;        // null = unknown / not checked
  serverInfo: { catalog?: { songs: number; albums: number }; cached?: number } | null;
  manifest: Record<string, ManifestEntry>;
  jobs: Record<string, JobView>;   // keyed by songId, active/last rip
  nowPlaying: NowPlaying | null;

  init: () => Promise<void>;
  setConfig: (serverUrl: string, token: string) => void;
  checkHealth: () => Promise<boolean>;
  refreshManifest: () => Promise<void>;
  urlFor: (songId: string) => string | null;
  /** Ensure a song is ripped + return its public URL (polls the server on a miss). */
  ensureUrl: (songId: string) => Promise<string>;
  play: (song: { id: string; title: string; artist: string }, opts?: { startMs?: number | null }) => Promise<void>;
  download: (song: { id: string; title: string; artist: string }) => Promise<void>;
  setNowPlaying: (n: NowPlaying | null) => void;
}

export const useRipsStore = create<RipState>((set, get) => {
  const init0 = load();
  return {
    serverUrl: init0.serverUrl,
    token: init0.token,
    serverOk: null,
    serverInfo: null,
    manifest: {},
    jobs: {},
    nowPlaying: null,

    init: async () => {
      await get().refreshManifest();
      if (get().serverUrl) await get().checkHealth();
    },
    setConfig: (serverUrl, token) => {
      const s = serverUrl.trim().replace(/\/$/, '');
      save({ serverUrl: s, token: token.trim() });
      set({ serverUrl: s, token: token.trim(), serverOk: null, serverInfo: null });
      if (s) void get().checkHealth();
    },
    checkHealth: async () => {
      const { serverUrl, token } = get();
      if (!serverUrl) { set({ serverOk: false, serverInfo: null }); return false; }
      try {
        const r = await fetch(`${serverUrl}/health`, { headers: authHeaders(token) });
        const ok = r.ok;
        const info = ok ? await r.json() : null;
        set({ serverOk: ok, serverInfo: info });
        return ok;
      } catch { set({ serverOk: false, serverInfo: null }); return false; }
    },
    refreshManifest: async () => {
      try {
        const r = await fetch(`${MANIFEST_URL}?t=${Date.now()}`, { cache: 'no-store' });
        if (r.ok) set({ manifest: await r.json() });
      } catch { /* offline — keep whatever we have */ }
    },
    urlFor: (songId) => {
      const e = get().manifest[songId];
      if (e) return `${PUBLIC_BASE}/${e.key}`;
      const j = get().jobs[songId];
      return j?.url || null;
    },
    ensureUrl: async (songId) => {
      const cached = get().urlFor(songId);
      if (cached) return cached;
      const { serverUrl, token } = get();
      if (!serverUrl) throw new Error('No rip server configured (Settings ▸ Rip server).');
      // kick off (or join) a job
      const res = await fetch(`${serverUrl}/rip`, {
        method: 'POST', headers: { 'content-type': 'application/json', ...authHeaders(token) },
        body: JSON.stringify({ songId }),
      });
      if (!res.ok) throw new Error(`rip failed (${res.status})`);
      let view: JobView = await res.json();
      set((st) => ({ jobs: { ...st.jobs, [songId]: view } }));
      if (view.phase === 'ready' && view.url) { await get().refreshManifest(); return view.url; }
      if (!view.jobId) throw new Error(view.error || 'rip did not start');
      // poll
      for (let i = 0; i < 1800; i++) { // generous cap (~30 min of 1s polls)
        await sleep(1000);
        const jr = await fetch(`${serverUrl}/jobs/${view.jobId}`, { headers: authHeaders(token) });
        if (!jr.ok) continue;
        view = await jr.json();
        set((st) => ({ jobs: { ...st.jobs, [songId]: view } }));
        if (view.phase === 'ready' && view.url) { await get().refreshManifest(); return view.url; }
        if (view.phase === 'error') throw new Error(view.error || 'rip failed');
      }
      throw new Error('rip timed out');
    },
    play: async (song, opts) => {
      const url = await get().ensureUrl(song.id);
      const e = get().manifest[song.id];
      const startMs = opts && 'startMs' in opts ? opts.startMs ?? null : e?.startMs ?? null;
      set({ nowPlaying: { songId: song.id, title: song.title, artist: song.artist, url, startMs } });
    },
    download: async (song) => {
      const url = await get().ensureUrl(song.id);
      const blob = await (await fetch(url)).blob();
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `${song.artist} - ${song.title}.mp3`.replace(/[/\\?%*:|"<>]/g, '_');
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
    },
    setNowPlaying: (n) => set({ nowPlaying: n }),
  };
});
