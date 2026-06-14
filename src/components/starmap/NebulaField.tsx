// NebulaField: renders ONE constellation (a bpm range or a key) as a hazy NEBULA
// for the BPM / KEY star-map modes. It is the analog of ConstellationField but
// for the song-grouped nebula view:
//
//   - a soft radial GLOW of radius `nebula.r` (reuses the #pdj-field-glow /
//     #pdj-field-blur defs + the hazy "field" vibe),
//   - the SEEDED decorative scatter of ~15–30 faint stars laid out by
//     computeNebulaLayout (already in absolute scene coords — NOT 1:1 with songs),
//   - a readable LABEL (e.g. "120–130", "8A", "A minor"),
//   - the SONG COUNT caption (e.g. "234 songs").
//
// The whole <g> is the click target (role=button, Enter/Space) → opens the
// browser pre-filtered to this constellation's songs (handled by the parent via
// nebula.filter). Purely presentational + an activate handler; no data ops here.
import type { KeyboardEvent as ReactKeyboardEvent } from 'react';
import type { Nebula, NebulaFilter } from '../../types/starmap';

interface NebulaFieldProps {
  nebula: Nebula;
  /** Open the browser pre-filtered to this nebula's songs (null = Unknown). */
  onActivate: (filter: NebulaFilter | null) => void;
}

export function NebulaField({ nebula: n, onActivate }: NebulaFieldProps) {
  const countLabel = `${n.songCount} ${n.songCount === 1 ? 'song' : 'songs'}`;
  // The catch-all "Unknown" nebula has no filter → it's informational, not a
  // drill-in target; we still render it but make it non-interactive.
  const interactive = n.filter != null;
  const title = `${n.label} — ${countLabel}${interactive ? ' · click to view songs' : ''}`;
  // Label + count sit in the headroom ABOVE the glow (mirrors the nebula box
  // layout: NEBULA_LABEL_H of headroom above the centered glow).
  const labelY = n.y - n.r - 14;
  const countY = n.y - n.r - 0.5;

  const onKey = (e: ReactKeyboardEvent<SVGGElement>) => {
    if (!interactive) return;
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onActivate(n.filter);
    }
  };

  return (
    <g
      className={'pdj-nebula' + (interactive ? '' : ' is-unknown')}
      data-nebula=""
      data-testid={'nebula-' + n.id}
      {...(interactive
        ? {
            role: 'button' as const,
            tabIndex: 0,
            'aria-label': title,
            onClick: () => onActivate(n.filter),
            onKeyDown: onKey,
          }
        : { 'aria-label': title })}
    >
      <title>{title}</title>

      {/* Soft hazy glow — the nebula cloud. */}
      <circle
        className="pdj-nebula__glow"
        cx={n.x}
        cy={n.y}
        r={n.r}
      />

      {/* Seeded decorative scatter (NOT 1:1 with songs). */}
      {n.stars.map((s, i) => (
        <circle
          key={i}
          className="pdj-nebula__star"
          cx={s.x}
          cy={s.y}
          r={s.r}
        />
      ))}

      {/* Label + song count, in the headroom above the glow. */}
      <text
        className="pdj-nebula__label"
        x={n.x}
        y={labelY}
        textAnchor="middle"
      >
        {n.label}
      </text>
      <text
        className="pdj-nebula__count"
        data-testid={'nebula-count-' + n.id}
        x={n.x}
        y={countY}
        textAnchor="middle"
      >
        {countLabel}
      </text>
    </g>
  );
}
