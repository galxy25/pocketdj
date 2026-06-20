// ▶ Play / ⤓ Download buttons for a song (or album). Shows the live rip phase on the
// button the user clicked (Searching… / Ripping mm:ss / Uploading…), polled from the
// rip server. Cached songs (already in the public S3 manifest) play instantly.
import { useState } from 'react';
import { useRipsStore } from '../../store/useRipsStore';

const clock = (ms?: number) => {
  if (ms == null) return '';
  const s = Math.round(ms / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};

export function RipButtons({ song, compact, playOpts }: { song: { id: string; title: string; artist: string }; compact?: boolean; playOpts?: { startMs?: number | null } }) {
  const job = useRipsStore((s) => s.jobs[song.id]);
  const cached = useRipsStore((s) => !!s.manifest[song.id]);
  const serverOk = useRipsStore((s) => s.serverOk);
  const hasServer = useRipsStore((s) => !!s.serverUrl);
  const play = useRipsStore((s) => s.play);
  const download = useRipsStore((s) => s.download);
  const [busy, setBusy] = useState<null | 'play' | 'download'>(null);

  const active = job && job.phase !== 'ready' && job.phase !== 'error' ? job : null;
  const errored = job?.phase === 'error';
  // can act if it's already ripped, or we have a (reachable) server to rip it
  const canAct = cached || (hasServer && serverOk !== false);

  if (active) {
    const label =
      active.phase === 'queued' ? 'Queued…'
        : active.phase === 'searching' ? 'Searching…'
          : active.phase === 'uploading' ? 'Uploading…'
            : active.phase === 'streaming' ? '● Streaming live'
              : active.progress?.totalMs ? `Ripping ${clock(active.progress.elapsedMs)} / ${clock(active.progress.totalMs)}`
                : 'Ripping…';
    return (
      <span className="pdj-rip pdj-rip--active" data-testid={`rip-status-${song.id}`}>
        <span className="pdj-rip__spin" aria-hidden>⟳</span> {label}
      </span>
    );
  }

  const doPlay = async () => { setBusy('play'); try { await play(song, playOpts); } catch (e) { alert((e as Error).message); } finally { setBusy(null); } };
  const doDownload = async () => { setBusy('download'); try { await download(song); } catch (e) { alert((e as Error).message); } finally { setBusy(null); } };

  return (
    <span className={`pdj-rip ${compact ? 'pdj-rip--compact' : ''}`}>
      <button
        type="button"
        className="pdj-rip__btn"
        data-testid={`rip-play-${song.id}`}
        title={cached ? 'Play' : errored ? 'Retry' : 'Rip & play'}
        disabled={!canAct || busy !== null}
        onClick={doPlay}
      >
        {busy === 'play' ? '…' : errored ? '⚠' : '▶'}
      </button>
      <button
        type="button"
        className="pdj-rip__btn"
        data-testid={`rip-download-${song.id}`}
        title={cached ? 'Download' : 'Rip & download'}
        disabled={!canAct || busy !== null}
        onClick={doDownload}
      >
        {busy === 'download' ? '…' : '⤓'}
      </button>
    </span>
  );
}
