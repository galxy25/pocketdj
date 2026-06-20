// App chrome: top bar + routed content + the mini player. Loads sources + the rips
// manifest on mount.
import { useEffect } from 'react';
import { Outlet } from 'react-router-dom';
import { TopBar } from './TopBar';
import { Banner } from './Banner';
import { MiniPlayer } from '../player/MiniPlayer';
import { useAppStore } from '../../store/useAppStore';
import { useRipsStore } from '../../store/useRipsStore';

export function AppShell() {
  const refreshSources = useAppStore((s) => s.refreshSources);
  const initRips = useRipsStore((s) => s.init);
  useEffect(() => {
    refreshSources();
    void initRips();
  }, [refreshSources, initRips]);

  return (
    <div className="pdj-app">
      <Banner />
      <TopBar />
      <main className="pdj-main">
        <Outlet />
      </main>
      <MiniPlayer />
    </div>
  );
}
