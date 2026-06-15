// Top bar: brand + view switch + settings.
// Top-level modes are Collection (star Map ⇄ List) · Pockets · Playlists. The
// Collection tab remembers your last sub-view (map/list) and a contextual
// Map/List toggle appears while you're in it.
import { useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { SettingsModal } from './SettingsModal';
import { useBrowserStore } from '../../store/useBrowserStore';

export function TopBar() {
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const collectionView = useBrowserStore((s) => s.collectionView);
  const setCollectionView = useBrowserStore((s) => s.setCollectionView);

  const onMap = pathname.startsWith('/map');
  const onAlbum = pathname.startsWith('/album');
  const onBrowse = pathname.startsWith('/browse');
  const onPockets = pathname.startsWith('/pockets');
  const onPlaylists = pathname.startsWith('/playlists');
  // The unified Collection mode owns the star map, the browser list, and album detail.
  const inCollection = onMap || onBrowse || onAlbum;
  const [settingsOpen, setSettingsOpen] = useState(false);

  // Collection tab → the remembered sub-view. The Map/List toggle also persists the choice.
  const goCollection = () => navigate(collectionView === 'list' ? '/browse' : '/map');
  const goMap = () => {
    setCollectionView('map');
    navigate('/map');
  };
  const goList = () => {
    setCollectionView('list');
    navigate('/browse');
  };
  // Within Collection, "Map" covers the star map (+ solar system); "List" covers the browser (+ album).
  const mapActive = onMap;
  const listActive = onBrowse || onAlbum;

  return (
    <header className="pdj-topbar">
      <div className="pdj-brand" onClick={goCollection} role="button" tabIndex={0}>
        <span className="pdj-brand__mark">◎</span>
        <span className="pdj-brand__name">
          Pocket<b>DJ</b>
        </span>
      </div>
      <div className="pdj-topbar__nav">
        <nav className="pdj-viewswitch" aria-label="Mode">
          <button
            className={inCollection ? 'is-active' : ''}
            data-testid="view-switch-collection"
            onClick={goCollection}
          >
            ⊞ Collection
          </button>
          <button
            className={onPockets ? 'is-active' : ''}
            data-testid="view-switch-pockets"
            onClick={() => navigate('/pockets')}
          >
            <BagIcon /> Pockets
          </button>
          <button
            className={onPlaylists ? 'is-active' : ''}
            data-testid="view-switch-playlists"
            onClick={() => navigate('/playlists')}
          >
            <PlayIcon /> Playlists
          </button>
          <button
            className="pdj-iconbtn"
            data-testid="open-settings"
            onClick={() => setSettingsOpen(true)}
            aria-label="Settings"
            title="Settings"
          >
            ⚙
          </button>
        </nav>
        {inCollection && (
          <nav className="pdj-subswitch" aria-label="Collection view" data-testid="collection-subswitch">
            <button
              className={mapActive ? 'is-active' : ''}
              data-testid="collection-map"
              onClick={goMap}
            >
              ✦ Map
            </button>
            <button
              className={listActive ? 'is-active' : ''}
              data-testid="collection-list"
              onClick={goList}
            >
              ☰ List
            </button>
          </nav>
        )}
      </div>
      <SettingsModal open={settingsOpen} onClose={() => setSettingsOpen(false)} />
    </header>
  );
}

/** A sling/crossbody bag — the Pockets mark (a "pocket" you carry your sets in). */
function BagIcon() {
  return (
    <svg
      className="pdj-nav-ico"
      viewBox="0 0 24 24"
      width="1.05em"
      height="1.05em"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {/* diagonal sling strap */}
      <path d="M9 7 17.6 3.1" />
      {/* tall pouch body */}
      <rect x="7.2" y="6.3" width="9.6" height="14.4" rx="2.6" />
      {/* curved yoke where the strap meets the bag */}
      <path d="M7.9 10c2.5-2.1 6.5-2.1 9 0" />
      {/* front zip pocket */}
      <rect x="9.4" y="12.2" width="5.2" height="6" rx="1.5" />
    </svg>
  );
}

/** A filled play triangle — the Playlists mark (▶ a set you perform). */
function PlayIcon() {
  return (
    <svg
      className="pdj-nav-ico"
      viewBox="0 0 24 24"
      width="0.95em"
      height="0.95em"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M8 5.5v13l11-6.5z" />
    </svg>
  );
}
