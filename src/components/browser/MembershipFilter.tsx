// Collection-membership filter for the song list. Two variants, same UI pattern
// (a compact trigger + a scrollable checkbox menu — scales better than chips):
//   variant 'hide' → hide songs already in ANY / a chosen subset of collections
//                    (the "any" option leaves only UNPLACED songs).
//   variant 'show' → show ONLY songs that ARE in ANY / a chosen subset
//                    (the "any" option leaves only PLACED songs).
// Both can be active at once; the browser intersects their constraints.
// Mobile-friendly (big tap targets, scrolls, taps outside to close).
import { useEffect, useRef, useState } from 'react';
import type { Playlist, Pocket } from '../../types/collections';

export type MembershipVariant = 'hide' | 'show';

const COPY: Record<MembershipVariant, { label: string; anyHint: string; prefix: string }> = {
  hide: { label: 'Hide added', anyHint: '(show only unplaced)', prefix: 'exclude' },
  show: { label: 'Show added', anyHint: '(only placed)', prefix: 'include' },
};

export function MembershipFilter(props: {
  variant: MembershipVariant;
  playlists: Playlist[];
  pockets: Pocket[];
  any: boolean;
  setAny: (v: boolean | ((p: boolean) => boolean)) => void;
  ids: Set<string>;
  setIds: (v: Set<string> | ((p: Set<string>) => Set<string>)) => void;
}) {
  const { variant, playlists, pockets, any, setAny, ids, setIds } = props;
  const c = COPY[variant];
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
    setIds((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });

  const active = any || ids.size > 0;
  const summary = any ? 'any collection' : ids.size ? `${ids.size} selected` : 'off';

  return (
    <div className="pdj-exfilter" ref={ref} data-testid={`${c.prefix}-filter`}>
      <button
        type="button"
        className={`pdj-exfilter__trigger ${active ? 'is-active' : ''}`}
        data-testid={`${c.prefix}-trigger`}
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        {c.label}: <strong>{summary}</strong> <span className="pdj-exfilter__caret">▾</span>
      </button>

      {open && (
        <div className="pdj-exfilter__menu" data-testid={`${c.prefix}-menu`} role="listbox">
          <label className="pdj-exfilter__opt pdj-exfilter__opt--any">
            <input
              type="checkbox"
              checked={any}
              data-testid={`${c.prefix}-any`}
              onChange={() => setAny((v) => !v)}
            />
            <span>Any playlist / pocket <em>{c.anyHint}</em></span>
          </label>

          <fieldset className="pdj-exfilter__group" disabled={any}>
            {playlists.length > 0 && <div className="pdj-exfilter__head">Playlists</div>}
            {playlists.map((p) => (
              <label key={p.id} className="pdj-exfilter__opt">
                <input
                  type="checkbox"
                  checked={ids.has(p.id)}
                  data-testid={`${c.prefix}-chip-${p.id}`}
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
                  checked={ids.has(p.id)}
                  data-testid={`${c.prefix}-chip-${p.id}`}
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
              data-testid={`${c.prefix}-clear`}
              onClick={() => {
                setAny(false);
                setIds(new Set());
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
