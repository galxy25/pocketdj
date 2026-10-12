import React from 'react';
import ReactDOM from 'react-dom/client';
import { App } from './App';
import { loadSearchConfig } from './search/esClient';
import { installEndpointRefresh, onEndpointsChange } from './config/remoteEndpoints';
import { useRipsStore } from './store/useRipsStore';
import './styles/index.css';

// Remote endpoint config (blue/green backend flip): non-blocking launch fetch + throttled
// foreground refetch. A changed config re-reads the rips manifest from the new bucket.
installEndpointRefresh();
onEndpointsChange(() => void useRipsStore.getState().refreshManifest());

// Warm the online-search host config early (non-blocking); esSearch also awaits it.
loadSearchConfig();

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
