// Album AUDIO track-by-track popup, shown when the central "sun" (album cover) is
// clicked in the solar system. Reuses the shared Modal (top-right ✕, Escape,
// backdrop close). Renders album.audioTracks AS-IS — the AUDIO ground truth from
// the analog-indexer audio stage. IMPORTANT: this segmentation is independent of
// the metadata tracklist, so the row count may differ from the song list by
// design; we never zip 1:1 against songs here.
import type { AlbumItem } from '../../types/model';
import { Modal } from '../common/Modal';
import { msToClock } from '../../lib/format';

interface Props {
  album: AlbumItem | null;
  open: boolean;
  onClose: () => void;
}

export function AudioTracksModal({ album, open, onClose }: Props) {
  const tracks = album?.audioTracks;
  const title = album ? `${album.name} — Audio` : 'Audio';

  return (
    <Modal open={open} onClose={onClose} title={title} testId="audio-tracks-modal">
      {album && (
        <div className="pdj-audiotracks" data-testid="audio-tracks">
          {tracks && tracks.length > 0 ? (
            <>
              <table className="pdj-audiotracks__table">
                <thead>
                  <tr>
                    <th>#</th>
                    <th>Start–End</th>
                    <th>BPM</th>
                    <th>Key</th>
                  </tr>
                </thead>
                <tbody>
                  {tracks.map((t) => (
                    <tr key={t.trackNumber} data-testid="audio-track-row">
                      <td className="pdj-audiotracks__num">{t.trackNumber}</td>
                      <td className="pdj-audiotracks__time">
                        {msToClock(t.startMs) || '—'}–{msToClock(t.endMs) || '—'}
                      </td>
                      <td className="pdj-audiotracks__bpm">{Number.isFinite(t.bpm) ? Math.round(t.bpm) : '—'}</td>
                      <td className="pdj-audiotracks__key">
                        <span className="pdj-audiotracks__keyname">{t.key || '—'}</span>
                        {t.camelot && <span className="pdj-tag pdj-audiotracks__camelot">{t.camelot}</span>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <p className="pdj-audiotracks__caption">
                AUDIO analysis (independent segmentation) — may differ from the tracklist.
                {album.audioDurationSec != null &&
                  ` Total analyzed: ${msToClock(album.audioDurationSec * 1000)}.`}
              </p>
            </>
          ) : (
            <div className="pdj-audiotracks__empty" data-testid="audio-tracks-empty">
              No audio analysis yet.
            </div>
          )}
        </div>
      )}
    </Modal>
  );
}
