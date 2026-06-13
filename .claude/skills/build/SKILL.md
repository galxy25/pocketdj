---
name: build
description: Build a production bundle of the PocketDJ PWA. Use when asked to "build the app", "build pocketdj", "make a production build", or to produce the deployable dist/ output (app shell + service worker). Also covers fast type-only checks.
---

# Build PocketDJ

PocketDJ is a React + Vite + TypeScript, offline-first PWA. The production build
compiles TypeScript, bundles with Vite, and uses `vite-plugin-pwa` (Workbox
`generateSW`) to emit a service worker that precaches the app shell.

## Fast type-only check (no bundle)

Use this to catch type errors quickly without a full build:

```bash
npm run typecheck   # tsc -b --noEmit
```

## Production build

```bash
npm run build       # runs: tsc -b && vite build  ->  dist/
```

This first type-checks/compiles (`tsc -b`), then produces the bundle in `dist/`.
If `tsc -b` fails, the Vite build does not run — fix the type errors first.

## What `dist/` contains

```
dist/
  index.html              # app shell entry (SPA)
  assets/*.{js,css}       # content-hashed bundles (immutable, safe to long-cache)
  sw.js                   # Workbox-generated service worker (precache manifest)
  workbox-*.js            # Workbox runtime
  registerSW.js           # registers the SW (autoUpdate)
  manifest.webmanifest    # PWA manifest
  favicon.svg, star-placeholder.svg, ...
```

The SW uses `registerType: 'autoUpdate'` and `navigateFallback: '/index.html'`
(SPA routing). `globPatterns` precaches only `**/*.{js,css,html,svg,png,woff2}` —
the **app shell**.

## Important: cover art is NOT precached

The PWA precaches the app shell only. **Album/cover art and all index data are
user data stored as blobs in IndexedDB (DB `pocketdj`), never in the SW cache**
(no precache, no runtime cache). A "small" build is expected — data size lives in
the browser, not in `dist/`.

## Sanity-check the build

Serve the built `dist/` locally and click around:

```bash
npm run preview     # serves dist/ on a local port (Vite preview)
```

Verify the app loads, the SW registers (DevTools - Application - Service Workers),
and that loading an index / demo data populates IndexedDB. For full behavioral
verification run the `test` skill (Playwright e2e).
