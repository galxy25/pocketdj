// Edit an album's AUDIO analysis (the per-segment ground truth): start/end, BPM, and
// key (musical + Camelot, valid values only, auto-linked). Saving recomputes each
// segment's duration + the album's audio rollup (median BPM, dominant key/Camelot) and
// persists. Opened from the audio footer of the single-album browser view.
import { useEffect, useState } from 'react';
import type { AlbumItem, AudioTrack } from '../../types/model';
import { putItem } from '../../storage/repo';
import { audioRollup } from '../../storage/importIndex';
import { Modal } from '../common/Modal';
import { msToClock, clockToMs } from '../../lib/format';
import { MUSICAL_KEYS, CAMELOT_KEYS, keyToCamelot, camelotToKey } from '../../lib/camelot';

interface Props {
  album: AlbumItem | null;
  open: boolean;
  onClose: () => void;
  onSaved: () => void;
}

export function AudioEditModal({ album, open, onClose, onSaved }: Props) {
  const [rows, setRows] = useState<AudioTrack[]>([]);
  useEffect(() => {
    setRows(album?.audioTracks ? album.audioTracks.map((t) => ({ ...t })) : []);
  }, [album, open]);

  function patch(i: number, p: Partial<AudioTrack>) {
    setRows((prev) => prev.map((r, idx) => (idx === i ? { ...r, ...p } : r)));
  }

  async function save() {
    if (!album) return;
    const tracks: AudioTrack[] = rows.map((r) => ({ ...r, durationMs: Math.max(0, (r.endMs || 0) - (r.startMs || 0)) }));
    const rollup = audioRollup(tracks);
    await putItem({ ...album, audioTracks: tracks, audioBpm: rollup.audioBpm, audioCamelot: rollup.audioCamelot, audioKey: rollup.audioKey });
    onSaved();
    onClose();
  }

  return (
    <Modal open={open} onClose={onClose} title={album ? `Edit audio — ${album.name}` : 'Edit audio'} testId="audio-edit-modal">
      {!album ? null : rows.length === 0 ? (
        <p className="pdj-audiotracks__empty">No audio analysis to edit.</p>
      ) : (
        <div className="pdj-audioedit">
          {rows.map((r, i) => (
            <div className="pdj-audioedit__row" key={i} data-testid="audio-edit-row">
              <span className="pdj-audioedit__num">{r.trackNumber}</span>
              <label>
                <span>Start</span>
                <input data-testid="ae-start" value={msToClock(r.startMs)} onChange={(e) => patch(i, { startMs: clockToMs(e.target.value) })} />
              </label>
              <label>
                <span>End</span>
                <input data-testid="ae-end" value={msToClock(r.endMs)} onChange={(e) => patch(i, { endMs: clockToMs(e.target.value) })} />
              </label>
              <label>
                <span>BPM</span>
                <input
                  type="number"
                  step="0.1"
                  data-testid="ae-bpm"
                  value={r.bpm ?? ''}
                  onChange={(e) => patch(i, { bpm: e.target.value === '' ? 0 : Number(e.target.value) })}
                />
              </label>
              <label>
                <span>Key</span>
                <select
                  data-testid="ae-key"
                  value={r.key ?? ''}
                  onChange={(e) => {
                    const k = e.target.value;
                    patch(i, { key: k, camelot: k ? keyToCamelot(k) ?? r.camelot : r.camelot });
                  }}
                >
                  <option value="">—</option>
                  {(r.key && !MUSICAL_KEYS.includes(r.key) ? [r.key, ...MUSICAL_KEYS] : MUSICAL_KEYS).map((k) => (
                    <option key={k} value={k}>
                      {k}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span>Camelot</span>
                <select
                  data-testid="ae-camelot"
                  value={r.camelot ?? ''}
                  onChange={(e) => {
                    const c = e.target.value;
                    patch(i, { camelot: c, key: c ? camelotToKey(c) ?? r.key : r.key });
                  }}
                >
                  <option value="">—</option>
                  {(r.camelot && !CAMELOT_KEYS.includes(r.camelot) ? [r.camelot, ...CAMELOT_KEYS] : CAMELOT_KEYS).map((c) => (
                    <option key={c} value={c}>
                      {c}
                    </option>
                  ))}
                </select>
              </label>
            </div>
          ))}
          <div className="pdj-form__actions">
            <button className="pdj-btn pdj-btn--ghost" data-testid="audio-edit-cancel" onClick={onClose}>
              Cancel
            </button>
            <button className="pdj-btn" data-testid="audio-edit-save" onClick={save}>
              Save
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}
