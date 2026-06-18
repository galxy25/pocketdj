// Multi-source picker: show data for ALL sources, NONE, or a chosen subset.
// A compact trigger + a scrollable checkbox menu (same pattern as MembershipFilter),
// which scales as more sources (vinyl, Apple Music, …) are added. Mobile-friendly.
import { useEffect, useRef, useState } from 'react';
import { useAppStore } from '../../store/useAppStore';

export function DataSourceSelector() {
  const sources = useAppStore((s) => s.sources);
  const sourceMode = useAppStore((s) => s.sourceMode);
  const selectedSourceIds = useAppStore((s) => s.selectedSourceIds);
  const selectAll = useAppStore((s) => s.selectAllSources);
  const selectNone = useAppStore((s) => s.selectNoSources);
  const toggleSource = useAppStore((s) => s.toggleSource);

  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', onDown);
    return () => document.removeEventListener('pointerdown', onDown);
  }, [open]);

  const isAll = sourceMode === 'all';
  const checked = (id: string) => isAll || selectedSourceIds.includes(id);
  const selectedCount = isAll
    ? sources.length
    : selectedSourceIds.filter((id) => sources.some((s) => s.id === id)).length;
  const summary = isAll
    ? 'All sources'
    : selectedCount === 0
      ? 'None'
      : `${selectedCount} of ${sources.length}`;

  return (
    <div className="pdj-field pdj-source pdj-exfilter" ref={ref} data-testid="data-source-selector">
      <span className="pdj-field__label">Sources</span>
      <button
        type="button"
        className={`pdj-exfilter__trigger ${selectedCount > 0 ? 'is-active' : ''}`}
        data-testid="source-trigger"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        <strong>{summary}</strong> <span className="pdj-exfilter__caret">▾</span>
      </button>

      {open && (
        <div className="pdj-exfilter__menu" data-testid="source-menu" role="listbox">
          <label className="pdj-exfilter__opt pdj-exfilter__opt--any">
            <input
              type="checkbox"
              checked={isAll}
              data-testid="source-all"
              onChange={() => (isAll ? selectNone() : selectAll())}
            />
            <span>All sources <em>(incl. ones added later)</em></span>
          </label>

          <fieldset className="pdj-exfilter__group">
            {sources.length === 0 && <div className="pdj-exfilter__head">No sources imported yet</div>}
            {sources.map((s) => (
              <label key={s.id} className="pdj-exfilter__opt">
                <input
                  type="checkbox"
                  checked={checked(s.id)}
                  data-testid={`source-opt-${s.id}`}
                  onChange={() => toggleSource(s.id)}
                />
                <span>
                  {s.type === 'digital' ? '♪' : '⬤'} {s.name}{' '}
                  <em>({s.itemCount.albums} · {s.itemCount.songs})</em>
                </span>
              </label>
            ))}
          </fieldset>

          {!isAll && (
            <button type="button" className="pdj-exfilter__clear" data-testid="source-reset" onClick={selectAll}>
              Reset to all
            </button>
          )}
        </div>
      )}
    </div>
  );
}
