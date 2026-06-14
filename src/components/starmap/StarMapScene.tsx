// StarMapScene: the app's default view. A static, pre-rendered, clickable SVG
// "night sky". It has TWO shapes, chosen by the grouping mode (?group=):
//
//   GENRE mode (?group=genre, default): 1 star = 1 album, TWO-TIER.
//     TIER 1 (default, /map): constellations are the ~14 top CATEGORIES (+ an
//       "Other" catch-all). Album stars render DIMMED and are NOT clickable; a
//       hazy glowing overlay (ConstellationField) sits over each category and is
//       the click target -> drills into that category (focused tier 2).
//     TIER 2 (/map?cat=<category> focused): clicking a hazy constellation overlay
//       drills into that category and shows its sub-genre constellations; album
//       stars ARE clickable -> /map/:albumId (solar system).
//
//   BPM / KEY modes (?group=bpm | key): NOT one star per album OR per song.
//     Instead ALL songs are grouped into a handful of CONSTELLATIONS (a bpm range
//     or a key) and each renders as a hazy NEBULA: a soft glow + a SEEDED
//     decorative scatter of faint stars (NOT 1:1 with songs) + a label + the song
//     COUNT. Clicking a nebula opens the browser pre-filtered (Songs view + the
//     matching bpm/camelot/key filter) so the existing virtualized song table
//     shows exactly that constellation's songs.
//
// Mode/tier/focus state is derived from the URL query (deep-linkable). The heavy
// geometry lives in src/starmap/layout.ts (renderer-agnostic). This component
// loads data, caches the layout by content hash + tier + focus + mode, resolves
// cover thumbnails lazily (genre only), and draws the SVG with lightweight
// pan/zoom.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { PointerEvent as ReactPointerEvent } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import type { StarMapLayout, NebulaLayout, Star, Tier } from '../../types/starmap';
import { useAppStore } from '../../store/useAppStore';
import { useBrowserStore } from '../../store/useBrowserStore';
import { getAlbums, getSongs, getMeta, setMeta } from '../../storage/repo';
import { artObjectURL } from '../../storage/artCache';
import { computeLayout, computeNebulaLayout } from '../../starmap/layout';
import { groupSongs } from '../../starmap/grouping';
import type { GroupBy, KeyNotation } from '../../starmap/grouping';
import { txn } from '../../lib/log';
import { ConstellationField } from './ConstellationField';
import { NebulaField } from './NebulaField';
import './starmap.css';

const META_PREFIX = 'starmap.layout:';

interface ViewBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

// Cache key MUST include tier + focusCategory AND the grouping mode, or the
// genre/bpm/key layouts would collide on the same content hash (same source,
// different geometry). keyNotation only discriminates within the 'key' mode.
function layoutCacheKey(
  hash: string,
  tier: Tier,
  focusCategory?: string,
  groupBy: GroupBy = 'genre',
  keyNotation: KeyNotation = 'camelot',
): string {
  return (
    META_PREFIX +
    hash +
    ':t' +
    tier +
    (focusCategory ? ':c' + focusCategory : '') +
    (groupBy !== 'genre'
      ? ':g' + groupBy + (groupBy === 'key' ? ':k' + keyNotation : '')
      : '')
  );
}

