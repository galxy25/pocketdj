// Bottom-bar mini player. Plays the "now playing" rip (a public S3 mp3, or a live
// progressive stream while a rip is still capturing). For analog tracks it auto-seeks
// to the track's startMs within the whole-album file (the user can still scrub freely).
// Mounted once in AppShell. The <audio> element is ALWAYS mounted (even with nothing
// playing) and registered to the store, so a user tap can unlock it for iOS autoplay
// before the live URL resolves.
import { useEffect, useRef, useState } from 'react';
import type { MouseEvent } from 'react';
import type HlsJs from 'hls.js';
import { useRipsStore } from '../../store/useRipsStore';

const clock = (s: number) => (isFinite(s) ? `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}` : '0:00');

export function MiniPlayer() {
  const now = useRipsStore((s) => s.nowPlaying);
  const setNow = useRipsStore((s) => s.setNowPlaying);
  const setAudioEl = useRipsStore((s) => s.setAudioEl);
  const queue = useRipsStore((s) => s.queue);
  const queueIndex = useRipsStore((s) => s.queueIndex);
  const next = useRipsStore((s) => s.next);
  const prev = useRipsStore((s) => s.prev);
  const hasQueue = !!queue && queue.length > 1;
  const audioRef = useRef<HTMLAudioElement>(null);
  const hlsRef = useRef<HlsJs | null>(null);
  const [playing, setPlaying] = useState(false);
  const [t, setT] = useState(0);
  const [dur, setDur] = useState(0);

  // register the (always-mounted) <audio> element so play() can prime/unlock it on tap
  useEffect(() => {
    setAudioEl(audioRef.current);
    return () => setAudioEl(null);
  }, [setAudioEl]);

  // load + start whenever the track changes
  useEffect(() => {
    const a = audioRef.current;
    if (!a || !now) return;
    a.muted = false; // prime() may have left it muted mid-unlock
    if (hlsRef.current) { hlsRef.current.destroy(); hlsRef.current = null; } // tear down prior hls.js

    let cancelled = false;
    // hls.js path: lazy-loaded so Safari/iOS (native HLS) never download it.
    const loadViaHlsJs = () => {
      void import('hls.js').then(({ default: Hls }) => {
        if (cancelled || !audioRef.current || !Hls.isSupported()) return;
        const hls = new Hls({ enableWorker: true, lowLatencyMode: true });
        hlsRef.current = hls;
        hls.loadSource(now.url);
        hls.attachMedia(audioRef.current);
        hls.on(Hls.Events.MANIFEST_PARSED, () => { void audioRef.current?.play().catch(() => {}); });
      }).catch(() => {});
    };

    if (now.url.includes('.m3u8')) {
      // Native HLS (iOS/Safari) is preferred when REAL. canPlayType can lie (some
      // Chromium claim HLS support but can't actually play it), so try native and fall
      // back to hls.js on a source error. Browsers with no native HLS go straight to it.
      if (a.canPlayType('application/vnd.apple.mpegurl')) {
        const onErr = () => { if (!a.error || a.error.code === a.error.MEDIA_ERR_SRC_NOT_SUPPORTED) loadViaHlsJs(); };
        a.addEventListener('error', onErr, { once: true });
        a.src = now.url; a.load(); void a.play().catch(() => {});
        return () => { cancelled = true; a.removeEventListener('error', onErr); if (hlsRef.current) { hlsRef.current.destroy(); hlsRef.current = null; } };
      }
      loadViaHlsJs();
      return () => { cancelled = true; if (hlsRef.current) { hlsRef.current.destroy(); hlsRef.current = null; } };
    }

    // plain mp3 (a ready S3 rip, or analog)
    a.src = now.url;
    a.load();
    if (now.live) {
      void a.play().catch(() => {}); // live: no metadata/seek to wait on — start now
      return;
    }
    const onMeta = () => {
      if (now.startMs && isFinite(a.duration)) a.currentTime = Math.min(now.startMs / 1000, a.duration - 0.1);
      void a.play().catch(() => {});
    };
    a.addEventListener('loadedmetadata', onMeta, { once: true });
    return () => a.removeEventListener('loadedmetadata', onMeta);
  }, [now]);

  const a = audioRef.current;
  const toggle = () => { if (!a) return; if (a.paused) void a.play(); else a.pause(); };
  const seek = (v: number) => { if (a) a.currentTime = v; };
  const pct = dur ? Math.min(100, (t / dur) * 100) : 0;
  const seekFromClick = (e: MouseEvent<HTMLDivElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    seek(((e.clientX - r.left) / r.width) * (dur || 0));
  };

  return (
    <>
      <audio
        ref={audioRef}
        playsInline
        preload="auto"
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onTimeUpdate={(e) => setT(e.currentTarget.currentTime)}
        onDurationChange={(e) => setDur(e.currentTarget.duration)}
        onEnded={() => { setPlaying(false); if (hasQueue) next(); }}
      />
      {now && (
        <div className="pdj-player" data-testid="mini-player">
          {hasQueue && (
            <button type="button" className="pdj-player__btn" data-testid="player-prev" onClick={prev} disabled={queueIndex <= 0} aria-label="Previous">⏮</button>
          )}
          <button type="button" className="pdj-player__btn" data-testid="player-toggle" onClick={toggle} aria-label={playing ? 'Pause' : 'Play'}>
            {playing ? '⏸' : '▶'}
          </button>
          {hasQueue && (
            <button type="button" className="pdj-player__btn" data-testid="player-next" onClick={next} disabled={queueIndex >= (queue!.length - 1)} aria-label="Next">⏭</button>
          )}
          <div className="pdj-player__meta">
            <div className="pdj-player__title" title={`${now.artist} — ${now.title}`}>{now.title}</div>
            <div className="pdj-player__artist">{now.artist}</div>
          </div>
          <span className="pdj-player__time">{clock(t)}</span>
          {now.live ? (
            // a live progressive stream can't seek past the buffered edge — show a LIVE tag
            <span className="pdj-player__live" data-testid="player-live" title="Streaming live as it rips">● LIVE</span>
          ) : now.waveform ? (
            <div className="pdj-player__wave" data-testid="player-wave" onClick={seekFromClick} title="Scrub">
              <img className="pdj-player__wave-img" src={now.waveform} alt="waveform" loading="lazy" />
              <div className="pdj-player__wave-played" style={{ width: `${pct}%` }} />
              <div className="pdj-player__wave-head" style={{ left: `${pct}%` }} />
            </div>
          ) : (
            <input
              className="pdj-player__seek"
              type="range" min={0} max={dur || 0} step={0.5} value={t}
              data-testid="player-seek"
              onChange={(e) => seek(Number(e.target.value))}
            />
          )}
          {!now.live && <span className="pdj-player__time">{clock(dur)}</span>}
          <button type="button" className="pdj-player__btn" data-testid="player-close" onClick={() => { a?.pause(); setNow(null); }} aria-label="Close">✕</button>
        </div>
      )}
    </>
  );
}
