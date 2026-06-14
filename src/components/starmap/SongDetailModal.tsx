// Song metadata popup shown when a planet (song) is clicked in the solar system.
// Reuses the shared Modal, which provides the top-right ✕, Escape, and backdrop
// close. Read-only view of everything we know about the song.
import type { ReactNode } from 'react';
import type { SongItem } from '../../types/model';
import { Modal } from '../common/Modal';
import { msToClock } from '../../lib/format';

interface Props {
  song: SongItem | null;
  albumName: string;
  onClose: () => void;
}

export function SongDetailModal({ song, albumName, onClose }: Props) {
  return (
    <Modal open={song != null} onClose={onClose} title={song ? song.name : 'Song'} testId="song-modal">
      {song && (
        <div className="pdj-songdetail" data-testid="song-detail">
          <Row label="Track">{song.trackNumber ?? '—'}</Row>
          <Row label="Artist">{song.artist}</Row>
          <Row label="Album">{albumName}</Row>
          <Row label="Year">{song.year ?? '—'}</Row>
          <Row label="Length">{msToClock(song.lengthMs) || '—'}</Row>
          <Row label="Explicit">{song.explicit ? 'Yes' : 'No'}</Row>
          <Row label="BPM">{song.bpm ?? '— (pending audio)'}</Row>
          <Row label="Key">{song.key ?? '— (pending audio)'}</Row>
          <Row label="Camelot">{song.camelot ?? '— (pending audio)'}</Row>
          <Row label="Sentiment">
            {song.sentimentKeywords.length ? (
              <span className="pdj-songdetail__tags">
                {song.sentimentKeywords.map((k) => (
                  <span key={k} className="pdj-tag">
                    {k}
                  </span>
                ))}
              </span>
            ) : (
              '—'
            )}
          </Row>
          {song.pointer && (
            <Row label="Plug in">
              <span className="pdj-songdetail__plug">
                {song.pointer.location && <>📦 {song.pointer.location} </>}
                {song.pointer.disc != null && <>· disc {song.pointer.disc} </>}
                {song.pointer.track != null && <>· track {song.pointer.track}</>}
                {song.pointer.filename && (
                  <>
                    <br />
                    <code>{song.pointer.filename}</code>
                  </>
                )}
              </span>
            </Row>
          )}
          {song.lyrics ? (
            <div className="pdj-songdetail__lyrics">
              <div className="pdj-songdetail__lyrics-head">Lyrics</div>
              <pre>{song.lyrics}</pre>
            </div>
          ) : (
            <Row label="Lyrics">{song.lyricsStatus === 'notfound' ? 'Not found' : '—'}</Row>
          )}
          <button
            type="button"
            className="pdj-songdetail__close"
            data-testid="song-detail-close"
            onClick={onClose}
          >
            Close
          </button>
        </div>
      )}
    </Modal>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="pdj-songdetail__row">
      <span className="pdj-songdetail__label">{label}</span>
      <span className="pdj-songdetail__value">{children}</span>
    </div>
  );
}
