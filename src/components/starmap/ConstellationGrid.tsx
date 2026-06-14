// Mobile constellation grid: a vertical-scrolling 2-column grid of constellation CARDS
// (instead of the pan/zoom SVG scatter, whose labels are illegible on a phone). ~4 cards
// fill the screen; free-scroll to the rest. Each card is a prominent TITLE + count, with a
// mode-specific visual: GENRE = sampled cover thumbnails; KEY = the Camelot color of that
// key (neutral glow when unknown); BPM = a metronome. Tapping runs the constellation's
// action (drill in, or open the filtered browser).
import type { CSSProperties } from 'react';
import { Thumbnail } from '../common/Thumbnail';

export interface ConstellationCell {
  /** Stable id (constellation/nebula id) for keys + data-testids. */
  id: string;
  label: string;
  countLabel: string;
  /** GENRE cards: sampled cover-art keys for the preview strip. */
  coverKeys?: string[];
  /** KEY cards: the Camelot color for this key (omit → neutral glow, e.g. "Unknown"). */
  accentColor?: string;
  /** BPM cards: render a metronome glyph. */
  icon?: 'metronome';
  onActivate: () => void;
}

function Metronome() {
  return (
    <svg className="pdj-cgrid__metronome" viewBox="0 0 48 48" aria-hidden>
      <polygon points="18,5 30,5 40,43 8,43" />
      <line x1="24" y1="41" x2="33.5" y2="12" />
      <rect x="30.5" y="12.5" width="7" height="4.5" rx="1.2" />
      <circle cx="24" cy="41" r="2.2" />
    </svg>
  );
}

export function ConstellationGrid({ cells }: { cells: ConstellationCell[] }) {
  return (
    <div className="pdj-cgrid" data-testid="constellation-grid">
      {cells.map((c) => (
        <button
          key={c.id}
          type="button"
          className={'pdj-cgrid__cell' + (c.accentColor ? ' is-keyed' : '')}
          data-testid={'cgrid-' + c.id}
          style={c.accentColor ? ({ '--cgrid-accent': c.accentColor } as CSSProperties) : undefined}
          onClick={c.onActivate}
        >
          {c.accentColor ? (
            <span className="pdj-cgrid__keyfill" aria-hidden />
          ) : (
            <span className="pdj-cgrid__glow" aria-hidden />
          )}
          {c.icon === 'metronome' && <Metronome />}
          {c.coverKeys && c.coverKeys.length > 0 && (
            <span className="pdj-cgrid__covers" aria-hidden>
              {c.coverKeys.slice(0, 16).map((k, i) => (
                <Thumbnail key={i} artKey={k} alt="" size={34} className="pdj-cgrid__cover" />
              ))}
            </span>
          )}
          <span className="pdj-cgrid__title">{c.label}</span>
          <span className="pdj-cgrid__count">{c.countLabel}</span>
        </button>
      ))}
    </div>
  );
}
