// Setlist view — the FROZEN, read-only performance produced by ▶ Play. Framed as
// the DJ's set list: "Spin these tracks, in this order." Each track carries its
// own snapshot (artist/name/bpm/camelot/length) so it reads standalone even if
// the catalog or pockets change later. Mix suggestions are a reserved seam:
// rendered as a dormant, disabled disclosure until the engine fills them in.
import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { getSetlist, getItem } from '../../storage/repo';
import { isSong, type SongItem } from '../../types/model';
import { useCollectionsStore } from '../../store/useCollectionsStore';
import { SongDetailModal } from '../starmap/SongDetailModal';
import { DEFAULT_TRACK_MS } from '../../engine/realize';
import type { Setlist, SetlistTrack, TrackSource } from '../../types/collections';
import { msToClock } from '../../lib/format';
import './playlists.css';

const SOURCE_LABEL: Record<TrackSource, string> = {
  explicit: 'explicit',
  pocket: 'pocket',
  autofill: '↔ bridge',
};

function ProvenanceBadge({ source }: { source: TrackSource }) {
  return (
    <span
      className={`pdj-badge pdj-badge--src-${source}`}
      title={
        source === 'autofill'
          ? 'Autofill bridge — harmonic transition between explicit picks'
          : source === 'pocket'
            ? 'Sampled from a pocket'
            : 'Placed explicitly'
      }
    >
      {SOURCE_LABEL[source]}
    </span>
  );
}

function TrackNote({ note, onSave }: { note?: string; onSave: (n: string | undefined) => void }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(note ?? '');
  useEffect(() => setDraft(note ?? ''), [note]);
  if (editing)
    return (
      <input
        className="pdj-track__note-input"
        autoFocus
        value={draft}
        placeholder="performer note…"
        aria-label="Track note"
        onChange={(e) => setDraft(e.target.value)}
        onBlur={() => {
          setEditing(false);
          onSave(draft.trim() || undefined);
        }}
        onKeyDown={(e) => {
          if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
          else if (e.key === 'Escape') {
            setDraft(note ?? '');
            setEditing(false);
          }
        }}
      />
    );
  return (
    <button
      type="button"
      className={`pdj-track__note ${note ? '' : 'pdj-track__note--add'}`}
      onClick={() => setEditing(true)}
      title="Edit note"
    >
      {note ? `📝 ${note}` : '＋ note'}
    </button>
  );
}

function TrackRow({
  track,
  index,
  onOpen,
  onSaveNote,
}: {
  track: SetlistTrack;
  index: number;
  onOpen: (songId: string) => void;
  onSaveNote: (index: number, note: string | undefined) => void;
}) {
  const hasMix = !!track.mixSuggestions && track.mixSuggestions.length > 0;
  // Reconcile with setlist.totalMs: the engine substitutes DEFAULT_TRACK_MS for
  // length-less tracks when summing, so show the same fallback per row instead of
  // a blank cell (which would otherwise disagree with the displayed total).
  const shownMs =
    typeof track.lengthMs === 'number' && track.lengthMs > 0 ? track.lengthMs : DEFAULT_TRACK_MS;

  if (track.isText) {
    return (
      <li className="pdj-track pdj-track--cue" data-testid={`setlist-track-${index}`}>
        <span className="pdj-track__pos">{index + 1}</span>
        <div className="pdj-track__main">
          <div className="pdj-track__title">
            <span className="pdj-badge" title="Out-of-index cue">
              cue
            </span>{' '}
            {track.name}
          </div>
          <div className="pdj-track__sub">
            <TrackNote note={track.note} onSave={(n) => onSaveNote(index, n)} />
          </div>
        </div>
        <div className="pdj-track__right" />
      </li>
    );
  }

  return (
    <li className="pdj-track" data-testid={`setlist-track-${index}`}>
      <span className="pdj-track__pos">{index + 1}</span>
      <button
        type="button"
        className="pdj-track__main pdj-track__main--btn"
        data-testid={`setlist-track-open-${index}`}
        onClick={() => onOpen(track.songId)}
        title="Song details"
      >
        <div className="pdj-track__title">
          <span className="pdj-track__artist">{track.artist} — </span>
          {track.name}
        </div>
        <div className="pdj-track__sub">
          {track.bpm != null && (
            <span className="pdj-badge pdj-badge--bpm">{track.bpm} BPM</span>
          )}
          {track.camelot && (
            <span className="pdj-badge pdj-badge--camelot">{track.camelot}</span>
          )}
          <ProvenanceBadge source={track.source} />
          {track.sequenceName && (
            <span className="pdj-badge" title="Chapter">
              {track.sequenceName}
            </span>
          )}
        </div>
      </button>
      <div className="pdj-track__right">
        <span className="pdj-track__len">{msToClock(shownMs)}</span>
        <TrackNote note={track.note} onSave={(n) => onSaveNote(index, n)} />
      </div>

      {/* Reserved seam: per-track mix suggestions. Dormant until the engine fills
          track.mixSuggestions; rendered disabled so the affordance is discoverable. */}
      <details className="pdj-track__mix" data-testid={`mix-suggestions-${index}`} aria-disabled>
        <summary
          onClick={(e) => e.preventDefault()}
          title="Per-track mix suggestions — coming soon"
        >
          ◇ Mix suggestions {hasMix ? `(${track.mixSuggestions!.length})` : '(coming soon)'}
        </summary>
      </details>
    </li>
  );
}

