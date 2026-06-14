// Edit any metadata field of an item and persist it. Save -> repo.putItem (emits
// a db.putItem transcript line) -> the browser re-derives. Renders the right
// editor per field type (text / number / mm:ss / checkbox / tag list).
import { useEffect, useState } from 'react';
import type { MusicItem, AlbumItem, SongItem } from '../../types/model';
import { isAlbum } from '../../types/model';
import { getItem, putItem } from '../../storage/repo';
import { Modal } from '../common/Modal';
import { msToClock, clockToMs } from '../../lib/format';

interface Props {
  itemId: string | null;
  onClose: () => void;
  onSaved: () => void;
}

export function EditItemModal({ itemId, onClose, onSaved }: Props) {
  const [item, setItem] = useState<MusicItem | null>(null);

  useEffect(() => {
    let live = true;
    if (itemId) getItem(itemId).then((it) => live && setItem(it ?? null));
    else setItem(null);
    return () => {
      live = false;
    };
  }, [itemId]);

  const open = itemId != null;

  async function save() {
    if (!item) return;
    await putItem(item);
    onSaved();
    onClose();
  }

  function set<T extends MusicItem>(patch: Partial<T>) {
    setItem((prev) => (prev ? ({ ...prev, ...patch } as MusicItem) : prev));
  }

  return (
    <Modal open={open} onClose={onClose} title={item ? `Edit ${item.type}` : 'Edit'} testId="edit-modal">
      {!item ? (
        <p>Loading…</p>
      ) : (
        <div className="pdj-form">
          <Text label="Artist" id="artist" value={item.artist} onChange={(v) => set({ artist: v })} />
          <Text label="Title" id="name" value={item.name} onChange={(v) => set({ name: v })} />
          <Num label="Year" id="year" value={item.year} onChange={(v) => set({ year: v })} />

          {isAlbum(item) ? (
            <AlbumFields album={item} set={set} />
          ) : (
            <SongFields song={item as SongItem} set={set} />
          )}

          <div className="pdj-form__actions">
            <button className="pdj-btn pdj-btn--ghost" data-testid="field-cancel" onClick={onClose}>
              Cancel
            </button>
            <button className="pdj-btn" data-testid="field-save" onClick={save}>
              Save
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}

function AlbumFields({ album, set }: { album: AlbumItem; set: (p: Partial<AlbumItem>) => void }) {
  return (
    <>
      <Text label="Genre" id="genre" value={album.genre} onChange={(v) => set({ genre: v })} />
      <Text label="Country" id="country" value={album.country} onChange={(v) => set({ country: v })} />
      <Text label="File type" id="fileType" value={album.fileType} onChange={(v) => set({ fileType: v as AlbumItem['fileType'] })} />
    </>
  );
}

function SongFields({ song, set }: { song: SongItem; set: (p: Partial<SongItem>) => void }) {
  return (
    <>
      <Num label="Track #" id="trackNumber" value={song.trackNumber} onChange={(v) => set({ trackNumber: v })} />
      <label className="pdj-form__row">
        <span>Length</span>
        <input
          data-testid="field-lengthMs"
          value={msToClock(song.lengthMs)}
          placeholder="m:ss"
          onChange={(e) => set({ lengthMs: clockToMs(e.target.value) })}
        />
      </label>
      <label className="pdj-form__row">
        <span>Explicit</span>
        <input
          type="checkbox"
          data-testid="field-explicit"
          checked={song.explicit}
          onChange={(e) => set({ explicit: e.target.checked })}
        />
      </label>
      <label className="pdj-form__row">
        <span>Sentiment</span>
        <input
          data-testid="field-sentimentKeywords"
          value={song.sentimentKeywords.join(', ')}
          placeholder="comma,separated"
          onChange={(e) => set({ sentimentKeywords: e.target.value.split(',').map((s) => s.trim()).filter(Boolean) })}
        />
      </label>
      <label className="pdj-form__row">
        <span>BPM</span>
        <input
          type="number"
          step="0.1"
          data-testid="field-bpm"
          value={song.bpm ?? ''}
          onChange={(e) => set({ bpm: e.target.value === '' ? null : Number(e.target.value) })}
        />
      </label>
      <Text label="Key" id="key" value={song.key ?? ''} onChange={(v) => set({ key: v || null })} />
      <Text label="Key (Camelot)" id="camelot" value={song.camelot ?? ''} onChange={(v) => set({ camelot: v || null })} />
      <label className="pdj-form__row">
        <span>Lyrics</span>
        <textarea
          data-testid="field-lyrics"
          rows={4}
          value={song.lyrics ?? ''}
          onChange={(e) => set({ lyrics: e.target.value })}
        />
      </label>
    </>
  );
}

function Text({ label, id, value, onChange }: { label: string; id: string; value?: string; onChange: (v: string) => void }) {
  return (
    <label className="pdj-form__row">
      <span>{label}</span>
      <input data-testid={`field-${id}`} value={value ?? ''} onChange={(e) => onChange(e.target.value)} />
    </label>
  );
}

function Num({ label, id, value, onChange }: { label: string; id: string; value?: number; onChange: (v: number | undefined) => void }) {
  return (
    <label className="pdj-form__row">
      <span>{label}</span>
      <input
        data-testid={`field-${id}`}
        type="number"
        value={value ?? ''}
        onChange={(e) => onChange(e.target.value === '' ? undefined : Number(e.target.value))}
      />
    </label>
  );
}
