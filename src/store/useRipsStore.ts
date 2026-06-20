// Rip-on-demand client state: the public S3 rips manifest (what's already ripped),
// the iMac rip-server config (base URL + token), per-song job state during a rip,
// and the "now playing" handoff to the mini player.
//
// The manifest is PUBLIC (fetched straight from S3), so we know what's cached even
// when the rip server is offline — the server is only needed to CREATE a rip.
import { create } from 'zustand';
import { zip } from 'fflate';
import { getItem, putItem } from '../storage/repo';
import { useDataStore } from './useDataStore';
import { isSong } from '../types/model';
import { SILENT_MP3 } from '../lib/silentAudio';

const PUBLIC_BASE = 'https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com';
const MANIFEST_URL = `${PUBLIC_BASE}/rips/manifest.json`;
const LS_KEY = 'pdj.rip.v1';

export interface ManifestEntry {
  key: string; ext: string; bytes: number;
  source: 'analog' | 'digital'; albumId?: string;
  startMs?: number | null; durationMs?: number | null; rippedAt: number;
  // background audio analysis (filled after the rip):
  bpm?: number | null; musicalKey?: string | null; camelot?: string | null;
  waveform?: string | null; analyzed?: boolean;
}
export type RipPhase = 'queued' | 'searching' | 'ripping' | 'streaming' | 'uploading' | 'ready' | 'error';
export interface JobView {
  jobId: string | null; songId: string; phase: RipPhase;
  message?: string | null; url?: string | null; error?: string | null;
  streamUrl?: string | null; // relative path to a live progressive MP3 (server tails the in-progress rip)
  progress?: { elapsedMs?: number; totalMs?: number; pct?: number; indeterminate?: boolean };
}
export interface NowPlaying { songId: string; title: string; artist: string; url: string; startMs?: number | null; waveform?: string | null; live?: boolean; }
export interface QueueItem { id: string; title: string; artist: string; }
export interface BulkProgress { done: number; total: number; label: string; }

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
  queue: QueueItem[] | null;       // play-through queue (a setlist)
  queueIndex: number;
  bulk: BulkProgress | null;       // Rip-All / Burn progress
  audioEl: HTMLAudioElement | null; // the shared <audio> (registered by MiniPlayer)

  init: () => Promise<void>;
  /** MiniPlayer registers its <audio> element here so play() can unlock it for iOS. */
  setAudioEl: (el: HTMLAudioElement | null) => void;
  /** Unlock the <audio> element within a user gesture (iOS autoplay). Call on tap. */
  primeAudio: () => void;
  setConfig: (serverUrl: string, token: string) => void;
  checkHealth: () => Promise<boolean>;
  refreshManifest: () => Promise<void>;
  urlFor: (songId: string) => string | null;
  /**
   * Ensure a song is ripped + return a playable URL (polls the server on a miss).
   * With `allowLive`, resolves as soon as a live progressive stream is available
   * (returns the rip server's /stream URL) and keeps polling in the background to
   * swap the manifest to the durable S3 mp3. Without it, waits for the finished mp3.
   */
  ensureUrl: (songId: string, opts?: { allowLive?: boolean }) => Promise<string>;
  play: (song: { id: string; title: string; artist: string }, opts?: { startMs?: number | null }) => Promise<void>;
  download: (song: { id: string; title: string; artist: string }) => Promise<void>;
  setNowPlaying: (n: NowPlaying | null) => void;
  /** Play a setlist start→finish: rips each just-in-time, advances on track end. */
  playQueue: (tracks: QueueItem[], start?: number) => Promise<void>;
  playAt: (i: number) => Promise<void>;
  next: () => void;
  prev: () => void;
  /** Rip every track (queued on the server; rip-ahead while earlier ones play). */
  ripAll: (tracks: QueueItem[]) => Promise<void>;
  /** Burn: rip any missing, then download all tracks as one zip. */
  burn: (name: string, tracks: QueueItem[]) => Promise<void>;
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
    queue: null,
    queueIndex: -1,
    bulk: null,
    audioEl: null,

    init: async () => {
      await get().refreshManifest();
      if (get().serverUrl) await get().checkHealth();
    },
    setAudioEl: (el) => set({ audioEl: el }),
    // iOS Safari only lets an <audio> element play programmatically once it has been
    // play()'d from a user gesture. A live rip's URL resolves seconds after the tap
    // (after polling), so by then the gesture is gone and play() is blocked silently.
    // Priming with a tiny silent clip *inside* the tap unlocks the element for later.
    primeAudio: () => {
      const a = get().audioEl;
      if (!a) return;
      try {
        a.src = SILENT_MP3;
        a.muted = true;
        const p = a.play();
        if (p && typeof p.then === 'function') p.then(() => { a.pause(); a.muted = false; }).catch(() => { a.muted = false; });
        else a.muted = false;
      } catch { /* ignore — best-effort unlock */ }
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
        if (r.ok) {
          const manifest = await r.json();
          set({ manifest });
          void applyAnalysisToCatalog(manifest); // roll bpm/key/camelot into the catalog
        }
      } catch { /* offline — keep whatever we have */ }
    },
    urlFor: (songId) => {
      const e = get().manifest[songId];
      if (e) return `${PUBLIC_BASE}/${e.key}`;
      const j = get().jobs[songId];
      return j?.url || null;
    },
    ensureUrl: async (songId, opts) => {
      const allowLive = !!opts?.allowLive;
      const cached = get().urlFor(songId);
      if (cached) return cached;
      const { serverUrl, token } = get();
      if (!serverUrl) throw new Error('No rip server configured (Settings ▸ Rip server).');
      const liveUrl = () => `${serverUrl}/stream/${encodeURIComponent(songId)}.mp3${token ? `?token=${encodeURIComponent(token)}` : ''}`;
      // After handing back a live URL, keep polling so the manifest swaps to the durable
      // S3 mp3 (seekable + analysed) for the next play.
      const pollToReady = async (jobId: string) => {
        for (let i = 0; i < 1800; i++) {
          await sleep(2000);
          try {
            const jr = await fetch(`${get().serverUrl}/jobs/${jobId}`, { headers: authHeaders(get().token) });
            if (!jr.ok) continue;
            const v: JobView = await jr.json();
            set((st) => ({ jobs: { ...st.jobs, [songId]: v } }));
            if (v.phase === 'ready' && v.url) { await get().refreshManifest(); return; }
            if (v.phase === 'error') return;
          } catch { /* keep trying */ }
        }
      };
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
      if (allowLive && view.streamUrl) { void pollToReady(view.jobId); return liveUrl(); }
      // poll
      for (let i = 0; i < 1800; i++) { // generous cap (~30 min of 1s polls)
        await sleep(1000);
        const jr = await fetch(`${serverUrl}/jobs/${view.jobId}`, { headers: authHeaders(token) });
        if (!jr.ok) continue;
        view = await jr.json();
        set((st) => ({ jobs: { ...st.jobs, [songId]: view } }));
        if (view.phase === 'ready' && view.url) { await get().refreshManifest(); return view.url; }
        if (allowLive && view.streamUrl && view.jobId) { void pollToReady(view.jobId); return liveUrl(); }
        if (view.phase === 'error') throw new Error(view.error || 'rip failed');
      }
      throw new Error('rip timed out');
    },
    play: async (song, opts) => {
      get().primeAudio(); // unlock <audio> within the tap gesture (iOS) before any await
      const url = await get().ensureUrl(song.id, { allowLive: true });
      const live = url.startsWith(`${get().serverUrl}/stream/`);
      const e = get().manifest[song.id];
      const startMs = live ? null : opts && 'startMs' in opts ? opts.startMs ?? null : e?.startMs ?? null;
      // single play clears any setlist queue (no next/prev)
      set({ queue: null, queueIndex: -1, nowPlaying: { songId: song.id, title: song.title, artist: song.artist, url, startMs, live, waveform: live ? null : e?.waveform ? `${PUBLIC_BASE}/${e.waveform}` : null } });
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

    // ---- setlist play-through ----
    playQueue: async (tracks, start = 0) => {
      set({ queue: tracks, queueIndex: -1 });
      await get().playAt(start);
    },
    playAt: async (i) => {
      const q = get().queue;
      if (!q || i < 0 || i >= q.length) return;
      const t = q[i];
      set({ queueIndex: i });
      get().primeAudio(); // unlock <audio> within the tap gesture (iOS) before any await
      const url = await get().ensureUrl(t.id, { allowLive: true });
      const live = url.startsWith(`${get().serverUrl}/stream/`);
      const e = get().manifest[t.id];
      set({ nowPlaying: { songId: t.id, title: t.title, artist: t.artist, url, startMs: live ? null : e?.startMs ?? null, live, waveform: live ? null : e?.waveform ? `${PUBLIC_BASE}/${e.waveform}` : null } });
    },
    next: () => { const { queue, queueIndex } = get(); if (queue && queueIndex + 1 < queue.length) void get().playAt(queueIndex + 1); },
    prev: () => { const { queue, queueIndex } = get(); if (queue && queueIndex > 0) void get().playAt(queueIndex - 1); },

    // ---- bulk: rip all / burn ----
    ripAll: async (tracks) => {
      const list = dedupe(tracks);
      let done = 0;
      set({ bulk: { done, total: list.length, label: 'Ripping' } });
      await Promise.all(list.map((t) =>
        get().ensureUrl(t.id).catch(() => {}).finally(() => { done++; set({ bulk: { done, total: list.length, label: 'Ripping' } }); })));
      set({ bulk: null });
    },
    burn: async (name, tracks) => {
      const list = dedupe(tracks);
      let done = 0;
      set({ bulk: { done, total: list.length, label: 'Burning' } });
      const files: Record<string, Uint8Array> = {};
      for (const t of list) {
        try {
          const url = await get().ensureUrl(t.id);
          const buf = new Uint8Array(await (await fetch(url)).arrayBuffer());
          const fname = `${String(done + 1).padStart(2, '0')} - ${t.artist} - ${t.title}.mp3`.replace(/[/\\?%*:|"<>]/g, '_');
          files[fname] = buf;
        } catch { /* skip a track that can't be ripped */ }
        done++;
        set({ bulk: { done, total: list.length, label: 'Burning' } });
      }
      const data: Uint8Array = await new Promise((res, rej) => zip(files, { level: 0 }, (err, d) => (err ? rej(err) : res(d))));
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([data.buffer as ArrayBuffer], { type: 'application/zip' }));
      a.download = `${name}.zip`.replace(/[/\\?%*:|"<>]/g, '_');
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 30_000);
      set({ bulk: null });
    },
  };
});

