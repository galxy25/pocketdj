// StarMapScene: the app's default view. A static, pre-rendered, clickable SVG
// "night sky" where 1 star = 1 album, constellations = genres, vertical position
// = year. Clicking a star navigates to that album's solar system (/map/:albumId).
//
// The heavy geometry lives in src/starmap/layout.ts (renderer-agnostic). This
// component only loads data, caches the layout by content hash, resolves cover
// thumbnails lazily, and draws the SVG with lightweight pan/zoom.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { PointerEvent as ReactPointerEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import type { StarMapLayout, Star } from '../../types/starmap';
import { useAppStore } from '../../store/useAppStore';
import { getAlbums, getMeta, setMeta } from '../../storage/repo';
import { artObjectURL } from '../../storage/artCache';
import { computeLayout } from '../../starmap/layout';
import { txn } from '../../lib/log';
import './starmap.css';

const META_PREFIX = 'starmap.layout:';

interface ViewBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

function layoutCacheKey(hash: string): string {
  return META_PREFIX + hash;
}

export function StarMapScene() {
  const activeSourceId = useAppStore((s) => s.activeSourceId);
  const navigate = useNavigate();

  const [layout, setLayout] = useState<StarMapLayout | null>(null);
  const [loading, setLoading] = useState(true);
  const [coverUrls, setCoverUrls] = useState<Record<string, string>>({});

  // ---- load albums + (cached) layout whenever the active source changes ----
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      const albums = await getAlbums(activeSourceId);
      // Compute the content hash cheaply (sorted ids) to consult the cache first.
      const next = computeLayout(albums);
      if (cancelled) return;

      const cacheKey = layoutCacheKey(next.albumSetHash);
      const cached = await getMeta<StarMapLayout>(cacheKey);
      if (cancelled) return;

      if (cached && cached.albumSetHash === next.albumSetHash) {
        setLayout(cached);
      } else {
        await setMeta(cacheKey, next);
        txn('starmap.layout', { albums: next.stars.length, constellations: next.constellations.length });
        if (cancelled) return;
        setLayout(next);
      }
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [activeSourceId]);

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

  // ---- pan / zoom via viewBox ----
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

  const onPointerDown = useCallback(
    (e: ReactPointerEvent<SVGSVGElement>) => {
      if (!viewBox) return;
      // Ignore drags that start on a star (let the click through).
      if ((e.target as Element).closest('[data-star]')) return;
      panRef.current = { startX: e.clientX, startY: e.clientY, vb: viewBox };
      setPanning(true);
      (e.target as Element).setPointerCapture?.(e.pointerId);
    },
    [viewBox],
  );

  const onPointerMove = useCallback((e: ReactPointerEvent<SVGSVGElement>) => {
    const p = panRef.current;
    if (!p || !svgRef.current) return;
    const rect = svgRef.current.getBoundingClientRect();
    const dx = ((e.clientX - p.startX) / rect.width) * p.vb.w;
    const dy = ((e.clientY - p.startY) / rect.height) * p.vb.h;
    setViewBox({ x: p.vb.x - dx, y: p.vb.y - dy, w: p.vb.w, h: p.vb.h });
  }, []);

  const endPan = useCallback(() => {
    panRef.current = null;
    setPanning(false);
  }, []);

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

  return (
    <div className="pdj-starmap">
      <div className="pdj-starmap__toolbar">
        <button type="button" className="pdj-starmap__btn" onClick={resetView}>
          Reset view
        </button>
      </div>
      <svg
        ref={svgRef}
        className={'pdj-starmap__svg' + (panning ? ' is-panning' : '')}
        data-testid="starmap-scene"
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
        </defs>

        {/* Constellation polylines + labels (behind the stars). */}
        {layout.constellations.map((c) => {
          const pts = c.starIds
            .map((id) => starById(layout, id))
            .filter((s): s is Star => s != null)
            .map((s) => `${s.x},${s.y}`)
            .join(' ');
          return (
            <g key={c.genre}>
              {c.starIds.length > 1 && <polyline className="pdj-constellation__line" points={pts} />}
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

        {/* Stars. */}
        {layout.stars.map((star) => (
          <StarNode
            key={star.albumId}
            star={star}
            coverUrl={coverUrls[star.albumId]}
            onActivate={() => navigate('/map/' + star.albumId)}
          />
        ))}
      </svg>
    </div>
  );
}

function starById(layout: StarMapLayout, id: string): Star | undefined {
  // Linear scan is fine: only called per-vertex of constellation lines.
  return layout.stars.find((s) => s.albumId === id);
}

interface StarNodeProps {
  star: Star;
  coverUrl?: string;
  onActivate: () => void;
}

function StarNode({ star, coverUrl, onActivate }: StarNodeProps) {
  const clipId = 'clip-' + star.albumId;
  const title = `${star.artist} — ${star.name}${star.year != null ? ` (${star.year})` : ''}`;
  return (
    <g
      className="pdj-star"
      data-star=""
      data-testid={'star-' + star.albumId}
      role="button"
      tabIndex={0}
      onClick={onActivate}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onActivate();
        }
      }}
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
    </g>
  );
}
