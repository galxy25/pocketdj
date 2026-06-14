// ConstellationField: the hazy, glowing, mostly-transparent overlay drawn over
// each TIER-1 (category) constellation. It is the CLICK TARGET on tier 1 — a soft
// luminous blob/hull around the constellation's stars that signals "click the
// constellation, not the album". The album stars render dimmed underneath.
//
// Geometry is derived from the constellation's member stars (a padded convex-ish
// hull, falling back to the bounding box) so the glow hugs the actual cluster
// rather than the whole rectangle. Purely presentational + a click/keyboard
// activate handler; no data ops here.
import type { KeyboardEvent as ReactKeyboardEvent } from 'react';
import type { Constellation, Star } from '../../types/starmap';

interface ConstellationFieldProps {
  constellation: Constellation;
  /** Member stars of this constellation (already laid out). */
  stars: Star[];
  /** Drill into this category (set focusCategory + tier 2). */
  onActivate: (category: string) => void;
}

interface Point {
  x: number;
  y: number;
}

/** Centroid of a set of points (or the box center if empty). */
function centroid(pts: Point[], c: Constellation): Point {
  if (pts.length === 0) return { x: c.x + c.w / 2, y: c.y + c.h / 2 };
  let sx = 0;
  let sy = 0;
  for (const p of pts) {
    sx += p.x;
    sy += p.y;
  }
  return { x: sx / pts.length, y: sy / pts.length };
}

/**
 * Build a soft hull path around the stars. We expand each star outward from the
 * cluster centroid, sort by angle, and stitch them with a closed smooth curve so
 * the glow reads as one organic luminous blob. With <3 stars we fall back to a
 * padded rounded rect (handled by the caller via the ellipse branch).
 */
function hullPath(pts: Point[], center: Point, pad: number): string {
  const expanded = pts.map((p) => {
    const dx = p.x - center.x;
    const dy = p.y - center.y;
    const len = Math.hypot(dx, dy) || 1;
    return { x: p.x + (dx / len) * pad, y: p.y + (dy / len) * pad, a: Math.atan2(dy, dx) };
  });
  expanded.sort((a, b) => a.a - b.a);
  // Closed Catmull-Rom-ish smoothing via quadratic midpoints.
  const n = expanded.length;
  let d = `M ${mid(expanded[n - 1], expanded[0]).x.toFixed(2)} ${mid(expanded[n - 1], expanded[0]).y.toFixed(2)}`;
  for (let i = 0; i < n; i++) {
    const cur = expanded[i];
    const next = expanded[(i + 1) % n];
    const m = mid(cur, next);
    d += ` Q ${cur.x.toFixed(2)} ${cur.y.toFixed(2)} ${m.x.toFixed(2)} ${m.y.toFixed(2)}`;
  }
  return d + ' Z';
}

function mid(a: Point, b: Point): Point {
  return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
}

export function ConstellationField({ constellation: c, stars, onActivate }: ConstellationFieldProps) {
  const pts: Point[] = stars.map((s) => ({ x: s.x, y: s.y }));
  const center = centroid(pts, c);
  // Pad scales a little with the typical star radius so big clusters glow wider.
  const avgR = stars.length ? stars.reduce((acc, s) => acc + s.r, 0) / stars.length : 18;
  const pad = avgR * 2.4 + 18;

  const onKey = (e: ReactKeyboardEvent<SVGGElement>) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onActivate(c.category);
    }
  };

  // A clip-free soft blob: hull for >=3 stars, else an ellipse around the cluster.
  let shape;
  if (stars.length >= 3) {
    shape = <path className="pdj-constellation__field-shape" d={hullPath(pts, center, pad)} />;
  } else {
    // 1-2 stars: an ellipse hugging them.
    const rx = (stars.length === 2 ? Math.abs(pts[0].x - pts[1].x) / 2 : 0) + pad;
    const ry = (stars.length === 2 ? Math.abs(pts[0].y - pts[1].y) / 2 : 0) + pad;
    shape = (
      <ellipse
        className="pdj-constellation__field-shape"
        cx={center.x}
        cy={center.y}
        rx={Math.max(rx, pad)}
        ry={Math.max(ry, pad)}
      />
    );
  }

  const title = `${c.label} — ${stars.length} album${stars.length === 1 ? '' : 's'} · click to explore sub-genres`;

  return (
    <g
      className="pdj-constellation__field"
      data-field=""
      data-testid={'constellation-overlay-' + c.category}
      role="button"
      tabIndex={0}
      aria-label={title}
      onClick={() => onActivate(c.category)}
      onKeyDown={onKey}
    >
      <title>{title}</title>
      {shape}
    </g>
  );
}
