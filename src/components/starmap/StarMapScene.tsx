// StarMapScene: the app's default view. A static, pre-rendered, clickable SVG
// "night sky" where 1 star = 1 album. It is now TWO-TIER:
//
//   TIER 1 (default, /map): constellations are the ~14 top CATEGORIES (+ an
//     "Other" catch-all). Album stars render DIMMED and are NOT clickable; a
//     hazy glowing overlay (ConstellationField) sits over each category and is
//     the click target -> drills into that category (focused tier 2).
//   TIER 2 (/map?cat=<category> focused): tiers are CLICK-DISCOVERABLE only.
//     Clicking a hazy constellation overlay drills into that category and shows
//     its sub-genre constellations; album stars ARE clickable -> /map/:albumId
//     (solar system). The back affordance ("← All genres") returns to tier 1.
//     There is no global tier-2 view; tier 2 is always focused on one category.
//
// Tier/focus state is derived from the URL query (deep-linkable). The heavy
// geometry lives in src/starmap/layout.ts (renderer-agnostic). This component
// loads data, caches the layout by content hash + tier + focus, resolves cover
// thumbnails lazily, and draws the SVG with lightweight pan/zoom.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { PointerEvent as ReactPointerEvent } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import type { StarMapLayout, Star, Tier } from '../../types/starmap';
import { useAppStore } from '../../store/useAppStore';
import { getAlbums, getMeta, setMeta } from '../../storage/repo';
import { artObjectURL } from '../../storage/artCache';
import { computeLayout } from '../../starmap/layout';
import { txn } from '../../lib/log';
import { ConstellationField } from './ConstellationField';
import './starmap.css';

const META_PREFIX = 'starmap.layout:';

interface ViewBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

// Cache key MUST include tier + focusCategory or the tiers would collide on the
// same album-set hash (same albums, different geometry).
function layoutCacheKey(hash: string, tier: Tier, focusCategory?: string): string {
  return META_PREFIX + hash + ':t' + tier + (focusCategory ? ':c' + focusCategory : '');
}

