// Top bar: brand + view switch (Star Map ⇄ Browser) + settings.
import { useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { SettingsModal } from './SettingsModal';

export function TopBar() {
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const onMap = pathname.startsWith('/map');
  const [settingsOpen, setSettingsOpen] = useState(false);

  return (
    <header className="pdj-topbar">
      <div className="pdj-brand" onClick={() => navigate('/map')} role="button" tabIndex={0}>
        <span className="pdj-brand__mark">◎</span>
        <span className="pdj-brand__name">
          Pocket<b>DJ</b>
        </span>
      </div>
      <nav className="pdj-viewswitch" aria-label="View">
        <button
          className={onMap ? 'is-active' : ''}
          data-testid="view-switch-starmap"
          onClick={() => navigate('/map')}
        >
          ✦ Star Map
        </button>
        <button
          className={!onMap ? 'is-active' : ''}
          data-testid="view-switch-browser"
          onClick={() => navigate('/browse')}
        >
          ☰ Browser
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
      <SettingsModal open={settingsOpen} onClose={() => setSettingsOpen(false)} />
    </header>
  );
}
