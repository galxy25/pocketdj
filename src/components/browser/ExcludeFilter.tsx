// "Hide songs already in…" multi-select dropdown for the song list. Scales better
// than an inline chip row: a compact trigger + a scrollable checkbox menu. Either
// hide songs in ANY playlist/pocket (show only unplaced) or scope to a checked
// subset. Mobile-friendly (big tap targets, scrolls, taps outside to close).
import { useEffect, useRef, useState } from 'react';
import type { Playlist, Pocket } from '../../types/collections';

export function ExcludeFilter(props: {
  playlists: Playlist[];
  pockets: Pocket[];
  excludeAny: boolean;
  setExcludeAny: (v: boolean | ((p: boolean) => boolean)) => void;
  excludeIds: Set<string>;
  setExcludeIds: (v: Set<string> | ((p: Set<string>) => Set<string>)) => void;
}) {
  const { playlists, pockets, excludeAny, setExcludeAny, excludeIds, setExcludeIds } = props;
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

  const toggle = (id: string) =>
    setExcludeIds((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });

  const active = excludeAny || excludeIds.size > 0;
  const summary = excludeAny ? 'any collection' : excludeIds.size ? `${excludeIds.size} selected` : 'off';

  return (
    <div className="pdj-exfilter" ref={ref} data-testid="exclude-filter">
      <button
        type="button"
        className={`pdj-exfilter__trigger ${active ? 'is-active' : ''}`}
        data-testid="exclude-trigger"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        Hide added: <strong>{summary}</strong> <span className="pdj-exfilter__caret">▾</span>
      </button>

      {open && (
        <div className="pdj-exfilter__menu" data-testid="exclude-menu" role="listbox">
          <label className="pdj-exfilter__opt pdj-exfilter__opt--any">
            <input
              type="checkbox"
              checked={excludeAny}
              data-testid="exclude-any"
              onChange={() => setExcludeAny((v) => !v)}
            />
            <span>Any playlist / pocket <em>(show only unplaced)</em></span>
          </label>

          <fieldset className="pdj-exfilter__group" disabled={excludeAny}>
            {playlists.length > 0 && <div className="pdj-exfilter__head">Playlists</div>}
            {playlists.map((p) => (
              <label key={p.id} className="pdj-exfilter__opt">
                <input
                  type="checkbox"
                  checked={excludeIds.has(p.id)}
                  data-testid={`exclude-chip-${p.id}`}
                  onChange={() => toggle(p.id)}
                />
                <span>♫ {p.name}</span>
              </label>
            ))}
            {pockets.length > 0 && <div className="pdj-exfilter__head">Pockets</div>}
            {pockets.map((p) => (
              <label key={p.id} className="pdj-exfilter__opt">
                <input
                  type="checkbox"
                  checked={excludeIds.has(p.id)}
                  data-testid={`exclude-chip-${p.id}`}
                  onChange={() => toggle(p.id)}
                />
                <span>◖ {p.name}</span>
              </label>
            ))}
          </fieldset>

          {active && (
            <button
              type="button"
              className="pdj-exfilter__clear"
              data-testid="exclude-clear"
              onClick={() => {
                setExcludeAny(false);
                setExcludeIds(new Set());
              }}
            >
              Clear
            </button>
          )}
        </div>
      )}
    </div>
  );
}
