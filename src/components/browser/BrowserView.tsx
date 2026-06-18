// The Browser: pick a source + item type, build filters, sort, and view the
// virtualized result. Pipeline: load(scope) -> applyFilters -> sort -> virtualize,
// memoized on (items, filterHash, sortHash).
import { useEffect, useMemo, useRef, useState } from 'react';
import { useAppStore, scopeFor, scopeKeyOf } from '../../store/useAppStore';
import { useBrowserStore } from '../../store/useBrowserStore';
import { useDataStore } from '../../store/useDataStore';
import { useCollectionsStore } from '../../store/useCollectionsStore';
import { applyFilters, filterHash } from '../../engine/filterEngine';
import { sortItems, sortHash } from '../../engine/sortEngine';
import { membersOf, isMember } from '../../engine/membership';
import { DataSourceSelector } from './DataSourceSelector';
import { MembershipFilter } from './MembershipFilter';
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
  const sourceMode = useAppStore((s) => s.sourceMode);
  const selectedSourceIds = useAppStore((s) => s.selectedSourceIds);
  const sources = useAppStore((s) => s.sources);
  const itemType = useAppStore((s) => s.itemType);
  const setItemType = useAppStore((s) => s.setItemType);
  // Resolved multi-source scope (ALL_SOURCE_ID | id[] | []) + its cache key.
  const scope = useMemo(
    () => scopeFor(sourceMode, selectedSourceIds, sources),
    [sourceMode, selectedSourceIds, sources],
  );
  const noSources = Array.isArray(scope) && scope.length === 0;
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
  // HIDE filter: drop songs already in ANY (excludeAny) or a chosen subset (excludeIds).
  const [excludeAny, setExcludeAny] = useState(false);
  const [excludeIds, setExcludeIds] = useState<Set<string>>(new Set());
  // SHOW filter: keep ONLY songs in ANY (includeAny) or a chosen subset (includeIds).
  const [includeAny, setIncludeAny] = useState(false);
  const [includeIds, setIncludeIds] = useState<Set<string>>(new Set());
  useEffect(() => void loadCollections(), [loadCollections]);

  // Only render once the loaded set matches the current (scope, type) — prevents
  // a frame where, e.g., album items render as songs mid-switch.
  const ready = scopeKey === `${scopeKeyOf(scope)}:${itemType}`;

  const [editId, setEditId] = useState<string | null>(null);
  const [detailId, setDetailId] = useState<string | null>(null);
  const [detailAlbumName, setDetailAlbumName] = useState('');
  const [columns, setColumns] = useState(4);
  const wrapRef = useRef<HTMLDivElement>(null);

  // (re)load when scope changes (keyed on the resolved scope, not the selection)
  const scopeKeyDep = scopeKeyOf(scope);
  useEffect(() => {
    load(scope, itemType);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scopeKeyDep, itemType, load]);

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

  // Song mode: apply the SHOW filter (keep only songs in the selected collections)
  // and/or the HIDE filter (drop songs in the selected collections). "any" expands
  // to every collection. Both can be on at once (intersection of constraints).
  const visible = useMemo(() => {
    const hideActive = excludeAny || excludeIds.size > 0;
    const showActive = includeAny || includeIds.size > 0;
    if (itemType !== 'song' || (!hideActive && !showActive)) return filtered;
    const allIds = () => new Set<string>([...playlists.map((p) => p.id), ...pockets.map((p) => p.id)]);
    const hideM = hideActive ? membersOf(excludeAny ? allIds() : excludeIds, playlists, pockets) : null;
    const showM = showActive ? membersOf(includeAny ? allIds() : includeIds, playlists, pockets) : null;
    return filtered.filter((it) => {
      if (it.type !== 'song') return true;
      if (showM && !isMember(it, showM)) return false;
      if (hideM && isMember(it, hideM)) return false;
      return true;
    });
  }, [filtered, itemType, excludeAny, excludeIds, includeAny, includeIds, playlists, pockets]);

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
        <div className="pdj-browser__subbar">
          <MembershipFilter
            variant="show"
            playlists={playlists}
            pockets={pockets}
            any={includeAny}
            setAny={setIncludeAny}
            ids={includeIds}
            setIds={setIncludeIds}
          />
          <MembershipFilter
            variant="hide"
            playlists={playlists}
            pockets={pockets}
            any={excludeAny}
            setAny={setExcludeAny}
            ids={excludeIds}
            setIds={setExcludeIds}
          />
        </div>
      )}

      <div className="pdj-browser__results" ref={wrapRef}>
        {noSources ? (
          <div className="pdj-grid__empty">No sources selected — pick at least one source above.</div>
        ) : loading || !ready ? (
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
