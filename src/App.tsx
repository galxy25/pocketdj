import { useEffect } from 'react';
import { createBrowserRouter, RouterProvider, Navigate } from 'react-router-dom';
import { AppShell } from './components/layout/AppShell';
import { BrowserView } from './components/browser/BrowserView';
import { StarMapScene } from './components/starmap/StarMapScene';
import { SolarSystemView } from './components/starmap/SolarSystemView';
import { installDebug } from './lib/debug';

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
  useEffect(() => {
    installDebug();
  }, []);
  return <RouterProvider router={router} future={{ v7_startTransition: true }} />;
}
