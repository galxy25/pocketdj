// Playlists mode — the index. Lists every playlist template (a playlist is an
// ordered set of "sequences"/chapters); create one to start, then open it to
// edit + ▶ Play it into a frozen Setlist. Cross-source, so it reads from the
// collections store, not the browser's current scope.
import { useEffect, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useCollectionsStore } from '../../store/useCollectionsStore';
import type { Playlist, PlaylistNode } from '../../types/collections';
import { isSequenceNode } from '../../types/collections';
import { importPlaylistZip } from '../../storage/playlistTransfer';
import './playlists.css';

/** Total item count across a playlist's sequences (recursive: counts nested nodes). */
function countItems(playlist: Playlist): number {
  let n = 0;
  const walk = (nodes: PlaylistNode[]) => {
    for (const node of nodes) {
      if (isSequenceNode(node)) walk(node.children);
      else n += 1;
    }
  };
  for (const seq of playlist.sequences) walk(seq.children);
  return n;
}

export function PlaylistsView() {
  const navigate = useNavigate();
  const load = useCollectionsStore((s) => s.load);
  const createPlaylist = useCollectionsStore((s) => s.createPlaylist);
  const playlists = useCollectionsStore((s) => s.playlists);
  // Subscribe to rev so the list re-renders after any write.
  useCollectionsStore((s) => s.rev);

  const [adding, setAdding] = useState(false);
  const [name, setName] = useState('');
  const [importing, setImporting] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    void load();
  }, [load]);

  const onImportFile = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = ''; // allow re-importing the same file
    if (!file) return;
    setImporting(true);
    try {
      const r = await importPlaylistZip(await file.arrayBuffer());
      await load();
      navigate(`/playlists/${r.playlistId}`);
    } catch (err) {
      alert(`Import failed: ${(err as Error).message}`);
    } finally {
      setImporting(false);
    }
  };

  const confirmCreate = async () => {
    const trimmed = name.trim();
    if (!trimmed) return;
    const created = await createPlaylist(trimmed);
    setName('');
    setAdding(false);
    navigate(`/playlists/${created.id}`);
  };

  return (
    <div className="pdj-playlists" data-testid="playlists-view">
      <div className="pdj-playlists__header">
        <div>
          <h1 className="pdj-playlists__title">Playlists</h1>
          <p className="pdj-playlists__subtitle">
            Build a template of chapters, then ▶ Play it into a set list.
          </p>
        </div>
        <div className="pdj-playlists__spacer" />
        <input
          ref={fileRef}
          type="file"
          accept=".zip"
          style={{ display: 'none' }}
          data-testid="playlist-import-input"
          onChange={(e) => void onImportFile(e)}
        />
        <button
          type="button"
          className="pdj-btn pdj-btn--ghost"
          data-testid="playlist-import"
          disabled={importing}
          title="Import a playlist exported from PocketDJ"
          onClick={() => fileRef.current?.click()}
        >
          {importing ? '…' : '⤒ Import'}
        </button>
        {adding ? (
          <div className="pdj-addcol__new">
            <input
              type="text"
              autoFocus
              value={name}
              placeholder="Playlist name"
              data-testid="playlist-create-input"
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') void confirmCreate();
                else if (e.key === 'Escape') {
                  setAdding(false);
                  setName('');
                }
              }}
            />
            <button
              type="button"
              className="pdj-btn pdj-btn--sm"
              data-testid="playlist-create-confirm"
              disabled={!name.trim()}
              onClick={() => void confirmCreate()}
            >
              Create
            </button>
          </div>
        ) : (
          <button
            type="button"
            className="pdj-btn"
            data-testid="playlist-create"
            onClick={() => setAdding(true)}
          >
            ＋ New playlist
          </button>
        )}
      </div>

      {playlists.length === 0 ? (
        <div className="pdj-pl__empty">
          No playlists yet. Create one, or use “＋ Add to…” on any song or album.
        </div>
      ) : (
        <div className="pdj-playlists__list">
          {playlists.map((p) => {
            const seqCount = p.sequences.length;
            const items = countItems(p);
            return (
              <Link
                key={p.id}
                to={`/playlists/${p.id}`}
                className="pdj-playlists__row"
                data-testid={`playlist-row-${p.id}`}
              >
                <span className="pdj-playlists__row-name">{p.name}</span>
                <span className="pdj-playlists__row-meta">
                  {seqCount} {seqCount === 1 ? 'sequence' : 'sequences'} · {items}{' '}
                  {items === 1 ? 'item' : 'items'}
                </span>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}
