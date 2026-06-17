// Playlist detail — the editable TEMPLATE. Rename/delete the playlist, edit its
// sequences (chapters) + their nodes, ▶ Play it into a frozen Setlist, and see
// the setlist history. Song/album nodes are resolved by id from the catalog
// (collections are cross-source) — and show their cover art, bpm/key, an editable
// performer note, and open full metadata on click.
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useCollectionsStore } from '../../store/useCollectionsStore';
import type { Playlist, PlaylistNode, Pocket, SequenceNode, Setlist } from '../../types/collections';
import {
  isAlbumNode,
  isPocketNode,
  isSongNode,
  isSequenceNode,
  isTextNode,
} from '../../types/collections';
import type { MusicItem, SongItem } from '../../types/model';
import { isAlbum, isSong } from '../../types/model';
import { getItem } from '../../storage/repo';
import { msToClock, clockToMs } from '../../lib/format';
import { Thumbnail } from '../common/Thumbnail';
import { SongDetailModal } from '../starmap/SongDetailModal';
import { seqStats } from '../../engine/playlistStats';
import './playlists.css';

// ---------------------------------------------------------------------------
// Inline note editor (performer note on an item — F7)
// ---------------------------------------------------------------------------
function NoteEditor(props: { note?: string; onSave: (note: string | undefined) => void }) {
  const { note } = props;
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(note ?? '');
  useEffect(() => setDraft(note ?? ''), [note]);

  if (!editing) {
    return note ? (
      <button
        type="button"
        className="pdj-node__note pdj-node__note--view"
        title="Edit note"
        onClick={() => setEditing(true)}
      >
        📝 {note}
      </button>
    ) : (
      <button type="button" className="pdj-node__note pdj-node__note--add" onClick={() => setEditing(true)}>
        ＋ note
      </button>
    );
  }
  return (
    <input
      className="pdj-node__note-input"
      autoFocus
      value={draft}
      placeholder="performer note…"
      aria-label="Item note"
      onChange={(e) => setDraft(e.target.value)}
      onBlur={() => {
        setEditing(false);
        props.onSave(draft.trim() || undefined);
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
}

// ---------------------------------------------------------------------------
// One node row inside a sequence
// ---------------------------------------------------------------------------
function NodeRow(props: {
  node: PlaylistNode;
  playlistId: string;
  sequences: SequenceNode[];
  currentSeqId: string;
  item?: MusicItem;
  coverArtKey?: string;
  nameFor: (node: PlaylistNode) => string;
  metaFor: (node: PlaylistNode) => string;
  onOpenSong: (songId: string) => void;
}) {
  const { node, playlistId, sequences, currentSeqId, item, coverArtKey } = props;
  const removeNode = useCollectionsStore((s) => s.removeNode);
  const moveNode = useCollectionsStore((s) => s.moveNode);
  const setPlaylistNodeNote = useCollectionsStore((s) => s.setPlaylistNodeNote);

  const kindLabel = isSongNode(node)
    ? 'song'
    : isAlbumNode(node)
      ? 'album'
      : isPocketNode(node)
        ? 'pocket'
        : isTextNode(node)
          ? 'cue'
          : 'sequence';
  const meta = props.metaFor(node);
  const song = item && isSong(item) ? item : undefined;
  const showArt = isSongNode(node) || isAlbumNode(node);
  const note = 'note' in node ? (node as { note?: string }).note : undefined;
  const label = props.nameFor(node);

  return (
    <div className="pdj-node" data-testid={`node-${node.nodeId}`}>
      {showArt && <Thumbnail artKey={coverArtKey} alt={label} size={36} className="pdj-node__art" />}
      <span className={`pdj-node__kind pdj-node__kind--${kindLabel}`}>{kindLabel}</span>
      <div className="pdj-node__body">
        {song ? (
          <button
            type="button"
            className="pdj-node__label pdj-node__label--btn"
            data-testid={`node-open-${node.nodeId}`}
            onClick={() => props.onOpenSong(song.id)}
            title="Song details"
          >
            {label}
          </button>
        ) : (
          <span className="pdj-node__label">{label}</span>
        )}
        <div className="pdj-node__sub">
          {song && (
            <>
              {song.bpm != null && <span className="pdj-node__badge">{song.bpm} BPM</span>}
              {(song.camelot || song.key) && (
                <span className="pdj-node__badge">{song.camelot ?? song.key}</span>
              )}
            </>
          )}
          {meta && <span className="pdj-node__meta">{meta}</span>}
          <NoteEditor note={note} onSave={(n) => void setPlaylistNodeNote(playlistId, node.nodeId, n)} />
        </div>
      </div>
      {sequences.length > 1 && (
        <select
          className="pdj-node__move"
          value={currentSeqId}
          data-testid={`node-move-${node.nodeId}`}
          aria-label="Move to sequence"
          onChange={(e) => {
            if (e.target.value !== currentSeqId) void moveNode(playlistId, node.nodeId, e.target.value);
          }}
        >
          {sequences.map((s) => (
            <option key={s.nodeId} value={s.nodeId}>
              → {s.name}
            </option>
          ))}
        </select>
      )}
      <button
        type="button"
        className="pdj-iconbtn"
        data-testid={`node-remove-${node.nodeId}`}
        aria-label="Remove"
        title="Remove"
        onClick={() => void removeNode(playlistId, node.nodeId)}
      >
        ✕
      </button>
    </div>
  );
}

// ---------------------------------------------------------------------------
// One sequence (chapter) section
// ---------------------------------------------------------------------------
function SequenceSection(props: {
  playlist: Playlist;
  seq: SequenceNode;
  pockets: Pocket[];
  canRemove: boolean;
  itemsById: Map<string, MusicItem>;
  pocketsById: Map<string, Pocket>;
  nameFor: (node: PlaylistNode) => string;
  metaFor: (node: PlaylistNode) => string;
  onOpenSong: (songId: string) => void;
}) {
  const { playlist, seq, pockets, canRemove, itemsById, pocketsById } = props;
  const renameSequence = useCollectionsStore((s) => s.renameSequence);
  const removeSequence = useCollectionsStore((s) => s.removeSequence);
  const setSequenceTarget = useCollectionsStore((s) => s.setSequenceTarget);
  const addToPlaylist = useCollectionsStore((s) => s.addToPlaylist);
  const addTextToPlaylist = useCollectionsStore((s) => s.addTextToPlaylist);

  const [nameDraft, setNameDraft] = useState(seq.name);
  const [targetText, setTargetText] = useState(msToClock(seq.targetMs));
  const [addPocketId, setAddPocketId] = useState('');
  const [textDraft, setTextDraft] = useState('');

  useEffect(() => setNameDraft(seq.name), [seq.name]);
  useEffect(() => setTargetText(msToClock(seq.targetMs)), [seq.targetMs]);

  const stats = useMemo(() => seqStats(seq, pocketsById, itemsById), [seq, pocketsById, itemsById]);

  const commitName = () => {
    const trimmed = nameDraft.trim();
    if (!trimmed || trimmed === seq.name) {
      setNameDraft(seq.name);
      return;
    }
    void renameSequence(playlist.id, seq.nodeId, trimmed);
  };
  const commitTarget = () => void setSequenceTarget(playlist.id, seq.nodeId, clockToMs(targetText));
  const addPocket = () => {
    if (!addPocketId) return;
    void addToPlaylist(playlist.id, { kind: 'pocket', id: addPocketId }, seq.nodeId);
    setAddPocketId('');
  };
  const addText = () => {
    const t = textDraft.trim();
    if (!t) return;
    void addTextToPlaylist(playlist.id, t, seq.nodeId);
    setTextDraft('');
  };

  return (
    <section className="pdj-seq" data-testid={`sequence-${seq.nodeId}`}>
      <div className="pdj-seq__head">
        <input
          className="pdj-seq__name"
          value={nameDraft}
          aria-label="Sequence name"
          data-testid={`sequence-rename-${seq.nodeId}`}
          onChange={(e) => setNameDraft(e.target.value)}
          onBlur={commitName}
          onKeyDown={(e) => {
            if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
            else if (e.key === 'Escape') setNameDraft(seq.name);
          }}
        />
        <span className="pdj-seq__stats" data-testid={`sequence-stats-${seq.nodeId}`}>
          {stats.songs} {stats.songs === 1 ? 'song' : 'songs'} · {msToClock(stats.ms) || '0:00'}
        </span>
        <label className="pdj-seq__target">
          target
          <input
            type="text"
            inputMode="numeric"
            placeholder="m:ss"
            value={targetText}
            data-testid={`sequence-target-${seq.nodeId}`}
            onChange={(e) => setTargetText(e.target.value)}
            onBlur={commitTarget}
            onKeyDown={(e) => {
              if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
            }}
          />
        </label>
        <button
          type="button"
          className="pdj-iconbtn"
          data-testid={`sequence-remove-${seq.nodeId}`}
          aria-label="Remove sequence"
          title={canRemove ? 'Remove chapter' : 'A playlist needs at least one chapter'}
          disabled={!canRemove}
          onClick={() => void removeSequence(playlist.id, seq.nodeId)}
        >
          🗑
        </button>
      </div>

      <div className="pdj-seq__nodes">
        {seq.children.length === 0 ? (
          <p className="pdj-seq__empty">Empty — add a pocket or a cue below, or items from the browser.</p>
        ) : (
          seq.children.map((node) => {
            const refId = isSongNode(node) ? node.songId : isAlbumNode(node) ? node.albumId : undefined;
            const item = refId ? itemsById.get(refId) : undefined;
            const coverArtKey =
              item && isAlbum(item)
                ? item.coverArtKey
                : item && isSong(item) && item.albumId
                  ? (itemsById.get(item.albumId) as { coverArtKey?: string } | undefined)?.coverArtKey
                  : undefined;
            return (
              <NodeRow
                key={node.nodeId}
                node={node}
                playlistId={playlist.id}
                sequences={playlist.sequences}
                currentSeqId={seq.nodeId}
                item={item}
                coverArtKey={coverArtKey}
                nameFor={props.nameFor}
                metaFor={props.metaFor}
                onOpenSong={props.onOpenSong}
              />
            );
          })
        )}
      </div>

      <div className="pdj-seq__add">
        <select
          value={addPocketId}
          data-testid={`sequence-add-pocket-select-${seq.nodeId}`}
          aria-label="Add a pocket to this chapter"
          onChange={(e) => setAddPocketId(e.target.value)}
        >
          <option value="">＋ Add pocket…</option>
          {pockets.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </select>
        <button
          type="button"
          className="pdj-btn pdj-btn--sm pdj-btn--ghost"
          data-testid={`sequence-add-pocket-${seq.nodeId}`}
          disabled={!addPocketId}
          onClick={addPocket}
        >
          Add
        </button>
      </div>

      <div className="pdj-seq__add">
        <input
          className="pdj-seq__text-input"
          type="text"
          placeholder='＋ Add a cue, e.g. "sample of This Land Is Mine Land"'
          value={textDraft}
          data-testid={`sequence-add-text-input-${seq.nodeId}`}
          aria-label="Add a free-text cue"
          onChange={(e) => setTextDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') addText();
          }}
        />
        <button
          type="button"
          className="pdj-btn pdj-btn--sm pdj-btn--ghost"
          data-testid={`sequence-add-text-${seq.nodeId}`}
          disabled={!textDraft.trim()}
          onClick={addText}
        >
          Add cue
        </button>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------
export function PlaylistDetail() {
  const { id = '' } = useParams();
  const navigate = useNavigate();

  const load = useCollectionsStore((s) => s.load);
  const playlists = useCollectionsStore((s) => s.playlists);
  const pockets = useCollectionsStore((s) => s.pockets);
  const rev = useCollectionsStore((s) => s.rev);
  const renamePlaylist = useCollectionsStore((s) => s.renamePlaylist);
  const deletePlaylist = useCollectionsStore((s) => s.deletePlaylist);
  const addSequence = useCollectionsStore((s) => s.addSequence);
  const play = useCollectionsStore((s) => s.play);
  const getSetlists = useCollectionsStore((s) => s.getSetlists);
  const deleteSetlist = useCollectionsStore((s) => s.deleteSetlist);

  const playlist = useMemo(() => playlists.find((p) => p.id === id), [playlists, id]);

  const [setlists, setSetlists] = useState<Setlist[]>([]);
  const [playing, setPlaying] = useState(false);
  const [nameDraft, setNameDraft] = useState('');
  // Resolved catalog items (songs/albums) keyed by id — drives labels, art, bpm/key, stats.
  const [itemsById, setItemsById] = useState<Record<string, MusicItem>>({});
  // Open song-metadata modal.
  const [openSong, setOpenSong] = useState<SongItem | null>(null);
  const [openAlbumName, setOpenAlbumName] = useState('');

  useEffect(() => void load(), [load]);

  useEffect(() => {
    if (playlist) setNameDraft(playlist.name);
  }, [playlist?.id, playlist?.name]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!id) return;
    let live = true;
    void getSetlists(id).then((rows) => live && setSetlists(rows));
    return () => {
      live = false;
    };
  }, [id, getSetlists, rev]);

  const pocketById = useMemo(() => new Map(pockets.map((p) => [p.id, p])), [pockets]);

  // Resolve every referenced song/album (+ song's album for cover art, + pocket members) from the catalog.
  useEffect(() => {
    if (!playlist) return;
    const need = new Set<string>();
    const walk = (nodes: PlaylistNode[]) => {
      for (const n of nodes) {
        if (isSongNode(n)) need.add(n.songId);
        else if (isAlbumNode(n)) need.add(n.albumId);
        else if (isPocketNode(n)) {
          const p = pocketById.get(n.pocketId);
          if (p) {
            p.songIds.forEach((x) => need.add(x));
            p.albumIds.forEach((x) => need.add(x));
          }
        } else if (isSequenceNode(n)) walk(n.children);
      }
    };
    for (const seq of playlist.sequences) walk(seq.children);
    // cover art: pull the owning album of any resolved song.
    for (const it of Object.values(itemsById)) if (isSong(it) && it.albumId) need.add(it.albumId);

    const missing = [...need].filter((x) => !(x in itemsById));
    if (missing.length === 0) return;
    let live = true;
    void Promise.all(missing.map((x) => getItem(x))).then((items) => {
      if (!live) return;
      setItemsById((prev) => {
        const next = { ...prev };
        items.forEach((it, i) => {
          if (it) next[missing[i]] = it;
        });
        // mark unresolved ids so we don't refetch forever
        missing.forEach((mid, i) => {
          if (!items[i]) next[mid] = next[mid];
        });
        return next;
      });
    });
    return () => {
      live = false;
    };
  }, [playlist, itemsById, pocketById]);

  const itemsMap = useMemo(() => new Map(Object.entries(itemsById)), [itemsById]);

  const nameFor = useCallback(
    (node: PlaylistNode): string => {
      if (isSongNode(node)) {
        const it = itemsById[node.songId];
        return it ? `${it.artist} — ${it.name}` : 'Loading…';
      }
      if (isAlbumNode(node)) {
        const it = itemsById[node.albumId];
        return it ? `${it.artist} — ${it.name}` : 'Loading…';
      }
      if (isPocketNode(node)) return pocketById.get(node.pocketId)?.name ?? '(missing pocket)';
      if (isTextNode(node)) return node.text;
      if (isSequenceNode(node)) return node.name;
      return '';
    },
    [itemsById, pocketById],
  );

  const metaFor = useCallback(
    (node: PlaylistNode): string => {
      if (isPocketNode(node)) {
        const p = pocketById.get(node.pocketId);
        if (!p) return '';
        const n = p.songIds.length + p.albumIds.length + p.childPocketIds.length;
        return `${n} ${n === 1 ? 'item' : 'items'}`;
      }
      if (isAlbumNode(node)) {
        const it = itemsById[node.albumId];
        const n = it && isAlbum(it) ? it.trackIds.length : 0;
        return n ? `${n} tracks` : 'album';
      }
      return '';
    },
    [pocketById, itemsById],
  );

  const onOpenSong = useCallback(
    (songId: string) => {
      const it = itemsById[songId];
      if (!it || !isSong(it)) return;
      const album = it.albumId ? itemsById[it.albumId] : undefined;
      setOpenAlbumName(album ? album.name : '');
      setOpenSong(it);
    },
    [itemsById],
  );

  const totals = useMemo(() => {
    if (!playlist) return { songs: 0, ms: 0 };
    let songs = 0;
    let ms = 0;
    for (const seq of playlist.sequences) {
      const r = seqStats(seq, pocketById, itemsMap);
      songs += r.songs;
      ms += r.ms;
    }
    return { songs, ms };
  }, [playlist, pocketById, itemsMap]);

  const commitName = () => {
    if (!playlist) return;
    const trimmed = nameDraft.trim();
    if (!trimmed || trimmed === playlist.name) {
      setNameDraft(playlist.name);
      return;
    }
    void renamePlaylist(playlist.id, trimmed);
  };

  const onPlay = async () => {
    if (!id || playing) return;
    setPlaying(true);
    try {
      const setlist = await play(id);
      if (setlist) navigate(`/playlists/${id}/setlist/${setlist.id}`);
    } finally {
      setPlaying(false);
    }
  };

  const onDelete = async () => {
    if (!id) return;
    await deletePlaylist(id);
    navigate('/playlists');
  };

  if (!playlist) {
    return (
      <div className="pdj-playlists" data-testid="playlist-detail">
        <Link to="/playlists" className="pdj-pl__back">
          ← Playlists
        </Link>
        <div className="pdj-pl__empty">This playlist no longer exists.</div>
      </div>
    );
  }

  const canRemoveSeq = playlist.sequences.length > 1;

  return (
    <div className="pdj-playlists" data-testid="playlist-detail">
      <Link to="/playlists" className="pdj-pl__back">
        ← Playlists
      </Link>

      <div className="pdj-pl__head">
        <input
          className="pdj-pl__name-input"
          value={nameDraft}
          aria-label="Playlist name"
          data-testid="playlist-rename"
          onChange={(e) => setNameDraft(e.target.value)}
          onBlur={commitName}
          onKeyDown={(e) => {
            if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
            else if (e.key === 'Escape') setNameDraft(playlist.name);
          }}
        />
        <button
          type="button"
          className="pdj-btn pdj-pl__play"
          data-testid="playlist-play"
          disabled={playing}
          onClick={() => void onPlay()}
        >
          {playing ? '…' : '▶'} Play
        </button>
        <button
          type="button"
          className="pdj-btn pdj-btn--sm pdj-btn--danger"
          data-testid="playlist-delete"
          onClick={() => void onDelete()}
        >
          Delete
        </button>
      </div>

      <p className="pdj-pl__count" data-testid="playlist-totals">
        {playlist.sequences.length} {playlist.sequences.length === 1 ? 'chapter' : 'chapters'} ·{' '}
        {totals.songs} {totals.songs === 1 ? 'song' : 'songs'} · {msToClock(totals.ms) || '0:00'}
      </p>

      <h2 className="pdj-pl__section-title">Sequences</h2>
      {playlist.sequences.map((seq) => (
        <SequenceSection
          key={seq.nodeId}
          playlist={playlist}
          seq={seq}
          pockets={pockets}
          canRemove={canRemoveSeq}
          itemsById={itemsMap}
          pocketsById={pocketById}
          nameFor={nameFor}
          metaFor={metaFor}
          onOpenSong={onOpenSong}
        />
      ))}

      <button
        type="button"
        className="pdj-btn pdj-btn--sm pdj-btn--ghost"
        data-testid="sequence-add"
        onClick={() => void addSequence(playlist.id, `Chapter ${playlist.sequences.length + 1}`)}
      >
        ＋ Add sequence
      </button>

      <h2 className="pdj-pl__section-title">Set lists</h2>
      {setlists.length === 0 ? (
        <p className="pdj-seq__empty">No set lists yet — hit ▶ Play to generate one.</p>
      ) : (
        <div className="pdj-setlist-hist">
          {setlists.map((sl) => (
            <div key={sl.id} className="pdj-setlist-hist__row" data-testid={`setlist-row-${sl.id}`}>
              <Link to={`/playlists/${playlist.id}/setlist/${sl.id}`} className="pdj-setlist-hist__link">
                <span className="pdj-setlist-hist__name">{sl.name ?? 'Set list'}</span>
                <span className="pdj-setlist-hist__meta">
                  {sl.tracks.length} {sl.tracks.length === 1 ? 'track' : 'tracks'} · {msToClock(sl.totalMs)} ·{' '}
                  {new Date(sl.generatedAt).toLocaleString()}
                </span>
              </Link>
              <button
                type="button"
                className="pdj-iconbtn"
                data-testid={`setlist-delete-${sl.id}`}
                aria-label="Delete set list"
                title="Delete set list"
                onClick={() => void deleteSetlist(sl.id)}
              >
                ✕
              </button>
            </div>
          ))}
        </div>
      )}

      <SongDetailModal song={openSong} albumName={openAlbumName} onClose={() => setOpenSong(null)} />
    </div>
  );
}
