import { useEffect, useState } from 'react';
import { createBrowserRouter, RouterProvider, Navigate } from 'react-router-dom';
import { AppShell } from './components/layout/AppShell';
import { BrowserView } from './components/browser/BrowserView';
import { StarMapScene } from './components/starmap/StarMapScene';
import { SolarSystemView } from './components/starmap/SolarSystemView';
import { installDebug } from './lib/debug';
import { seedIfEmpty } from './lib/dataActions';
import { requestPersistentStorage } from './storage/artCache';

const router = createBrowserRouter([
  {
    path: '/',
    element: <AppShell />,
    children: [
      { index: true, element: <Navigate to="/map" replace /> },
      { path: 'browse', element: <BrowserView /> },
      { path: 'map', element: <StarMapScene /> },
      { path: 'map/:albumId', element: <SolarSystemView /> },
      { path: '*', element: <Navigate to="/map" replace /> },
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
