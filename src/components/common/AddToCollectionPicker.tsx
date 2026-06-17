// Shared "Add to…" picker. Lets the user drop a song/album into any existing
// playlist (optionally targeting a specific sequence) or pocket, or spin up a
// new one inline. Closing on a successful add is the key contract; the four
// detail surfaces mount this via <AddToCollectionButton />.
import { useEffect, useMemo, useState } from 'react';
import { Modal } from './Modal';
import { useCollectionsStore } from '../../store/useCollectionsStore';
import type { Playlist } from '../../types/collections';
import {
  loadAddToPrefs,
  rememberPlaylist,
  rememberPocket,
  lastFirst,
} from '../../lib/addToPrefs';
import './add-to-collection.css';

interface Props {
  open: boolean;
  onClose: () => void;
  item: { kind: 'song' | 'album'; id: string; name: string };
}

/** Inline "＋ New …" name entry shared by the playlist + pocket sections. */
function NewEntry(props: {
  testId: string;
  label: string;
  placeholder: string;
  onCreate: (name: string) => void | Promise<void>;
}) {
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState('');

  const confirm = () => {
    const trimmed = name.trim();
    if (!trimmed) return;
    void props.onCreate(trimmed);
  };

  if (!adding) {
    return (
      <button
        type="button"
        className="pdj-btn pdj-btn--sm pdj-btn--ghost"
        data-testid={props.testId}
        onClick={() => setAdding(true)}
      >
        {props.label}
      </button>
    );
  }
  return (
    <div className="pdj-addcol__new">
      <input
        type="text"
        autoFocus
        value={name}
        placeholder={props.placeholder}
        data-testid={`${props.testId}-input`}
        onChange={(e) => setName(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') confirm();
          else if (e.key === 'Escape') setAdding(false);
        }}
      />
      <button
        type="button"
        className="pdj-btn pdj-btn--sm"
        data-testid={`${props.testId}-confirm`}
        disabled={!name.trim()}
        onClick={confirm}
      >
        Create
      </button>
    </div>
  );
}

/** One playlist row — expands to a sequence picker when the playlist has >1 sequence. */
function PlaylistRow(props: {
  playlist: Playlist;
  lastSeqId?: string;
  isLast?: boolean;
  onAdd: (playlistId: string, sequenceNodeId?: string) => void | Promise<void>;
}) {
  const { playlist, lastSeqId, isLast } = props;
  const multi = playlist.sequences.length > 1;
  const [picking, setPicking] = useState(false);
  // Default the sequence to the one last used for this playlist, when it still exists.
  const defaultSeq =
    (lastSeqId && playlist.sequences.some((s) => s.nodeId === lastSeqId) ? lastSeqId : undefined) ??
    playlist.sequences[0]?.nodeId ??
    '';
  const [seqId, setSeqId] = useState(defaultSeq);

  if (multi && picking) {
    return (
      <div className="pdj-addcol__row" data-testid={`add-collection-playlist-${playlist.id}`}>
        <div className="pdj-addcol__seq">
          <label htmlFor={`seq-${playlist.id}`}>{playlist.name} → sequence</label>
          <select
            id={`seq-${playlist.id}`}
            value={seqId}
            data-testid="add-collection-sequence-select"
            onChange={(e) => setSeqId(e.target.value)}
          >
            {playlist.sequences.map((s) => (
              <option key={s.nodeId} value={s.nodeId}>
                {s.name}
              </option>
            ))}
          </select>
        </div>
        <button
          type="button"
          className="pdj-btn pdj-btn--sm"
          data-testid={`add-collection-playlist-confirm-${playlist.id}`}
          onClick={() => void props.onAdd(playlist.id, seqId)}
        >
          Add
        </button>
      </div>
    );
  }

  return (
    <button
      type="button"
      className="pdj-addcol__row"
      data-testid={`add-collection-playlist-${playlist.id}`}
      onClick={() => {
        if (multi) setPicking(true);
        else void props.onAdd(playlist.id);
      }}
    >
      <span className="pdj-addcol__row-name">
        {playlist.name}
        {isLast && <span className="pdj-addcol__last">last used</span>}
      </span>
      <span className="pdj-addcol__row-meta">
        {multi ? `${playlist.sequences.length} sequences` : 'add'}
      </span>
    </button>
  );
}

