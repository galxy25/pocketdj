// App chrome: top bar + routed content. Loads sources on mount.
import { useEffect } from 'react';
import { Outlet } from 'react-router-dom';
import { TopBar } from './TopBar';
import { useAppStore } from '../../store/useAppStore';

export function AppShell() {
  const refreshSources = useAppStore((s) => s.refreshSources);
  useEffect(() => {
    refreshSources();
  }, [refreshSources]);

  return (
    <div className="pdj-app">
      <TopBar />
      <main className="pdj-main">
        <Outlet />
      </main>
    </div>
  );
}
