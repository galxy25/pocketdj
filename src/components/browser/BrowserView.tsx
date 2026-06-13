// The Browser: pick a source + item type, build filters, sort, and view the
// virtualized result. Pipeline: load(scope) -> applyFilters -> sort -> virtualize,
// memoized on (items, filterHash, sortHash).
import { useEffect, useMemo, useRef, useState } from 'react';
import { useAppStore } from '../../store/useAppStore';
import { useBrowserStore } from '../../store/useBrowserStore';
import { useDataStore } from '../../store/useDataStore';
import { applyFilters, filterHash } from '../../engine/filterEngine';
import { sortItems, sortHash } from '../../engine/sortEngine';
import { DataSourceSelector } from './DataSourceSelector';
import { FilterBuilder } from './FilterBuilder';
import { SortControl } from './SortControl';
import { ItemGrid } from './ItemGrid';
import { EditItemModal } from './EditItemModal';
import { ImportExportBar } from './ImportExportBar';

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

  // Only render once the loaded set matches the current (source, type) scope —
  // prevents a frame where, e.g., album items render as songs mid-switch.
  const ready = scopeKey === `${activeSourceId}:${itemType}`;

  const [editId, setEditId] = useState<string | null>(null);
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
          {filtered.length} / {items.length}
        </span>
        <div className="pdj-browser__spacer" />
        <ImportExportBar />
      </div>

      <FilterBuilder />

      <div className="pdj-browser__results" ref={wrapRef}>
        {loading || !ready ? (
          <div className="pdj-grid__empty">Loading…</div>
        ) : (
          <ItemGrid items={filtered} itemType={itemType} columns={columns} onEdit={setEditId} />
        )}
      </div>

      <EditItemModal
        itemId={editId}
        onClose={() => setEditId(null)}
        onSaved={() => useDataStore.getState().reload()}
      />
    </div>
  );
}
