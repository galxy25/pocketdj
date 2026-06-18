import { useEffect, useState } from 'react';
import { createBrowserRouter, RouterProvider, Navigate } from 'react-router-dom';
import { AppShell } from './components/layout/AppShell';
import { BrowserView } from './components/browser/BrowserView';
import { AlbumTrackTable } from './components/browser/AlbumTrackTable';
import { StarMapScene } from './components/starmap/StarMapScene';
import { SolarSystemView } from './components/starmap/SolarSystemView';
import { PocketsView } from './components/pockets/PocketsView';
import { PocketDetail } from './components/pockets/PocketDetail';
import { PlaylistsView } from './components/playlists/PlaylistsView';
import { PlaylistDetail } from './components/playlists/PlaylistDetail';
import { SetlistView } from './components/playlists/SetlistView';
import { installDebug } from './lib/debug';
import { seedIfEmpty } from './lib/dataActions';
import { runMigrations } from './storage/migrations';
import { requestPersistentStorage } from './storage/artCache';
import { useBrowserStore } from './store/useBrowserStore';

/** Land in Collection at the user's remembered sub-view (star Map vs. List). */
function CollectionHome() {
  const view = useBrowserStore((s) => s.collectionView);
  return <Navigate to={view === 'list' ? '/browse' : '/map'} replace />;
}

const router = createBrowserRouter([
  {
    path: '/',
    element: <AppShell />,
    children: [
      { index: true, element: <CollectionHome /> },
      { path: 'browse', element: <BrowserView /> },
      { path: 'album/:albumId', element: <AlbumTrackTable /> },
      { path: 'map', element: <StarMapScene /> },
      { path: 'map/:albumId', element: <SolarSystemView /> },
      { path: 'pockets', element: <PocketsView /> },
      { path: 'pockets/:id', element: <PocketDetail /> },
      { path: 'playlists', element: <PlaylistsView /> },
      { path: 'playlists/:id', element: <PlaylistDetail /> },
      { path: 'playlists/:id/setlist/:setlistId', element: <SetlistView /> },
      { path: '*', element: <CollectionHome /> },
    ],
  },
], {
  future: { v7_relativeSplatPath: true },
});

export function App() {
  const [ready, setReady] = useState(false);
  const [status, setStatus] = useState('Loading your vinyl…');
  useEffect(() => {
    installDebug();
    let cancelled = false;
    // Ask to keep cover-art blobs from being evicted (durable offline across restart).
    void requestPersistentStorage();
    (async () => {
      try {
        await seedIfEmpty((done, total) => {
          if (!cancelled && total) setStatus(`Loading your vinyl… ${done}/${total}`);
        });
        await runMigrations(); // forward-migrate collections to the current data version
      } catch {
        /* render the app anyway — user can import manually */
      }
      if (!cancelled) setReady(true);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  if (!ready) {
    return (
      <div className="pdj-boot">
        <h1>PocketDJ</h1>
        <div className="pdj-boot__hint">{status}</div>
      </div>
    );
  }
  return <RouterProvider router={router} future={{ v7_startTransition: true }} />;
}
