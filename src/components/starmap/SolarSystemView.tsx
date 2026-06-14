// SolarSystemView: a single album rendered as a solar system. The album cover is
// the sun at the scene center; each song is a planet orbiting it (orbit radius by
// track number, planet size by length). Static for now — geometry comes from
// src/starmap/solarSystem.ts so a future animated/3D renderer can reuse it.
import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import type { AlbumItem, SongItem } from '../../types/model';
import type { Planet, SolarSystem } from '../../types/starmap';
import { isAlbum } from '../../types/model';
import { getAlbumSongs, getItem } from '../../storage/repo';
import { useArtUrl } from '../common/useArtUrl';
import { computeSolarSystem } from '../../starmap/solarSystem';
import { msToClock } from '../../lib/format';
import { SongDetailModal } from './SongDetailModal';
import { AudioTracksModal } from './AudioTracksModal';
import './starmap.css';

// Distinct planet tints keyed off sentiment / explicit flags. Uses the palette's
// accents so a planet reads as "warmer/cooler" without needing real color data.
function planetFill(planet: Planet): string {
  if (planet.explicit) return 'var(--pdj-danger)';
  if (planet.sentimentKeywords.length > 0) return 'var(--pdj-accent-2)';
  return 'var(--pdj-accent)';
}

export function SolarSystemView() {
  const { albumId } = useParams<{ albumId: string }>();
  const navigate = useNavigate();

  const [album, setAlbum] = useState<AlbumItem | null>(null);
  const [songs, setSongs] = useState<SongItem[] | null>(null);
  // Sun cover via the shared ref-counted art cache (same path as the browser + stars).
  const sunUrl = useArtUrl(album?.coverArtKey);
  const [loading, setLoading] = useState(true);
  const [hoveredId, setHoveredId] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [audioOpen, setAudioOpen] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setAlbum(null);
    setSongs(null);
    (async () => {
      if (!albumId) {
        setLoading(false);
        return;
      }
      const item = await getItem(albumId);
      const found = item && isAlbum(item) ? item : null;
      const albumSongs = found ? await getAlbumSongs(albumId) : [];
      if (cancelled) return;
      setAlbum(found);
      setSongs(albumSongs);
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [albumId]);

  const system = useMemo<SolarSystem | null>(
    () => (album && songs ? computeSolarSystem(album, songs) : null),
    [album, songs],
  );

  if (loading) {
    return (
      <div className="pdj-solar">
        <div className="pdj-starmap__loading">Aligning the planets…</div>
      </div>
    );
  }

  if (!album || !system) {
    return (
      <div className="pdj-solar">
        <div className="pdj-starmap__header">
          <button type="button" className="pdj-starmap__btn" onClick={() => navigate('/map')}>
            ← Back to sky
          </button>
        </div>
        <div className="pdj-starmap__empty">Album not found.</div>
      </div>
    );
  }

  const c = system.size / 2; // scene center
  const sunR = 56;
  const sunClipId = 'sun-clip-' + album.id;

  // Distinct orbit radii (one ring per occupied orbit) for the faint guide rings.
  const orbitRadii = [...new Set(system.planets.map((p) => Math.round(p.orbit)))].sort((a, b) => a - b);

  return (
    <div className="pdj-solar">
      <div className="pdj-solar__header">
        <button
          type="button"
          className="pdj-starmap__btn"
          data-testid="solar-back"
          onClick={() => (window.history.length > 1 ? navigate(-1) : navigate('/map'))}
        >
          ← Back
        </button>
        <h1 className="pdj-solar__title">{system.name}</h1>
        <span className="pdj-solar__artist">{system.artist}</span>
        <button
          type="button"
          className="pdj-starmap__btn"
          data-testid="solar-to-browser"
          style={{ marginLeft: 'auto' }}
          onClick={() => navigate('/album/' + album.id)}
          title="View this album's tracks in the browser"
        >
          ☰ Browser
        </button>
      </div>

      <svg
        className="pdj-solar__svg"
        data-testid="solar-system"
        viewBox={`0 0 ${system.size} ${system.size}`}
        preserveAspectRatio="xMidYMid meet"
      >
        <defs>
          <radialGradient id="pdj-sun-glow" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stopColor="var(--pdj-accent-2)" stopOpacity="0.6" />
            <stop offset="100%" stopColor="var(--pdj-accent-2)" stopOpacity="0" />
          </radialGradient>
        </defs>

        {/* Orbit rings. */}
        {orbitRadii.map((radius) => (
          <circle key={radius} className="pdj-solar__orbit" cx={c} cy={c} r={radius} />
        ))}

        {/* Sun = album cover. */}
        <circle cx={c} cy={c} r={sunR * 1.8} fill="url(#pdj-sun-glow)" />
        <g
          className="pdj-solar__sun"
          data-testid="solar-sun"
          role="button"
          tabIndex={0}
          aria-label={`${system.artist} — ${system.name}: audio analysis`}
          onClick={() => setAudioOpen(true)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              setAudioOpen(true);
            }
          }}
        >
          <title>{`${system.artist} — ${system.name} (audio analysis)`}</title>
          {sunUrl ? (
            <>
              <clipPath id={sunClipId}>
                <circle cx={c} cy={c} r={sunR} />
              </clipPath>
              <image
                href={sunUrl}
                x={c - sunR}
                y={c - sunR}
                width={sunR * 2}
                height={sunR * 2}
                clipPath={`url(#${sunClipId})`}
                preserveAspectRatio="xMidYMid slice"
              />
            </>
          ) : (
            <circle cx={c} cy={c} r={sunR} fill="var(--pdj-accent-2)" />
          )}
          <circle cx={c} cy={c} r={sunR} fill="none" stroke="var(--pdj-accent-2)" strokeWidth={1} opacity={0.6} />
        </g>

        {/* Planets = songs. */}
        {system.planets.map((planet) => {
          const px = c + Math.cos(planet.angle) * planet.orbit;
          const py = c + Math.sin(planet.angle) * planet.orbit;
          const songId = planet.songId;
          const dur = songLength(songs, songId);
          const label = `${planet.trackNumber}. ${planet.name}${dur ? ` (${dur})` : ''}`;
          const isHover = hoveredId === songId;
          return (
            <g key={songId}>
              <circle
                className={'pdj-planet' + (isHover ? ' is-hover' : '')}
                data-testid={'planet-' + songId}
                role="button"
                tabIndex={0}
                aria-label={label}
                cx={px}
                cy={py}
                r={planet.r}
                fill={planetFill(planet)}
                onMouseEnter={() => setHoveredId(songId)}
                onMouseLeave={() => setHoveredId((h) => (h === songId ? null : h))}
                onFocus={() => setHoveredId(songId)}
                onBlur={() => setHoveredId((h) => (h === songId ? null : h))}
                onClick={() => setSelectedId(songId)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    setSelectedId(songId);
                  }
                }}
              >
                <title>{planet.name}</title>
              </circle>
              {/* Track names are shown by default for every planet; hover emphasizes. */}
              <text
                className={'pdj-planet__label' + (isHover ? ' is-hover' : '')}
                data-testid="track-label"
                x={px}
                y={py - planet.r - 5}
                textAnchor="middle"
              >
                {planet.name.length > 22 ? planet.name.slice(0, 21) + '…' : planet.name}
              </text>
            </g>
          );
        })}
      </svg>

      <SongDetailModal
        song={songs?.find((s) => s.id === selectedId) ?? null}
        albumName={system.name}
        onClose={() => setSelectedId(null)}
      />

      <AudioTracksModal album={album} open={audioOpen} onClose={() => setAudioOpen(false)} />
    </div>
  );
}

function songLength(songs: SongItem[] | null, songId: string): string {
  const s = songs?.find((x) => x.id === songId);
  return s ? msToClock(s.lengthMs) : '';
}
