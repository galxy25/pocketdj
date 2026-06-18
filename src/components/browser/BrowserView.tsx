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
import { isAlbum, isSong, type SongItem, type MusicItem } from '../../types/model';
import { useSearchStore } from '../../store/useSearchStore';
import { esSearch } from '../../search/esClient';

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

  // Online search (OpenSearch). The toggle only appears once creds are set in Settings.
  const searchOnline = useSearchStore((s) => s.online);
  const setSearchOnline = useSearchStore((s) => s.setOnline);
  const hasSearchCreds = useSearchStore((s) => !!s.creds);
  const sigCreds = useSearchStore((s) => s.sigCreds);
  const [searchText, setSearchText] = useState('');
  const [esItems, setEsItems] = useState<MusicItem[]>([]);
  const [esTotal, setEsTotal] = useState(0);
  const [esTook, setEsTook] = useState(0);
  const [esBusy, setEsBusy] = useState(false);
  const [esError, setEsError] = useState('');
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

  // Selected source NAMES (for the ES `source` filter); undefined = all sources.
  const selectedSourceNames = useMemo(() => {
    if (sourceMode === 'all') return undefined;
    const byId = new Map(sources.map((s) => [s.id, s.name]));
    const names = selectedSourceIds.map((id) => byId.get(id)).filter(Boolean) as string[];
    return names.length ? names : [];
  }, [sourceMode, selectedSourceIds, sources]);

  // ONLINE mode: debounce the query → OpenSearch (across title/artist/album/lyrics/sentiment).
  useEffect(() => {
    if (!searchOnline) return;
    const creds = sigCreds();
    if (!creds) return;
    let live = true;
    setEsBusy(true);
    setEsError('');
    const t = setTimeout(async () => {
      try {
        const r = await esSearch(
          { q: searchText, type: itemType, sources: selectedSourceNames, size: 80 },
          creds,
        );
        if (!live) return;
        setEsItems(r.items);
        setEsTotal(r.total);
        setEsTook(r.tookMs);
      } catch (e) {
        if (live) { setEsError((e as Error).message); setEsItems([]); setEsTotal(0); }
      } finally {
        if (live) setEsBusy(false);
      }
    }, 250);
    return () => { live = false; clearTimeout(t); };
  }, [searchOnline, searchText, itemType, selectedSourceNames, sigCreds]);

  // OFFLINE text filter: a quick local title/artist substring over the visible set.
  const offlineFiltered = useMemo(() => {
    const q = searchText.trim().toLowerCase();
    if (!q) return visible;
    return visible.filter(
      (it) => it.name.toLowerCase().includes(q) || it.artist.toLowerCase().includes(q),
    );
  }, [visible, searchText]);

  const gridItems = searchOnline ? esItems : offlineFiltered;

  const songsById = useMemo(() => {
    const map = new Map<string, SongItem>();
    for (const it of items) if (isSong(it)) map.set(it.id, it);
    for (const it of esItems) if (isSong(it)) map.set(it.id, it); // online hits too
    return map;
  }, [items, esItems]);
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
        <input
          className="pdj-input pdj-browser__search"
          type="search"
          placeholder={searchOnline ? 'Search everything (online)…' : 'Filter title / artist…'}
          data-testid="browser-search"
          value={searchText}
          onChange={(e) => setSearchText(e.target.value)}
        />
        {hasSearchCreds && (
          <button
            type="button"
            className={`pdj-btn pdj-btn--ghost pdj-browser__mode ${searchOnline ? 'is-online' : ''}`}
            data-testid="search-mode-toggle"
            title={searchOnline ? 'Online — searching via OpenSearch' : 'Offline — searching this device'}
            onClick={() => setSearchOnline(!searchOnline)}
          >
            {searchOnline ? '⚡ Online' : '⌂ Offline'}
          </button>
        )}
        <span className="pdj-browser__count" data-testid="result-count">
          {searchOnline ? `${esItems.length} / ${esTotal}` : `${gridItems.length} / ${items.length}`}
          {searchOnline && esTook ? ` · ${esTook}ms` : ''}
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
        {searchOnline ? (
          esError ? (
            <div className="pdj-grid__empty">Online search error: {esError}</div>
          ) : esBusy && esItems.length === 0 ? (
            <div className="pdj-grid__empty">Searching OpenSearch…</div>
          ) : esItems.length === 0 ? (
            <div className="pdj-grid__empty">No matches{searchText ? ` for “${searchText}”` : ''}.</div>
          ) : (
            <ItemGrid items={gridItems} itemType={itemType} columns={columns} onEdit={setEditId} onOpen={setDetailId} />
          )
        ) : noSources ? (
          <div className="pdj-grid__empty">No sources selected — pick at least one source above.</div>
        ) : loading || !ready ? (
          <div className="pdj-grid__empty">Loading…</div>
        ) : (
          <ItemGrid
            items={gridItems}
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
