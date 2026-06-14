// Album AUDIO metadata table — the per-segment ground truth from the analog-indexer
// audio stage (track #, start–end, BPM, key/Camelot). Shared by the solar-system
// sun-click popup (AudioTracksModal) and the single-album browser table footer.
// IMPORTANT: the audio segmentation is INDEPENDENT of the metadata tracklist, so the
// row count may differ from the song list by design — never zip 1:1 against songs.
import type { AlbumItem } from '../../types/model';
import { msToClock } from '../../lib/format';

export function AudioTracksTable({ album }: { album: AlbumItem }) {
  const tracks = album.audioTracks;
  if (!tracks || tracks.length === 0) {
    return (
      <div className="pdj-audiotracks__empty" data-testid="audio-tracks-empty">
        No audio analysis yet.
      </div>
    );
  }
  return (
    <div className="pdj-audiotracks" data-testid="audio-tracks">
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
        {album.audioDurationSec != null && ` Total analyzed: ${msToClock(album.audioDurationSec * 1000)}.`}
      </p>
    </div>
  );
}
