// Pockets mode — detail. Edit a pocket's name, delete it, manage its members
// (songs + albums resolved by id from the catalog) and nest other pockets under
// it (cycle-guarded by the store). Members are cross-source, so names are
// resolved via the repo, not the browser's current scope.
import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useCollectionsStore } from '../../store/useCollectionsStore';
import { getItem } from '../../storage/repo';
import type { MusicItem, SongItem } from '../../types/model';
import { isSong } from '../../types/model';
import { SongDetailModal } from '../starmap/SongDetailModal';
import './pockets.css';

export function PocketDetail(): JSX.Element {
  const { id = '' } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const load = useCollectionsStore((s) => s.load);
  const pockets = useCollectionsStore((s) => s.pockets);
  useCollectionsStore((s) => s.rev);
  const renamePocket = useCollectionsStore((s) => s.renamePocket);
  const deletePocket = useCollectionsStore((s) => s.deletePocket);
  const removeFromPocket = useCollectionsStore((s) => s.removeFromPocket);
  const addChildPocket = useCollectionsStore((s) => s.addChildPocket);

  const pocket = pockets.find((p) => p.id === id);

  // Resolved catalog items for direct song + album members (cross-source, by id).
  const [items, setItems] = useState<Map<string, MusicItem>>(new Map());
  // Song-detail popover (the same modal as browser / solar-system) for a clicked song.
  const [openSong, setOpenSong] = useState<SongItem | null>(null);
  const [openAlbumName, setOpenAlbumName] = useState('');
  // Live-edited name; falls back to the stored name.
  const [nameDraft, setNameDraft] = useState('');
  const [childPick, setChildPick] = useState('');
  const [cycleWarn, setCycleWarn] = useState(false);

  useEffect(() => {
    void load();
  }, [load]);

  // Keep the name draft synced when the pocket arrives / changes externally.
  useEffect(() => {
    if (pocket) setNameDraft(pocket.name);
  }, [pocket?.id, pocket?.name]); // eslint-disable-line react-hooks/exhaustive-deps

  // Resolve member ids -> catalog items whenever the membership changes.
  const memberKey = pocket ? [...pocket.songIds, ...pocket.albumIds].join(',') : '';
  useEffect(() => {
    if (!pocket) return;
    let cancelled = false;
    const ids = [...pocket.songIds, ...pocket.albumIds];
    (async () => {
      const resolved = await Promise.all(ids.map((mid) => getItem(mid)));
      if (cancelled) return;
      const next = new Map<string, MusicItem>();
      ids.forEach((mid, i) => {
        const it = resolved[i] as MusicItem | undefined;
        if (it) next.set(mid, it);
      });
      setItems(next);
    })();
    return () => {
      cancelled = true;
    };
  }, [memberKey]); // eslint-disable-line react-hooks/exhaustive-deps

  // Other pockets eligible as children (exclude self).
  const otherPockets = useMemo(
    () => pockets.filter((p) => p.id !== id),
    [pockets, id],
  );

  if (!pocket) {
    return (
      <div className="pdj-pocket" data-testid="pocket-detail">
        <Link to="/pockets" className="pdj-pocket__back">
          ← Pockets
        </Link>
        <div className="pdj-pocket__missing">Pocket not found.</div>
      </div>
    );
  }

  const commitName = () => {
    const trimmed = nameDraft.trim();
    if (!trimmed || trimmed === pocket.name) {
      setNameDraft(pocket.name);
      return;
    }
    void renamePocket(pocket.id, trimmed);
  };

  const onDelete = async () => {
    await deletePocket(pocket.id);
    navigate('/pockets');
  };

  const onAddChild = async () => {
    if (!childPick) return;
    const ok = await addChildPocket(pocket.id, childPick);
    if (!ok) {
      setCycleWarn(true);
      return;
    }
    setCycleWarn(false);
    setChildPick('');
  };

  // Clicking a song member opens the same read-only detail popover as the browser.
  const openSongDetail = async (sid: string) => {
    const it = items.get(sid);
    if (!it || !isSong(it)) return;
    let albumName = '';
    if (it.albumId) {
      const a = await getItem(it.albumId);
      albumName = a?.name ?? '';
    }
    setOpenAlbumName(albumName);
    setOpenSong(it);
  };

  const childPockets = pocket.childPocketIds
    .map((cid) => pockets.find((p) => p.id === cid))
    .filter((p): p is NonNullable<typeof p> => p != null);

  const hasMembers = pocket.songIds.length > 0 || pocket.albumIds.length > 0;

  return (
    <div className="pdj-pocket" data-testid="pocket-detail">
      <Link to="/pockets" className="pdj-pocket__back">
        ← Pockets
      </Link>

      <div className="pdj-pocket__head">
        <input
          className="pdj-pocket__name"
          data-testid="pocket-rename"
          aria-label="Pocket name"
          value={nameDraft}
          onChange={(e) => setNameDraft(e.target.value)}
          onBlur={commitName}
          onKeyDown={(e) => {
            if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
            else if (e.key === 'Escape') setNameDraft(pocket.name);
          }}
        />
        <span className="pdj-pockets__kind">{pocket.kind}</span>
        <button
          type="button"
          className="pdj-btn pdj-btn--sm pdj-btn--danger"
          data-testid="pocket-delete"
          onClick={() => void onDelete()}
        >
          Delete
        </button>
      </div>

      <p className="pdj-pocket__note">
        A harmonic pocket groups songs, albums, and nested pockets that mix well together. Reference
        it from a playlist to pull these in — and keep auto-updating as you add more.
      </p>

      <section className="pdj-pocket__section">
        <h2 className="pdj-pocket__heading">
          Members ({pocket.songIds.length + pocket.albumIds.length})
        </h2>
        {!hasMembers ? (
          <p className="pdj-pocket__empty">
            No songs or albums yet. Add them from the browser via “＋ Add to…”.
          </p>
        ) : (
          <div className="pdj-pocket__members">
            {pocket.songIds.map((sid) => {
              const it = items.get(sid);
              const song = it && isSong(it) ? it : undefined;
              return (
                <div className="pdj-pocket__member" key={sid} data-testid={`pocket-member-${sid}`}>
                  <button
                    type="button"
                    className="pdj-pocket__member-main pdj-pocket__member-main--btn"
                    data-testid={`pocket-member-open-${sid}`}
                    onClick={() => void openSongDetail(sid)}
                    title="Song details"
                  >
                    <span className="pdj-pocket__member-top">
                      <span className="pdj-pocket__member-type">Song</span>
                      <span className="pdj-pocket__member-name">{it?.name ?? sid}</span>
                      {it?.artist && <span className="pdj-pocket__member-artist">{it.artist}</span>}
                    </span>
                    <span className="pdj-pocket__member-meta">
                      {song?.bpm != null && <span className="pdj-pocket__bpm">{song.bpm} BPM</span>}
                      {song?.camelot && <span className="pdj-pocket__key">{song.camelot}</span>}
                      {song && song.bpm == null && !song.camelot && (
                        <span className="pdj-pocket__nokey">no audio analysis</span>
                      )}
                    </span>
                  </button>
                  <button
                    type="button"
                    className="pdj-btn pdj-btn--sm pdj-btn--ghost"
                    data-testid={`pocket-member-remove-${sid}`}
                    aria-label={`Remove ${it?.name ?? 'song'}`}
                    onClick={() => void removeFromPocket(pocket.id, { kind: 'song', id: sid })}
                  >
                    Remove
                  </button>
                </div>
              );
            })}
            {pocket.albumIds.map((aid) => {
              const it = items.get(aid);
              const album = it && !isSong(it) ? it : undefined;
              return (
                <div className="pdj-pocket__member" key={aid} data-testid={`pocket-member-${aid}`}>
                  <button
                    type="button"
                    className="pdj-pocket__member-main pdj-pocket__member-main--btn"
                    data-testid={`pocket-member-open-${aid}`}
                    onClick={() => navigate(`/album/${aid}`)}
                    title="Open album"
                  >
                    <span className="pdj-pocket__member-top">
                      <span className="pdj-pocket__member-type">Album</span>
                      <span className="pdj-pocket__member-name">{it?.name ?? aid}</span>
                      {it?.artist && <span className="pdj-pocket__member-artist">{it.artist}</span>}
                    </span>
                    {(album?.audioBpm != null || album?.audioCamelot) && (
                      <span className="pdj-pocket__member-meta">
                        {album?.audioBpm != null && (
                          <span className="pdj-pocket__bpm">~{album.audioBpm} BPM</span>
                        )}
                        {album?.audioCamelot && <span className="pdj-pocket__key">{album.audioCamelot}</span>}
                      </span>
                    )}
                  </button>
                  <button
                    type="button"
                    className="pdj-btn pdj-btn--sm pdj-btn--ghost"
                    data-testid={`pocket-member-remove-${aid}`}
                    aria-label={`Remove ${it?.name ?? 'album'}`}
                    onClick={() => void removeFromPocket(pocket.id, { kind: 'album', id: aid })}
                  >
                    Remove
                  </button>
                </div>
              );
            })}
          </div>
        )}
      </section>

      <section className="pdj-pocket__section">
        <h2 className="pdj-pocket__heading">Child pockets ({pocket.childPocketIds.length})</h2>
        {childPockets.length === 0 ? (
          <p className="pdj-pocket__empty">No nested pockets.</p>
        ) : (
          <div className="pdj-pocket__members">
            {childPockets.map((c) => (
              <div className="pdj-pocket__member" key={c.id} data-testid={`pocket-child-${c.id}`}>
                <span className="pdj-pocket__member-main">
                  <span className="pdj-pocket__member-type">Pocket</span>
                  <Link to={`/pockets/${c.id}`} className="pdj-pocket__member-name">
                    {c.name}
                  </Link>
                </span>
                <button
                  type="button"
                  className="pdj-btn pdj-btn--sm pdj-btn--ghost"
                  data-testid={`pocket-child-remove-${c.id}`}
                  aria-label={`Remove ${c.name}`}
                  onClick={() => void removeFromPocket(pocket.id, { kind: 'pocket', id: c.id })}
                >
                  Remove
                </button>
              </div>
            ))}
          </div>
        )}

        {otherPockets.length > 0 && (
          <div className="pdj-pocket__add-child">
            <select
              data-testid="pocket-add-child"
              aria-label="Add child pocket"
              value={childPick}
              onChange={(e) => {
                setChildPick(e.target.value);
                setCycleWarn(false);
              }}
            >
              <option value="">Add a child pocket…</option>
              {otherPockets.map((p) => (
                <option key={p.id} value={p.id} disabled={pocket.childPocketIds.includes(p.id)}>
                  {p.name}
                  {pocket.childPocketIds.includes(p.id) ? ' (already nested)' : ''}
                </option>
              ))}
            </select>
            <button
              type="button"
              className="pdj-btn pdj-btn--sm"
              data-testid="pocket-add-child-confirm"
              disabled={!childPick}
              onClick={() => void onAddChild()}
            >
              Nest
            </button>
          </div>
        )}
        {cycleWarn && (
          <p className="pdj-pocket__warn" data-testid="pocket-cycle-warning">
            Can’t nest that — it would create a cycle.
          </p>
        )}
      </section>

      <SongDetailModal
        song={openSong}
        albumName={openAlbumName}
        onClose={() => setOpenSong(null)}
      />
    </div>
  );
}
