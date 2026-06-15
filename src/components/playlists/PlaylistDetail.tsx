// Playlist detail — the editable TEMPLATE. Rename/delete the playlist, edit its
// sequences (chapters) + their nodes, ▶ Play it into a frozen Setlist, and see
// the setlist history. Names for song/album nodes are resolved by id from the
// catalog (collections are cross-source, so we can't read the browser's scope).
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useCollectionsStore } from '../../store/useCollectionsStore';
import type {
  Playlist,
  PlaylistNode,
  Pocket,
  SequenceNode,
  Setlist,
} from '../../types/collections';
import { isAlbumNode, isPocketNode, isSongNode, isSequenceNode } from '../../types/collections';
import type { MusicItem } from '../../types/model';
import { getItem } from '../../storage/repo';
import { msToClock, clockToMs } from '../../lib/format';
import './playlists.css';

// ---------------------------------------------------------------------------
// One node row inside a sequence
// ---------------------------------------------------------------------------
function NodeRow(props: {
  node: PlaylistNode;
  playlistId: string;
  sequences: SequenceNode[];
  currentSeqId: string;
  nameFor: (node: PlaylistNode) => string;
  metaFor: (node: PlaylistNode) => string;
}) {
  const { node, playlistId, sequences, currentSeqId } = props;
  const removeNode = useCollectionsStore((s) => s.removeNode);
  const moveNode = useCollectionsStore((s) => s.moveNode);

  const kindLabel = isSongNode(node)
    ? 'song'
    : isAlbumNode(node)
      ? 'album'
      : isPocketNode(node)
        ? 'pocket'
        : 'sequence';
  const meta = props.metaFor(node);

  return (
    <div className="pdj-node" data-testid={`node-${node.nodeId}`}>
      <span className="pdj-node__kind">{kindLabel}</span>
      <span className="pdj-node__label">{props.nameFor(node)}</span>
      {meta && <span className="pdj-node__meta">{meta}</span>}
      {sequences.length > 1 && (
        <select
          className="pdj-node__move"
          value={currentSeqId}
          data-testid={`node-move-${node.nodeId}`}
          aria-label="Move to sequence"
          onChange={(e) => {
            if (e.target.value !== currentSeqId) {
              void moveNode(playlistId, node.nodeId, e.target.value);
            }
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
  nameFor: (node: PlaylistNode) => string;
  metaFor: (node: PlaylistNode) => string;
}) {
  const { playlist, seq, pockets, canRemove } = props;
  const renameSequence = useCollectionsStore((s) => s.renameSequence);
  const removeSequence = useCollectionsStore((s) => s.removeSequence);
  const setSequenceTarget = useCollectionsStore((s) => s.setSequenceTarget);
  const addToPlaylist = useCollectionsStore((s) => s.addToPlaylist);

  const [nameDraft, setNameDraft] = useState(seq.name);
  const [targetText, setTargetText] = useState(msToClock(seq.targetMs));
  const [addPocketId, setAddPocketId] = useState('');

  // Keep the local name field in sync if the underlying value changes. Buffered
  // locally so typing isn't reverted by the async store write (savePlaylist awaits
  // IndexedDB before set(), which lags a keystroke behind under React 18 batching).
  useEffect(() => {
    setNameDraft(seq.name);
  }, [seq.name]);

  // Keep the local target field in sync if the underlying value changes.
  useEffect(() => {
    setTargetText(msToClock(seq.targetMs));
  }, [seq.targetMs]);

  const commitName = () => {
    const trimmed = nameDraft.trim();
    if (!trimmed || trimmed === seq.name) {
      setNameDraft(seq.name);
      return;
    }
    void renameSequence(playlist.id, seq.nodeId, trimmed);
  };

  const commitTarget = () => {
    const ms = clockToMs(targetText); // '' -> undefined (clears it)
    void setSequenceTarget(playlist.id, seq.nodeId, ms);
  };

  const addPocket = () => {
    if (!addPocketId) return;
    void addToPlaylist(playlist.id, { kind: 'pocket', id: addPocketId }, seq.nodeId);
    setAddPocketId('');
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
          <p className="pdj-seq__empty">Empty — add a pocket below, or items from the browser.</p>
        ) : (
          seq.children.map((node) => (
            <NodeRow
              key={node.nodeId}
              node={node}
              playlistId={playlist.id}
              sequences={playlist.sequences}
              currentSeqId={seq.nodeId}
              nameFor={props.nameFor}
              metaFor={props.metaFor}
            />
          ))
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
  // Live-edited name; falls back to the stored name. Buffered locally so typing
  // isn't reverted by the async store write (savePlaylist awaits IndexedDB before
  // set(), so a controlled value lags a keystroke behind under React 18 batching).
  const [nameDraft, setNameDraft] = useState('');
  // Resolved song/album names, keyed by item id (cross-source catalog lookups).
  const [itemNames, setItemNames] = useState<Record<string, string>>({});

  useEffect(() => {
    void load();
  }, [load]);

  // Sync the name draft when the playlist arrives / changes externally.
  useEffect(() => {
    if (playlist) setNameDraft(playlist.name);
  }, [playlist?.id, playlist?.name]); // eslint-disable-line react-hooks/exhaustive-deps

  // Setlist history (reload after each Play via rev).
  useEffect(() => {
    if (!id) return;
    let live = true;
    void getSetlists(id).then((rows) => {
      if (live) setSetlists(rows);
    });
    return () => {
      live = false;
    };
  }, [id, getSetlists, rev]);

  // Resolve every song/album node label from the catalog by id.
  useEffect(() => {
    if (!playlist) return;
    const ids = new Set<string>();
    const walk = (nodes: PlaylistNode[]) => {
      for (const n of nodes) {
        if (isSongNode(n)) ids.add(n.songId);
        else if (isAlbumNode(n)) ids.add(n.albumId);
        else if (isSequenceNode(n)) walk(n.children);
      }
    };
    for (const seq of playlist.sequences) walk(seq.children);

    let live = true;
    const missing = [...ids].filter((x) => !(x in itemNames));
    if (missing.length === 0) return;
    void Promise.all(missing.map((x) => getItem(x))).then((items) => {
      if (!live) return;
      setItemNames((prev) => {
        const next = { ...prev };
        items.forEach((it: MusicItem | undefined, i) => {
          next[missing[i]] = it ? `${it.artist} — ${it.name}` : '(unknown item)';
        });
        return next;
      });
    });
    return () => {
      live = false;
    };
  }, [playlist, itemNames]);

  const pocketById = useMemo(() => new Map(pockets.map((p) => [p.id, p])), [pockets]);

  const nameFor = useCallback(
    (node: PlaylistNode): string => {
      if (isSongNode(node)) return itemNames[node.songId] ?? 'Loading…';
      if (isAlbumNode(node)) return itemNames[node.albumId] ?? 'Loading…';
      if (isPocketNode(node)) return pocketById.get(node.pocketId)?.name ?? '(missing pocket)';
      if (isSequenceNode(node)) return node.name;
      return '';
    },
    [itemNames, pocketById],
  );

  const metaFor = useCallback(
    (node: PlaylistNode): string => {
      if (isPocketNode(node)) {
        const p = pocketById.get(node.pocketId);
        if (!p) return '';
        const n = p.songIds.length + p.albumIds.length + p.childPocketIds.length;
        return `${n} ${n === 1 ? 'item' : 'items'}`;
      }
      if (isAlbumNode(node)) return 'album';
      return '';
    },
    [pocketById],
  );

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

      <p className="pdj-pl__count">
        {playlist.sequences.length}{' '}
        {playlist.sequences.length === 1 ? 'chapter' : 'chapters'}
      </p>

      <h2 className="pdj-pl__section-title">Sequences</h2>
      {playlist.sequences.map((seq) => (
        <SequenceSection
          key={seq.nodeId}
          playlist={playlist}
          seq={seq}
          pockets={pockets}
          canRemove={canRemoveSeq}
          nameFor={nameFor}
          metaFor={metaFor}
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
            <div
              key={sl.id}
              className="pdj-setlist-hist__row"
              data-testid={`setlist-row-${sl.id}`}
            >
              <Link
                to={`/playlists/${playlist.id}/setlist/${sl.id}`}
                className="pdj-setlist-hist__link"
              >
                <span className="pdj-setlist-hist__name">{sl.name ?? 'Set list'}</span>
                <span className="pdj-setlist-hist__meta">
                  {sl.tracks.length} {sl.tracks.length === 1 ? 'track' : 'tracks'} ·{' '}
                  {msToClock(sl.totalMs)} · {new Date(sl.generatedAt).toLocaleString()}
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
    </div>
  );
}
