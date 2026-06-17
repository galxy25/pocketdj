// The Browser: pick a source + item type, build filters, sort, and view the
// virtualized result. Pipeline: load(scope) -> applyFilters -> sort -> virtualize,
// memoized on (items, filterHash, sortHash).
import { useEffect, useMemo, useRef, useState } from 'react';
import { useAppStore } from '../../store/useAppStore';
import { useBrowserStore } from '../../store/useBrowserStore';
import { useDataStore } from '../../store/useDataStore';
import { useCollectionsStore } from '../../store/useCollectionsStore';
import { applyFilters, filterHash } from '../../engine/filterEngine';
import { sortItems, sortHash } from '../../engine/sortEngine';
import { membersOf, isMember } from '../../engine/membership';
import { DataSourceSelector } from './DataSourceSelector';
import { FilterBuilder } from './FilterBuilder';
import { SortControl } from './SortControl';
import { ItemGrid } from './ItemGrid';
import { EditItemModal } from './EditItemModal';
import { SongDetailModal } from '../starmap/SongDetailModal';
import { ImportExportBar } from './ImportExportBar';
import { getItem } from '../../storage/repo';
import { isAlbum, isSong, type SongItem } from '../../types/model';

const CARD_MIN = 184;

export function BrowserView() {
  const activeSourceId = useAppStore((s) => s.activeSourceId);
  const itemType = useAppStore((s) => s.itemType);
  const setItemType = useAppStore((s) => s.setItemType);
  const filter = useBrowserStore((s) => s.filter);
  const sort = useBrowserStore((s) => s.sort);

  const items = useDataStore((s) => s.items);
  const loading = useDataStore((s) => s.loading);
  const scopeKey = useDataStore((s) => s.scopeKey);
  const load = useDataStore((s) => s.load);

  // Collections for the "exclude songs already in playlist/pocket" filter (song mode).
  const playlists = useCollectionsStore((s) => s.playlists);
  const pockets = useCollectionsStore((s) => s.pockets);
  const loadCollections = useCollectionsStore((s) => s.load);
  // Selected collection ids to exclude members of (empty = show all).
  const [excludeIds, setExcludeIds] = useState<Set<string>>(new Set());
  useEffect(() => void loadCollections(), [loadCollections]);
  const toggleExclude = (id: string) =>
    setExcludeIds((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });

  // Only render once the loaded set matches the current (source, type) scope —
  // prevents a frame where, e.g., album items render as songs mid-switch.
  const ready = scopeKey === `${activeSourceId}:${itemType}`;

  const [editId, setEditId] = useState<string | null>(null);
  const [detailId, setDetailId] = useState<string | null>(null);
  const [detailAlbumName, setDetailAlbumName] = useState('');
  const [columns, setColumns] = useState(4);
  const wrapRef = useRef<HTMLDivElement>(null);

  // (re)load when scope changes
  useEffect(() => {
    load(activeSourceId, itemType);
  }, [activeSourceId, itemType, load]);

  // measure columns for the album grid
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setColumns(Math.max(1, Math.floor(el.clientWidth / CARD_MIN)));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const filtered = useMemo(
    () => sortItems(applyFilters(items, filter), sort),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [items, filterHash(filter), sortHash(sort)],
  );

  // Song mode: optionally exclude songs already in the selected playlists/pockets.
  const visible = useMemo(() => {
    if (itemType !== 'song' || excludeIds.size === 0) return filtered;
    const m = membersOf(excludeIds, playlists, pockets);
    return filtered.filter((it) => it.type !== 'song' || !isMember(it, m));
  }, [filtered, itemType, excludeIds, playlists, pockets]);

  const songsById = useMemo(() => {
    const map = new Map<string, SongItem>();
    for (const it of items) if (isSong(it)) map.set(it.id, it);
    return map;
  }, [items]);
  const detailSong = detailId ? songsById.get(detailId) ?? null : null;

  // Resolve the album name for the opened song. The loaded scope only holds
  // songs, so fetch the owning album by id; fall back to the song's artist.
  useEffect(() => {
    if (!detailSong) {
      setDetailAlbumName('');
      return;
    }
    let live = true;
    setDetailAlbumName(detailSong.artist || '');
    if (detailSong.albumId) {
      getItem(detailSong.albumId).then((it) => {
        if (live && it && isAlbum(it)) setDetailAlbumName(it.name);
      });
    }
    return () => {
      live = false;
    };
  }, [detailSong]);

  return (
    <div className="pdj-browser">
      <div className="pdj-browser__toolbar">
        <DataSourceSelector />
        <div className="pdj-field pdj-typeswitch" role="group" aria-label="Item type">
          <span className="pdj-field__label">Show</span>
          <div className="pdj-seg">
            <button
              className={itemType === 'album' ? 'is-active' : ''}
              data-testid="type-album"
              onClick={() => setItemType('album')}
            >
              Albums
            </button>
            <button
              className={itemType === 'song' ? 'is-active' : ''}
              data-testid="type-song"
              onClick={() => setItemType('song')}
            >
              Songs
            </button>
          </div>
        </div>
        <SortControl />
        <span className="pdj-browser__count" data-testid="result-count">
          {visible.length} / {items.length}
        </span>
        <div className="pdj-browser__spacer" />
        <ImportExportBar />
      </div>

      <FilterBuilder />

      {itemType === 'song' && (playlists.length > 0 || pockets.length > 0) && (
        <div className="pdj-exclude" data-testid="exclude-filter">
          <span className="pdj-exclude__label">Exclude songs in</span>
          <div className="pdj-exclude__chips">
            {playlists.map((p) => (
              <button
                key={p.id}
                type="button"
                className={`pdj-chip ${excludeIds.has(p.id) ? 'is-on' : ''}`}
                data-testid={`exclude-chip-${p.id}`}
                aria-pressed={excludeIds.has(p.id)}
                onClick={() => toggleExclude(p.id)}
              >
                ♫ {p.name}
              </button>
            ))}
            {pockets.map((p) => (
              <button
                key={p.id}
                type="button"
                className={`pdj-chip ${excludeIds.has(p.id) ? 'is-on' : ''}`}
                data-testid={`exclude-chip-${p.id}`}
                aria-pressed={excludeIds.has(p.id)}
                onClick={() => toggleExclude(p.id)}
              >
                ◖ {p.name}
              </button>
            ))}
            {excludeIds.size > 0 && (
              <button
                type="button"
                className="pdj-chip pdj-chip--clear"
                data-testid="exclude-clear"
                onClick={() => setExcludeIds(new Set())}
              >
                ✕ clear
              </button>
            )}
          </div>
        </div>
      )}

      <div className="pdj-browser__results" ref={wrapRef}>
        {loading || !ready ? (
          <div className="pdj-grid__empty">Loading…</div>
        ) : (
          <ItemGrid
            items={visible}
            itemType={itemType}
            columns={columns}
            onEdit={setEditId}
            onOpen={setDetailId}
          />
        )}
      </div>

      <EditItemModal
        itemId={editId}
        onClose={() => setEditId(null)}
        onSaved={() => useDataStore.getState().reload()}
      />

      <SongDetailModal
        song={detailSong}
        albumName={detailAlbumName}
        onClose={() => setDetailId(null)}
      />
    </div>
  );
}