export function SetlistView() {
  const { id = '', setlistId = '' } = useParams();
  const navigate = useNavigate();
  const deleteSetlist = useCollectionsStore((s) => s.deleteSetlist);
  const renameSetlist = useCollectionsStore((s) => s.renameSetlist);
  const setSetlistTrackNote = useCollectionsStore((s) => s.setSetlistTrackNote);

  const [setlist, setSetlist] = useState<Setlist | null>(null);
  const [loading, setLoading] = useState(true);
  const [nameDraft, setNameDraft] = useState('');
  // Song-detail popover (same modal as the browser; closes via its top-right ✕).
  const [openSong, setOpenSong] = useState<SongItem | null>(null);
  const [openAlbumName, setOpenAlbumName] = useState('');

  useEffect(() => {
    if (!setlistId) return;
    let live = true;
    setLoading(true);
    void getSetlist(setlistId).then((sl) => {
      if (!live) return;
      setSetlist(sl ?? null);
      setNameDraft(sl?.name ?? '');
      setLoading(false);
    });
    return () => {
      live = false;
    };
  }, [setlistId]);

  const onDelete = async () => {
    if (!setlistId) return;
    await deleteSetlist(setlistId);
    navigate(`/playlists/${id}`);
  };

  const commitName = () => {
    if (!setlist) return;
    const trimmed = nameDraft.trim();
    if (!trimmed || trimmed === (setlist.name ?? '')) {
      setNameDraft(setlist.name ?? '');
      return;
    }
    void renameSetlist(setlist.id, trimmed).then((s) => s && setSetlist(s));
  };

  const onSaveTrackNote = (index: number, note: string | undefined) => {
    if (!setlist) return;
    void setSetlistTrackNote(setlist.id, index, note).then((s) => s && setSetlist(s));
  };

  // Export the frozen set list as a CSV. Prefers the native OS save dialog
  // (File System Access API — name + location), falls back to an anchor download.
  const saveCsv = async () => {
    if (!setlist) return;
    const cell = (v: unknown) => {
      const s = v == null ? '' : String(v);
      return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    };
    // `Song ID` is the index item id (sng_…): a downstream audio builder can O(1)-look it
    // up in index.json to resolve the track number + audio segment start/end timestamps.
    const header = ['#', 'Artist', 'Title', 'BPM', 'Key', 'Length', 'Source', 'Sequence', 'Note', 'Song ID'];
    const lines = [header.join(',')];
    setlist.tracks.forEach((t, i) => {
      const ms = t.isText ? 0 : typeof t.lengthMs === 'number' && t.lengthMs > 0 ? t.lengthMs : DEFAULT_TRACK_MS;
      lines.push(
        [
          i + 1,
          t.artist,
          t.name,
          t.bpm ?? '',
          t.camelot ?? '',
          t.isText ? '' : msToClock(ms),
          t.isText ? 'cue' : t.source,
          t.sequenceName ?? '',
          t.note ?? '',
          t.songId,
        ]
          .map(cell)
          .join(','),
      );
    });
    const csv = lines.join('\r\n') + '\r\n';
    const base = (setlist.name ?? 'setlist').replace(/[\\/:*?"<>|]+/g, '').trim() || 'setlist';
    const suggestedName = `${base}.csv`;

    const w = window as unknown as {
      showSaveFilePicker?: (opts: {
        suggestedName?: string;
        types?: { description: string; accept: Record<string, string[]> }[];
      }) => Promise<{ createWritable: () => Promise<{ write: (d: BlobPart) => Promise<void>; close: () => Promise<void> }> }>;
    };
    if (typeof w.showSaveFilePicker === 'function') {
      try {
        const handle = await w.showSaveFilePicker({
          suggestedName,
          types: [{ description: 'CSV file', accept: { 'text/csv': ['.csv'] } }],
        });
        const writable = await handle.createWritable();
        await writable.write(new Blob([csv], { type: 'text/csv' }));
        await writable.close();
        return;
      } catch (err) {
        if ((err as DOMException)?.name === 'AbortError') return; // user cancelled the dialog
        // any other error: fall through to the legacy download
      }
    }
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = suggestedName;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };

  // Clicking a track opens the read-only song detail popover (resolve the live song by id).
  const openSongDetail = async (songId: string) => {
    const it = await getItem(songId);
    if (!it || !isSong(it)) return;
    let albumName = '';
    if (it.albumId) {
      const a = await getItem(it.albumId);
      albumName = a?.name ?? '';
    }
    setOpenAlbumName(albumName);
    setOpenSong(it);
  };

  if (loading) {
    return (
      <div className="pdj-setlist" data-testid="setlist-view">
        <div className="pdj-pl__empty">Loading set list…</div>
      </div>
    );
  }

  if (!setlist) {
    return (
      <div className="pdj-setlist" data-testid="setlist-view">
        <Link to={`/playlists/${id}`} className="pdj-pl__back">
          ← Back to playlist
        </Link>
        <div className="pdj-pl__empty">This set list no longer exists.</div>
      </div>
    );
  }

  return (
    <div className="pdj-setlist" data-testid="setlist-view">
      <Link to={`/playlists/${id}`} className="pdj-pl__back">
        ← Back to playlist
      </Link>

      <header className="pdj-setlist__head">
        <input
          className="pdj-setlist__title pdj-setlist__title-input"
          value={nameDraft}
          placeholder="Set list"
          aria-label="Set list name"
          data-testid="setlist-rename"
          onChange={(e) => setNameDraft(e.target.value)}
          onBlur={commitName}
          onKeyDown={(e) => {
            if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
            else if (e.key === 'Escape') setNameDraft(setlist.name ?? '');
          }}
        />
        <p className="pdj-setlist__tagline">Spin these tracks, in this order.</p>
      </header>

      <div className="pdj-setlist__stats">
        <span className="pdj-setlist__stat">
          <b data-testid="setlist-total">{msToClock(setlist.totalMs)}</b> total
        </span>
        <span className="pdj-setlist__stat">
          <b>{setlist.tracks.length}</b> {setlist.tracks.length === 1 ? 'track' : 'tracks'}
        </span>
        <span className="pdj-setlist__stat">
          {new Date(setlist.generatedAt).toLocaleString()}
        </span>
        <div className="pdj-setlist__spacer" />
        <button
          type="button"
          className="pdj-btn pdj-btn--sm"
          data-testid="setlist-save"
          onClick={() => void saveCsv()}
          title="Save this set list as a CSV file"
        >
          ⤓ Save CSV
        </button>
        <button
          type="button"
          className="pdj-btn pdj-btn--sm pdj-btn--danger"
          data-testid="setlist-delete"
          onClick={() => void onDelete()}
        >
          Delete
        </button>
      </div>

      {setlist.tracks.length === 0 ? (
        <div className="pdj-pl__empty">
          This set list is empty — add items to the playlist, then ▶ Play again.
        </div>
      ) : (
        <div className="pdj-setlist__sections">
          {groupBySequence(setlist.tracks).map((section, si) => (
            <section
              className="pdj-setlist__section"
              key={`${section.name}-${si}`}
              data-testid={`setlist-section-${si}`}
            >
              <div className="pdj-setlist__section-head">
                <span className="pdj-setlist__section-name">{section.name}</span>
                <span className="pdj-setlist__section-count">
                  {section.items.length} {section.items.length === 1 ? 'track' : 'tracks'} ·{' '}
                  {msToClock(section.ms)}
                </span>
              </div>
              <ol className="pdj-setlist__tracks">
                {section.items.map(({ track, index }) => (
                  <TrackRow
                    key={`${track.songId}-${index}`}
                    track={track}
                    index={index}
                    onOpen={openSongDetail}
                    onSaveNote={onSaveTrackNote}
                  />
                ))}
              </ol>
            </section>
          ))}
        </div>
      )}

      <SongDetailModal song={openSong} albumName={openAlbumName} onClose={() => setOpenSong(null)} />
    </div>
  );
}

/** Group consecutive tracks by the sequence (chapter) they were realized from. */
function groupBySequence(
  tracks: SetlistTrack[],
): { name: string; ms: number; items: { track: SetlistTrack; index: number }[] }[] {
  const sections: { name: string; ms: number; items: { track: SetlistTrack; index: number }[] }[] = [];
  tracks.forEach((track, index) => {
    const name = track.sequenceName || 'Set';
    let last = sections[sections.length - 1];
    if (!last || last.name !== name) {
      last = { name, ms: 0, items: [] };
      sections.push(last);
    }
    last.items.push({ track, index });
    if (!track.isText)
      last.ms += typeof track.lengthMs === 'number' && track.lengthMs > 0 ? track.lengthMs : DEFAULT_TRACK_MS;
  });
  return sections;
}
