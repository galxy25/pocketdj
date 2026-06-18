import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// PocketDJ build config.
// - React + TS app.
// - vite-plugin-pwa (Workbox generateSW): precache the APP SHELL ONLY.
//   Cover art is user data stored as IndexedDB blobs, never in the SW cache.
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      injectRegister: 'auto',
      strategies: 'generateSW',
      includeAssets: ['favicon.svg', 'star-placeholder.svg'],
      manifest: {
        name: 'PocketDJ',
        short_name: 'PocketDJ',
        description: 'Puts a DJ in your pocket. Portable, personal, offline-first music performance playlists.',
        theme_color: '#0b0f1a',
        background_color: '#0b0f1a',
        display: 'standalone',
        start_url: '/',
        icons: [
          { src: 'favicon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' },
          // TODO(polish): add rasterized 192/512 + maskable PNGs for broader install support.
        ],
      },
      workbox: {
        // App shell only. Art + data live in IndexedDB (not precached, not runtime-cached).
        globPatterns: ['**/*.{js,css,html,svg,png,woff2}'],
        navigateFallback: '/index.html',
        cleanupOutdatedCaches: true,
      },
      devOptions: {
        // Allow testing the SW/PWA behavior during `vite dev`.
        enabled: false,
      },
    }),
  ],
  server: {
    port: 5173,
    strictPort: false,
    // Dev-only mirror of the prod CloudFront `/pocketdj/*` behavior: forward online
    // search to the OpenSearch Serverless (aoss) origin with changeOrigin so the
    // Host matches what the browser SigV4-signs. Lets online mode work in `vite dev`.
    // (Production is served by CloudFront, which has its own equivalent behavior.)
    proxy: {
      '/pocketdj': {
        target: 'https://zxvkpgoc5ivtrbqp37s5.us-west-2.aoss.amazonaws.com',
        changeOrigin: true,
        secure: true,
      },
    },
  },
  build: {
    target: 'es2022',
    sourcemap: true,
  },
});