/** Unique tracks by id, preserving order. */
function dedupe(tracks: QueueItem[]): QueueItem[] {
  const seen = new Set<string>();
  return tracks.filter((t) => t.id && !seen.has(t.id) && seen.add(t.id));
}

/**
 * Roll the rip analysis (bpm/key/camelot) into the catalog: patch IndexedDB song
 * items so the data shows up in the default index — filterable, sortable, on the
 * star map, in song detail. Only fills from entries that carry analysis; never
 * overwrites an existing value with null. Reloads the browser once if anything
 * changed. Runs in the background after the manifest loads.
 */
async function applyAnalysisToCatalog(manifest: Record<string, ManifestEntry>): Promise<void> {
  let patched = 0;
  for (const [songId, e] of Object.entries(manifest)) {
    if (e.bpm == null && !e.musicalKey && !e.camelot) continue;
    try {
      const it = await getItem(songId);
      if (!it || !isSong(it)) continue;
      // FILL gaps only — never clobber existing catalog values (analog songs already
      // carry accurate audio-stage bpm/key; digital songs are null and get filled).
      const bpm = it.bpm ?? e.bpm ?? null;
      const key = it.key ?? e.musicalKey ?? null;
      const camelot = it.camelot ?? e.camelot ?? null;
      if (it.bpm !== bpm || it.key !== key || it.camelot !== camelot) {
        await putItem({ ...it, bpm, key, camelot });
        patched++;
      }
    } catch { /* ignore one bad item */ }
  }
  if (patched) void useDataStore.getState().reload();
}