export function AddToCollectionPicker(props: Props): JSX.Element | null {
  const { open, onClose, item } = props;
  const load = useCollectionsStore((s) => s.load);
  const playlists = useCollectionsStore((s) => s.playlists);
  const pockets = useCollectionsStore((s) => s.pockets);
  const createPlaylist = useCollectionsStore((s) => s.createPlaylist);
  const addToPlaylist = useCollectionsStore((s) => s.addToPlaylist);
  const createPocket = useCollectionsStore((s) => s.createPocket);
  const addSongToPocket = useCollectionsStore((s) => s.addSongToPocket);
  const addAlbumToPocket = useCollectionsStore((s) => s.addAlbumToPocket);

  const prefs = useMemo(() => (open ? loadAddToPrefs() : {}), [open]);
  // Surface the last-used target first (and badge it).
  const orderedPlaylists = useMemo(() => lastFirst(playlists, prefs.playlistId), [playlists, prefs.playlistId]);
  const orderedPockets = useMemo(() => lastFirst(pockets, prefs.pocketId), [pockets, prefs.pocketId]);

  // Refresh the cache once whenever the picker opens.
  useEffect(() => {
    if (open) void load();
  }, [open, load]);

  if (!open) return null;

  const addToPocket = async (pocketId: string) => {
    if (item.kind === 'song') await addSongToPocket(pocketId, item.id);
    else await addAlbumToPocket(pocketId, item.id);
    rememberPocket(pocketId);
    onClose();
  };

  const addToList = async (playlistId: string, sequenceNodeId?: string) => {
    await addToPlaylist(playlistId, { kind: item.kind, id: item.id }, sequenceNodeId);
    rememberPlaylist(playlistId, sequenceNodeId);
    onClose();
  };

  return (
    <Modal open={open} onClose={onClose} title={`Add "${item.name}" to…`} testId="add-collection-modal">
      <section className="pdj-addcol__section">
        <h3 className="pdj-addcol__heading">Playlists</h3>
        {playlists.length === 0 ? (
          <p className="pdj-addcol__empty">No playlists yet — create one.</p>
        ) : (
          <div className="pdj-addcol__list">
            {orderedPlaylists.map((p) => (
              <PlaylistRow
                key={p.id}
                playlist={p}
                lastSeqId={prefs.sequenceByPlaylist?.[p.id]}
                isLast={p.id === prefs.playlistId}
                onAdd={addToList}
              />
            ))}
          </div>
        )}
        <NewEntry
          testId="add-collection-new-playlist"
          label="＋ New playlist"
          placeholder="Playlist name"
          onCreate={async (name) => {
            const created = await createPlaylist(name);
            await addToList(created.id);
          }}
        />
      </section>

      <section className="pdj-addcol__section">
        <h3 className="pdj-addcol__heading">Pockets</h3>
        {pockets.length === 0 ? (
          <p className="pdj-addcol__empty">No pockets yet — create one.</p>
        ) : (
          <div className="pdj-addcol__list">
            {orderedPockets.map((p) => (
              <button
                key={p.id}
                type="button"
                className="pdj-addcol__row"
                data-testid={`add-collection-pocket-${p.id}`}
                onClick={() => void addToPocket(p.id)}
              >
                <span className="pdj-addcol__row-name">
                  {p.name}
                  {p.id === prefs.pocketId && <span className="pdj-addcol__last">last used</span>}
                </span>
                <span className="pdj-addcol__row-meta">add</span>
              </button>
            ))}
          </div>
        )}
        <NewEntry
          testId="add-collection-new-pocket"
          label="＋ New pocket"
          placeholder="Pocket name"
          onCreate={async (name) => {
            const created = await createPocket(name);
            await addToPocket(created.id);
          }}
        />
      </section>
    </Modal>
  );
}
