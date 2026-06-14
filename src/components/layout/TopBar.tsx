// Top bar: brand + view switch (Star Map ⇄ Browser).
import { useLocation, useNavigate } from 'react-router-dom';

export function TopBar() {
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const onMap = pathname.startsWith('/map');

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
      </nav>
    </header>
  );
}