export function StarMapScene() {
  const activeSourceId = useAppStore((s) => s.activeSourceId);
  const setItemType = useAppStore((s) => s.setItemType);
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();

  // ---- grouping mode, derived from the URL query (deep-linkable) ----
  // ?group= ∈ genre (default) | bpm | key. ?keynote= ∈ camelot (default) |
  // musical, meaningful only when group=key. Genre is the ONLY mode with tier
  // drill-in (?cat=); bpm/key are single-tier NEBULA views (cat ignored).
  const groupParam = params.get('group');
  const groupBy: GroupBy =
    groupParam === 'bpm' || groupParam === 'key' ? groupParam : 'genre';
  const keyNotation: KeyNotation =
    params.get('keynote') === 'musical' ? 'musical' : 'camelot';
  const audioMode = groupBy !== 'genre';

  // ---- tier / focus state, derived from the URL query (deep-linkable) ----
  // Tier 2 is ONLY reachable by drilling into a category (click-discoverable) in
  // GENRE mode. There is no global tier-2 view; tier 2 is always focused on one
  // category. In bpm/key modes there is no drill-in (single-tier nebulae).
  const focusCategory = audioMode ? undefined : params.get('cat') ?? undefined;
  const tier: Tier = audioMode ? 2 : focusCategory ? 2 : 1;

  // Exactly one of these is set at a time, keyed by audioMode.
  const [layout, setLayout] = useState<StarMapLayout | null>(null);
  const [nebulaLayout, setNebulaLayout] = useState<NebulaLayout | null>(null);
  const [loading, setLoading] = useState(true);
  const [coverUrls, setCoverUrls] = useState<Record<string, string>>({});

  // The active scene's geometry, regardless of which mode produced it.
  const scene = audioMode ? nebulaLayout : layout;

  // ---- tier/focus mutations (all go through the URL so back/forward works) ----
  // Genre is the default mode → its params (group=genre, keynote) are omitted to
  // keep the URL clean; only bpm/key (and key's notation) are serialized.
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

  // ---- grouping-mode mutations (deep-linkable like ?cat=) ----
  // Switching mode drops the genre-only ?cat= drill-in. keynote is only carried
  // for the key mode.
  const setGroupBy = useCallback(
    (next: GroupBy) => {
      // Mode switches are tier transitions in the transcript (no dedicated op).
      txn('starmap.tier', { groupBy: next });
      if (next === 'genre') {
        setParams({});
      } else if (next === 'key') {
        setParams({ group: 'key', keynote: keyNotation });
      } else {
        setParams({ group: next });
      }
    },
    [setParams, keyNotation],
  );

  const setKeyNotation = useCallback(
    (next: KeyNotation) => {
      txn('starmap.tier', { groupBy: 'key', keyNotation: next });
      setParams({ group: 'key', keynote: next });
    },
    [setParams],
  );

  // ---- click a nebula -> pre-filter the browser to its songs + navigate ----
  // The existing browser (BrowserView + useBrowserStore) is already a
  // virtualized, sortable song table with the song-detail popup. We set it to the
  // Songs view, replace the filter with the nebula's single clause, and navigate
  // to /browse so the table shows EXACTLY that constellation's songs. The
  // "Unknown" nebula carries no clean predicate (filter === null) → no-op.
  const openNebulaInBrowser = useCallback(
    (filter: NebulaLayout['nebulae'][number]['filter']) => {
      if (!filter) return; // Unknown nebula: nothing to filter on.
      const store = useBrowserStore.getState();
      store.clearFilter();
      if (filter.field === 'bpm') {
        store.addClause('bpm', 'between');
        const id = lastClauseId();
        if (id) store.updateClause(id, { min: filter.min, max: filter.max });
      } else {
        store.addClause(filter.field, 'eq');
        const id = lastClauseId();
        if (id) store.updateClause(id, { value: filter.value });
      }
      setItemType('song');
      navigate('/browse');
    },
    [navigate, setItemType],
  );

  // ---- load albums (genre) or songs (bpm/key) + (cached) layout ----
  // The dependency list spans both modes; whichever branch runs writes only its
  // own state and clears the other so the renderer never reads a stale scene.
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      let next: StarMapLayout | NebulaLayout;
      if (audioMode) {
        const songs = await getSongs(activeSourceId);
        if (cancelled) return;
        next = computeNebulaLayout(groupSongs(songs, groupBy, keyNotation));
      } else {
        const albums = await getAlbums(activeSourceId);
        if (cancelled) return;
        next = computeLayout(albums, { tier, focusCategory });
      }

      const cacheKey = layoutCacheKey(
        next.albumSetHash,
        tier,
        focusCategory,
        groupBy,
        keyNotation,
      );
      const cached = await getMeta<StarMapLayout | NebulaLayout>(cacheKey);
      if (cancelled) return;

      const resolved =
        cached && cached.albumSetHash === next.albumSetHash ? cached : next;
      if (resolved === next) {
        await setMeta(cacheKey, next);
        if (cancelled) return;
        txn('starmap.layout', {
          tier,
          focusCategory: focusCategory ?? null,
          groupBy,
          keyNotation: groupBy === 'key' ? keyNotation : null,
          ...(audioMode
            ? { nebulae: (next as NebulaLayout).nebulae.length }
            : {
                albums: (next as StarMapLayout).stars.length,
                constellations: (next as StarMapLayout).constellations.length,
              }),
        });
      }

      if (audioMode) {
        setNebulaLayout(resolved as NebulaLayout);
        setLayout(null);
        setCoverUrls({});
      } else {
        setLayout(resolved as StarMapLayout);
        setNebulaLayout(null);
      }
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [activeSourceId, tier, focusCategory, groupBy, keyNotation, audioMode]);

  // ---- lazily resolve cover object URLs for stars that have art (genre only) ----
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

  // ---- pan / zoom via viewBox (resets when the active scene changes) ----
  const initialViewBox = useMemo<ViewBox | null>(
    () => (scene ? { x: 0, y: 0, w: scene.width, h: scene.height } : null),
    [scene],
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
  const wheelState = useRef({ viewBox, scene });
  wheelState.current = { viewBox, scene };
  useEffect(() => {
    const el = svgRef.current;
    if (!el) return;
    const handler = (e: WheelEvent) => {
      const { viewBox: vb, scene: lay } = wheelState.current;
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
    const lay = wheelState.current.scene;
    return Math.max(200, Math.min((lay?.width ?? 2000) * 2.5, w));
  }, []);

  const onPointerDown = useCallback(
    (e: ReactPointerEvent<SVGSVGElement>) => {
      const vb = wheelState.current.viewBox;
      if (!vb || !svgRef.current) return;
      // Ignore drags that start on a click target (let the click through).
      if ((e.target as Element).closest('[data-star],[data-field],[data-nebula]')) return;
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

  // Member stars per constellation (used by the genre tier-1 hazy overlays).
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

  // ---- mode toolbar (shared by every render branch, incl. empty/loading) ----
  const toolbar = (
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

      {/* Grouping-mode segmented control: Genre (2-tier album drill-in) / BPM /
          Key (single-tier song NEBULAE). Deep-linked via ?group=. */}
      <div className="pdj-starmap__segmented" role="group" aria-label="Group stars by">
        <button
          type="button"
          className={'pdj-starmap__seg' + (groupBy === 'genre' ? ' is-active' : '')}
          data-testid="starmap-mode-genre"
          aria-pressed={groupBy === 'genre'}
          onClick={() => setGroupBy('genre')}
        >
          Genre
        </button>
        <button
          type="button"
          className={'pdj-starmap__seg' + (groupBy === 'bpm' ? ' is-active' : '')}
          data-testid="starmap-mode-bpm"
          aria-pressed={groupBy === 'bpm'}
          onClick={() => setGroupBy('bpm')}
        >
          BPM
        </button>
        <button
          type="button"
          className={'pdj-starmap__seg' + (groupBy === 'key' ? ' is-active' : '')}
          data-testid="starmap-mode-key"
          aria-pressed={groupBy === 'key'}
          onClick={() => setGroupBy('key')}
        >
          Key
        </button>
      </div>

      {/* Key-notation sub-toggle: only meaningful in Key mode. */}
      {groupBy === 'key' && (
        <div
          className="pdj-starmap__segmented"
          role="group"
          aria-label="Key notation"
        >
          <button
            type="button"
            className={
              'pdj-starmap__seg' + (keyNotation === 'camelot' ? ' is-active' : '')
            }
            data-testid="keynote-camelot"
            aria-pressed={keyNotation === 'camelot'}
            onClick={() => setKeyNotation('camelot')}
          >
            Camelot
          </button>
          <button
            type="button"
            className={
              'pdj-starmap__seg' + (keyNotation === 'musical' ? ' is-active' : '')
            }
            data-testid="keynote-musical"
            aria-pressed={keyNotation === 'musical'}
            onClick={() => setKeyNotation('musical')}
          >
            Musical
          </button>
        </div>
      )}

      <button type="button" className="pdj-starmap__btn" onClick={resetView}>
        Reset view
      </button>
    </div>
  );

  if (loading || !scene || !viewBox) {
    return (
      <div className="pdj-starmap">
        {toolbar}
        <div className="pdj-starmap__loading">Charting the sky…</div>
      </div>
    );
  }

  // ---- empty state (per mode) ----
  const isEmpty = audioMode
    ? (scene as NebulaLayout).nebulae.length === 0
    : (scene as StarMapLayout).stars.length === 0;
  if (isEmpty) {
    return (
      <div className="pdj-starmap">
        {toolbar}
        <div className="pdj-starmap__empty">
          {audioMode
            ? 'No songs to map yet. Import a source to chart the nebulae.'
            : 'No albums to map yet. Import a source to see the stars.'}
        </div>
      </div>
    );
  }

  const svgTier = audioMode ? 2 : (layout as StarMapLayout).tier;
  const tier1 = !audioMode && (layout as StarMapLayout).tier === 1;

  return (
    <div className="pdj-starmap">
      {toolbar}

      {focusCategory && (
        <div className="pdj-starmap__crumb" data-testid="focus-label">
          {focusCategory} · sub-genres
        </div>
      )}

      <svg
        ref={svgRef}
        className={'pdj-starmap__svg' + (panning ? ' is-panning' : '')}
        data-testid="starmap-scene"
        data-tier={svgTier}
        data-mode={groupBy}
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
          {/* Soft blur for the hazy constellation / nebula fields. */}
          <filter id="pdj-field-blur" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur in="SourceGraphic" stdDeviation="14" />
          </filter>
          <radialGradient id="pdj-field-glow" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stopColor="var(--pdj-accent)" stopOpacity="0.9" />
            <stop offset="60%" stopColor="var(--pdj-accent-2)" stopOpacity="0.5" />
            <stop offset="100%" stopColor="var(--pdj-accent-2)" stopOpacity="0" />
          </radialGradient>
        </defs>

        {/* ===================== BPM / KEY: nebulae ===================== */}
        {audioMode &&
          (scene as NebulaLayout).nebulae.map((n) => (
            <NebulaField key={n.id} nebula={n} onActivate={openNebulaInBrowser} />
          ))}

        {/* ===================== GENRE: album stars ===================== */}
        {!audioMode && (
          <>
            {/* Constellation polylines + labels (behind the stars). */}
            {(layout as StarMapLayout).constellations.map((c) => {
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
            {(layout as StarMapLayout).stars.map((star) => (
              <StarNode
                key={star.albumId}
                star={star}
                tier={(layout as StarMapLayout).tier}
                coverUrl={coverUrls[star.albumId]}
                onActivate={() => navigate('/map/' + star.albumId)}
              />
            ))}

            {/* Tier-1 only: the hazy glowing overlay over each category
                constellation. Rendered ON TOP so it is the click target. */}
            {tier1 &&
              (layout as StarMapLayout).constellations.map((c) => (
                <ConstellationField
                  key={'field-' + c.genre}
                  constellation={c}
                  stars={starsByConstellation.get(c.genre) ?? []}
                  onActivate={drillInto}
                />
              ))}
          </>
        )}
      </svg>
    </div>
  );
}

/** The id of the most-recently appended browser filter clause (addClause appends
 * and generates the id internally; we read it back to target updateClause). */
function lastClauseId(): string | undefined {
  const clauses = useBrowserStore.getState().filter.clauses;
  return clauses[clauses.length - 1]?.id;
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
