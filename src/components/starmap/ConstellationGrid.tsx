// Mobile constellation grid: a vertical-scrolling 2-column grid of constellation
// CARDS (instead of the pan/zoom SVG scatter, whose labels are illegible on a phone).
// ~4 cards fill the screen; free-scroll to the rest. Each card is a prominent TITLE +
// count + a few sampled cover thumbnails — a legible way to pick a constellation. Used
// for the multi-constellation views (genre categories, BPM / Key nebulae); tapping a
// card runs that constellation's action (drill in, or open the filtered browser).
import { Thumbnail } from '../common/Thumbnail';

export interface ConstellationCell {
  /** Stable id (constellation/nebula id) for keys + data-testids. */
  id: string;
  label: string;
  countLabel: string;
  /** Sampled cover-art keys for a preview strip (genre cards); empty for song nebulae. */
  coverKeys?: string[];
  onActivate: () => void;
}

export function ConstellationGrid({ cells }: { cells: ConstellationCell[] }) {
  return (
    <div className="pdj-cgrid" data-testid="constellation-grid">
      {cells.map((c) => (
        <button
          key={c.id}
          type="button"
          className="pdj-cgrid__cell"
          data-testid={'cgrid-' + c.id}
          onClick={c.onActivate}
        >
          <span className="pdj-cgrid__glow" aria-hidden />
          {c.coverKeys && c.coverKeys.length > 0 && (
            <span className="pdj-cgrid__covers" aria-hidden>
              {c.coverKeys.slice(0, 4).map((k, i) => (
                <Thumbnail key={i} artKey={k} alt="" size={48} className="pdj-cgrid__cover" />
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
