// Edit any metadata field of an item and persist it. Save -> repo.putItem (emits
// a db.putItem transcript line) -> the browser re-derives. Renders the right
// editor per field type (text / number / mm:ss / checkbox / tag list).
import { useEffect, useRef, useState } from 'react';
import type { MusicItem, AlbumItem, SongItem } from '../../types/model';
import { isAlbum } from '../../types/model';
import { getItem, putItem } from '../../storage/repo';
import { artKeyFor, cacheArtUrl, generatePlaceholder } from '../../storage/artCache';
import { Modal } from '../common/Modal';
import { msToClock, clockToMs } from '../../lib/format';
import { CATEGORY_NAMES } from '../../starmap/constellationMap';
import { MUSICAL_KEYS, CAMELOT_KEYS, keyToCamelot, camelotToKey } from '../../lib/camelot';

interface Props {
  itemId: string | null;
  onClose: () => void;
  onSaved: () => void;
}

export function EditItemModal({ itemId, onClose, onSaved }: Props) {
  const [item, setItem] = useState<MusicItem | null>(null);
  const origCover = useRef<string>('');

  useEffect(() => {
    let live = true;
    if (itemId)
      getItem(itemId).then((it) => {
        if (!live) return;
        setItem(it ?? null);
        origCover.current = it && isAlbum(it) ? it.coverArtUrl ?? '' : '';
      });
    else setItem(null);
    return () => {
      live = false;
    };
  }, [itemId]);

  const open = itemId != null;

  async function save() {
    if (!item) return;
    let toSave: MusicItem = item;
    if (isAlbum(item)) {
      const url = (item.coverArtUrl ?? '').trim();
      // Only rebuild the cover when the URL actually changed — otherwise we'd drop the
      // offline-durable CDN mirror. On change: point at the new URL, re-derive the key,
      // and warm it so it displays.
      if (url !== origCover.current.trim()) {
        const sources = url ? [{ type: 'remote' as const, url }] : undefined;
        const a: AlbumItem = { ...item, coverArtUrl: url || undefined, coverArtSources: sources };
        a.coverArtKey = artKeyFor({ coverArtSources: sources, coverArtUrl: url || undefined, id: a.id });
        toSave = a;
        if (url) void cacheArtUrl(url);
        else void generatePlaceholder(a.id);
      }
    }
    await putItem(toSave);
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
      {/* Top-level genres as a dropdown; free text still allowed for sub-genres. */}
      <Combo label="Genre" id="genre" value={album.genre} options={CATEGORY_NAMES} onChange={(v) => set({ genre: v })} />
      <Text label="Cover URL" id="coverUrl" value={album.coverArtUrl} onChange={(v) => set({ coverArtUrl: v })} />
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
      <KeySelect
        keyValue={song.key ?? ''}
        camelot={song.camelot ?? ''}
        onChange={(key, camelot) => set({ key: key || null, camelot: camelot || null })}
      />
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

/** Free-text input with a dropdown of suggested values (top-level genres). */
function Combo({ label, id, value, options, onChange }: { label: string; id: string; value?: string; options: string[]; onChange: (v: string) => void }) {
  const listId = `dl-${id}`;
  return (
    <label className="pdj-form__row">
      <span>{label}</span>
      <input data-testid={`field-${id}`} list={listId} value={value ?? ''} onChange={(e) => onChange(e.target.value)} />
      <datalist id={listId}>
        {options.map((o) => (
          <option key={o} value={o} />
        ))}
      </datalist>
    </label>
  );
}

/** Two linked dropdowns of VALID keys — picking one auto-fills the other (musical ⇄ Camelot). */
function KeySelect({ keyValue, camelot, onChange }: { keyValue: string; camelot: string; onChange: (key: string, camelot: string) => void }) {
  // keep any non-standard stored value visible rather than silently dropping it
  const keyOpts = keyValue && !MUSICAL_KEYS.includes(keyValue) ? [keyValue, ...MUSICAL_KEYS] : MUSICAL_KEYS;
  const camOpts = camelot && !CAMELOT_KEYS.includes(camelot) ? [camelot, ...CAMELOT_KEYS] : CAMELOT_KEYS;
  return (
    <>
      <label className="pdj-form__row">
        <span>Key</span>
        <select
          data-testid="field-key"
          value={keyValue}
          onChange={(e) => {
            const k = e.target.value;
            onChange(k, k ? keyToCamelot(k) ?? camelot : '');
          }}
        >
          <option value="">—</option>
          {keyOpts.map((k) => (
            <option key={k} value={k}>
              {k}
            </option>
          ))}
        </select>
      </label>
      <label className="pdj-form__row">
        <span>Key (Camelot)</span>
        <select
          data-testid="field-camelot"
          value={camelot}
          onChange={(e) => {
            const c = e.target.value;
            onChange(c ? camelotToKey(c) ?? keyValue : '', c);
          }}
        >
          <option value="">—</option>
          {camOpts.map((c) => (
            <option key={c} value={c}>
              {c}
            </option>
          ))}
        </select>
      </label>
    </>
  );
}