export function StarMapScene() {
  const activeSourceId = useAppStore((s) => s.activeSourceId);
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();

  // ---- tier / focus state, derived from the URL query (deep-linkable) ----
  // Tier 2 is ONLY reachable by drilling into a category (click-discoverable).
  // There is no global tier-2 view; tier 2 is always focused on one category.
  const focusCategory = params.get('cat') ?? undefined;
  const tier: Tier = focusCategory ? 2 : 1;

  const [layout, setLayout] = useState<StarMapLayout | null>(null);
  const [loading, setLoading] = useState(true);
  const [coverUrls, setCoverUrls] = useState<Record<string, string>>({});

  // ---- tier/focus mutations (all go through the URL so back/forward works) ----
  const goTier1 = useCallback(() => {
    txn('starmap.tier', { tier: 1, focusCategory: null });
    setParams({});
  }, [setParams]);

  const drillInto = useCallback(
    (category: string) => {
      txn('starmap.tier', { tier: 2, focusCategory: category });
      setParams({ cat: category });
    },
    [setParams],
  );

  // ---- load albums + (cached) layout whenever source / tier / focus changes ----
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      const albums = await getAlbums(activeSourceId);
      const next = computeLayout(albums, { tier, focusCategory });
      if (cancelled) return;

      const cacheKey = layoutCacheKey(next.albumSetHash, tier, focusCategory);
      const cached = await getMeta<StarMapLayout>(cacheKey);
      if (cancelled) return;

      if (cached && cached.albumSetHash === next.albumSetHash) {
        setLayout(cached);
      } else {
        await setMeta(cacheKey, next);
        txn('starmap.layout', {
          albums: next.stars.length,
          constellations: next.constellations.length,
          tier,
          focusCategory: focusCategory ?? null,
        });
        if (cancelled) return;
        setLayout(next);
      }
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [activeSourceId, tier, focusCategory]);

  // ---- lazily resolve cover object URLs for stars that have art ----
  useEffect(() => {
    if (!layout) return;
    let cancelled = false;
    (async () => {
      const updates: Record<string, string> = {};
      for (const star of layout.stars) {
        if (!star.coverArtKey) continue;
        const url = await artObjectURL(star.coverArtKey);
        if (cancelled) return;
        if (url) updates[star.albumId] = url;
      }
      if (!cancelled && Object.keys(updates).length) {
        setCoverUrls((prev) => ({ ...prev, ...updates }));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [layout]);

  // ---- pan / zoom via viewBox (resets when the layout changes) ----
  const initialViewBox = useMemo<ViewBox | null>(
    () => (layout ? { x: 0, y: 0, w: layout.width, h: layout.height } : null),
    [layout],
  );
  const [viewBox, setViewBox] = useState<ViewBox | null>(null);
  useEffect(() => {
    setViewBox(initialViewBox);
  }, [initialViewBox]);

  const svgRef = useRef<SVGSVGElement | null>(null);
  const panRef = useRef<{ startX: number; startY: number; vb: ViewBox } | null>(null);
  // Active pointers (mouse/touch). Two simultaneous touch pointers = a pinch-zoom.
  const pointers = useRef<Map<number, { x: number; y: number }>>(new Map());
  const pinchRef = useRef<{ startDist: number; startVb: ViewBox; sceneMidX: number; sceneMidY: number } | null>(null);
  const [panning, setPanning] = useState(false);

  const resetView = useCallback(() => {
    setViewBox(initialViewBox);
  }, [initialViewBox]);

  // Wheel-zoom must be a NATIVE, non-passive listener: React's onWheel is passive,
  // so calling preventDefault() there throws "Unable to preventDefault inside passive
  // event listener". Keep the latest state in a ref so the listener stays stable.
  const wheelState = useRef({ viewBox, layout });
  wheelState.current = { viewBox, layout };
  useEffect(() => {
    const el = svgRef.current;
    if (!el) return;
    const handler = (e: WheelEvent) => {
      const { viewBox: vb, layout: lay } = wheelState.current;
      if (!vb) return;
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      const px = vb.x + ((e.clientX - rect.left) / rect.width) * vb.w;
      const py = vb.y + ((e.clientY - rect.top) / rect.height) * vb.h;
      const factor = e.deltaY > 0 ? 1.1 : 1 / 1.1;
      const minW = 200;
      const maxW = (lay?.width ?? 2000) * 2.5;
      const newW = Math.max(minW, Math.min(maxW, vb.w * factor));
      const newH = newW * (vb.h / vb.w);
      setViewBox({
        x: px - ((px - vb.x) * newW) / vb.w,
        y: py - ((py - vb.y) * newH) / vb.h,
        w: newW,
        h: newH,
      });
    };
    el.addEventListener('wheel', handler, { passive: false });
    return () => el.removeEventListener('wheel', handler);
  }, []);

  // Clamp a viewBox width to the zoom range (same bounds as wheel-zoom).
  const clampW = useCallback((w: number) => {
    const lay = wheelState.current.layout;
    return Math.max(200, Math.min((lay?.width ?? 2000) * 2.5, w));
  }, []);

  const onPointerDown = useCallback(
    (e: ReactPointerEvent<SVGSVGElement>) => {
      const vb = wheelState.current.viewBox;
      if (!vb || !svgRef.current) return;
      // Ignore drags that start on a click target (let the click through).
      if ((e.target as Element).closest('[data-star],[data-field]')) return;
      try {
        (e.target as Element).setPointerCapture?.(e.pointerId);
      } catch {
        /* no active pointer (e.g. synthetic event) — capture is best-effort */
      }
      pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (pointers.current.size >= 2) {
        // Two fingers down → start a pinch; anchor on the scene point under the midpoint.
        panRef.current = null;
        setPanning(false);
        const [a, b] = [...pointers.current.values()];
        const rect = svgRef.current.getBoundingClientRect();
        const midX = (a.x + b.x) / 2;
        const midY = (a.y + b.y) / 2;
        pinchRef.current = {
          startDist: Math.hypot(b.x - a.x, b.y - a.y) || 1,
          startVb: vb,
          sceneMidX: vb.x + ((midX - rect.left) / rect.width) * vb.w,
          sceneMidY: vb.y + ((midY - rect.top) / rect.height) * vb.h,
        };
      } else {
        panRef.current = { startX: e.clientX, startY: e.clientY, vb };
        setPanning(true);
      }
    },
    [],
  );

  const onPointerMove = useCallback(
    (e: ReactPointerEvent<SVGSVGElement>) => {
      if (!svgRef.current) return;
      if (pointers.current.has(e.pointerId)) pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
      const rect = svgRef.current.getBoundingClientRect();
      // Pinch: scale by the finger-distance ratio, keeping the start scene-point under the live midpoint.
      if (pointers.current.size >= 2 && pinchRef.current) {
        const [a, b] = [...pointers.current.values()];
        const dist = Math.hypot(b.x - a.x, b.y - a.y) || 1;
        const midX = (a.x + b.x) / 2;
        const midY = (a.y + b.y) / 2;
        const { startDist, startVb, sceneMidX, sceneMidY } = pinchRef.current;
        const newW = clampW(startVb.w * (startDist / dist));
        const newH = newW * (startVb.h / startVb.w);
        const fx = (midX - rect.left) / rect.width;
        const fy = (midY - rect.top) / rect.height;
        setViewBox({ x: sceneMidX - fx * newW, y: sceneMidY - fy * newH, w: newW, h: newH });
        return;
      }
      const p = panRef.current;
      if (!p) return;
      const dx = ((e.clientX - p.startX) / rect.width) * p.vb.w;
      const dy = ((e.clientY - p.startY) / rect.height) * p.vb.h;
      setViewBox({ x: p.vb.x - dx, y: p.vb.y - dy, w: p.vb.w, h: p.vb.h });
    },
    [clampW],
  );

  const endPan = useCallback((e: ReactPointerEvent<SVGSVGElement>) => {
    pointers.current.delete(e.pointerId);
    if (pointers.current.size < 2) pinchRef.current = null;
    if (pointers.current.size === 0) {
      panRef.current = null;
      setPanning(false);
    } else if (pointers.current.size === 1) {
      // One finger left after a pinch → continue as a pan from where it is.
      const only = [...pointers.current.values()][0];
      const vb = wheelState.current.viewBox;
      if (vb) {
        panRef.current = { startX: only.x, startY: only.y, vb };
        setPanning(true);
      }
    }
  }, []);

  // Member stars per constellation (used by the tier-1 hazy overlays).
  const starsByConstellation = useMemo(() => {
    const map = new Map<string, Star[]>();
    if (!layout) return map;
    const byId = new Map(layout.stars.map((s) => [s.albumId, s]));
    for (const c of layout.constellations) {
      const members = c.starIds
        .map((id) => byId.get(id))
        .filter((s): s is Star => s != null);
      map.set(c.genre, members);
    }
    return map;
  }, [layout]);

  if (loading || !layout || !viewBox) {
    return (
      <div className="pdj-starmap">
        <div className="pdj-starmap__loading">Charting the sky…</div>
      </div>
    );
  }

  if (layout.stars.length === 0) {
    return (
      <div className="pdj-starmap">
        <div className="pdj-starmap__empty">No albums to map yet. Import a source to see the stars.</div>
      </div>
    );
  }

  const tier1 = layout.tier === 1;

  return (
    <div className="pdj-starmap">
      <div className="pdj-starmap__toolbar">
        {focusCategory && (
          <button
            type="button"
            className="pdj-starmap__btn"
            data-testid="back-to-tier1"
            onClick={goTier1}
          >
            ← All genres
          </button>
        )}
        <button type="button" className="pdj-starmap__btn" onClick={resetView}>
          Reset view
        </button>
      </div>

      {focusCategory && (
        <div className="pdj-starmap__crumb" data-testid="focus-label">
          {focusCategory} · sub-genres
        </div>
      )}

      <svg
        ref={svgRef}
        className={'pdj-starmap__svg' + (panning ? ' is-panning' : '')}
        data-testid="starmap-scene"
        data-tier={layout.tier}
        viewBox={`${viewBox.x} ${viewBox.y} ${viewBox.w} ${viewBox.h}`}
        preserveAspectRatio="xMidYMid meet"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endPan}
        onPointerLeave={endPan}
        onPointerCancel={endPan}
      >
        <defs>
          <radialGradient id="pdj-star-glow" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stopColor="var(--pdj-accent)" stopOpacity="0.55" />
            <stop offset="100%" stopColor="var(--pdj-accent)" stopOpacity="0" />
          </radialGradient>
          {/* Soft blur for the tier-1 hazy constellation field. */}
          <filter id="pdj-field-blur" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur in="SourceGraphic" stdDeviation="14" />
          </filter>
          <radialGradient id="pdj-field-glow" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stopColor="var(--pdj-accent)" stopOpacity="0.9" />
            <stop offset="60%" stopColor="var(--pdj-accent-2)" stopOpacity="0.5" />
            <stop offset="100%" stopColor="var(--pdj-accent-2)" stopOpacity="0" />
          </radialGradient>
        </defs>

        {/* Constellation polylines + labels (behind the stars). */}
        {layout.constellations.map((c) => {
          const members = starsByConstellation.get(c.genre) ?? [];
          const pts = members.map((s) => `${s.x},${s.y}`).join(' ');
          return (
            <g key={c.genre}>
              {members.length > 1 && <polyline className="pdj-constellation__line" points={pts} />}
              <text
                className="pdj-constellation__label"
                data-testid={'constellation-' + c.genre}
                x={c.x + 4}
                y={c.y + 16}
              >
                {c.label}
              </text>
            </g>
          );
        })}

        {/* Stars. Dimmed + non-interactive on tier 1; clickable on tier 2.
            At tier 2 each star also shows its album name as a text label. */}
        {layout.stars.map((star) => (
          <StarNode
            key={star.albumId}
            star={star}
            tier={layout.tier}
            coverUrl={coverUrls[star.albumId]}
            onActivate={() => navigate('/map/' + star.albumId)}
          />
        ))}

        {/* Tier-1 only: the hazy glowing overlay over each category constellation.
            Rendered ON TOP so it is the click target (drills into the category). */}
        {tier1 &&
          layout.constellations.map((c) => (
            <ConstellationField
              key={'field-' + c.genre}
              constellation={c}
              stars={starsByConstellation.get(c.genre) ?? []}
              onActivate={drillInto}
            />
          ))}
      </svg>
    </div>
  );
}

interface StarNodeProps {
  star: Star;
  /** Current layout tier; tier-2 stars render a visible album-name caption. */
  tier: Tier;
  coverUrl?: string;
  onActivate: () => void;
}

function StarNode({ star, tier, coverUrl, onActivate }: StarNodeProps) {
  const clipId = 'clip-' + star.albumId;
  const title = `${star.artist} — ${star.name}${star.year != null ? ` (${star.year})` : ''}`;
  // On tier 1, stars are dimmed and NOT a click/keyboard target (the hazy
  // constellation overlay above is the interactive element). data-star is only
  // set when clickable so pan/zoom hit-testing and tests can distinguish them.
  const interactive = star.clickable;
  // Album-name label: only visible at tier 2 so tier 1 stays uncluttered.
  const showLabel = tier === 2;
  // Label sits just below the star circle with a small gap.
  const labelY = star.y + star.r + 14;
  return (
    <g
      className={'pdj-star' + (interactive ? '' : ' is-dimmed')}
      {...(interactive ? { 'data-star': '' } : {})}
      data-testid={'star-' + star.albumId}
      {...(interactive
        ? {
            role: 'button' as const,
            tabIndex: 0,
            onClick: onActivate,
            onKeyDown: (e: React.KeyboardEvent<SVGGElement>) => {
              if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                onActivate();
              }
            },
          }
        : {})}
    >
      <title>{title}</title>
      {/* soft glow */}
      <circle className="pdj-star__halo" cx={star.x} cy={star.y} r={star.r * 2.1} fill="url(#pdj-star-glow)" />
      {coverUrl ? (
        <>
          <clipPath id={clipId}>
            <circle cx={star.x} cy={star.y} r={star.r} />
          </clipPath>
          <image
            href={coverUrl}
            x={star.x - star.r}
            y={star.y - star.r}
            width={star.r * 2}
            height={star.r * 2}
            clipPath={`url(#${clipId})`}
            preserveAspectRatio="xMidYMid slice"
          />
        </>
      ) : (
        <circle cx={star.x} cy={star.y} r={star.r} fill="var(--pdj-accent-2)" />
      )}
      {/* focus/outline ring (also marks art-backed stars) */}
      <circle className="pdj-star__ring" cx={star.x} cy={star.y} r={star.r} />
      {/* Tier-2 album name caption — rendered below the star so the cover art
          stays unobscured. Truncation is handled in CSS via textLength clamp. */}
      {showLabel && (
        <text
          className="pdj-star__label"
          data-testid={'star-label-' + star.albumId}
          x={star.x}
          y={labelY}
          textAnchor="middle"
        >
          {star.name}
        </text>
      )}
    </g>
  );
}
