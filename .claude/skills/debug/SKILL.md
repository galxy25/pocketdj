---
name: debug
description: Debug PocketDJ by running the dev server, driving the browser, auditing data ops, and inspecting client state. Use when asked to "debug the app", "inspect pocketdj state", "why is X not working", or to figure out why data/UI behaves wrong. Covers the PDJ_API transcript, the window.__pdj dev handle, and IndexedDB inspection.
---

# Debug PocketDJ

PocketDJ's only backend is the client (React + Vite PWA). All state is in the
browser: IndexedDB DB `pocketdj` (stores: `sources`, `items`, `art`, `meta`).
Every storage/data op emits ONE console line `PDJ_API {"t":…,"op":"…",…}`
(see `src/lib/log.ts`) — that's your audit log.

## 1. Start the dev server

```bash
npm run dev        # Vite dev server at http://localhost:5173
```

The dev server log is just console output (no separate logfile). Note the PWA
service worker is disabled in dev (`devOptions.enabled: false`), so debug app
logic in dev and the SW separately via `npm run preview`.

## 2. Drive the app with the Playwright MCP browser

Use the Playwright MCP browser tools to navigate, screenshot, and read console:

- `browser_navigate` to `http://localhost:5173` (and routes `/browse`, `/map`,
  `/map/:albumId`).
- `browser_snapshot` / `browser_take_screenshot` to see UI state.
- `browser_console_messages` to read the console.
- `browser_evaluate` to run JS in the page (inspect state, call the dev handle).

## 3. Audit data ops via the PDJ_API transcript

Filter console output for the transcript prefix and read the op stream:

- Grep console messages for `PDJ_API` to get the ordered list of data ops.
- Each line is JSON: `{"t":…,"op":"…", …details}`.
- Common ops: `db.open`, `db.putItem`, `db.bulkPutItems`, `import.index`,
  `import.zip`, `export.zip`, `art.cache`, `art.generate`, `filter.apply`,
  `sort.apply`, `starmap.layout`, `mock.load`.

If a feature "isn't working", check whether its expected op fired (e.g. no
`filter.apply` line means the filter never ran; no `db.bulkPutItems` after an
import means data never landed).

## 4. Inspect / reset state with the dev handle

A dev-only handle `window.__pdj` is exposed. Drive it via `browser_evaluate`:

```js
await window.__pdj.counts();        // counts per store — how much data is loaded
await window.__pdj.loadMock();      // load mock data (public/mock-index.json)
await window.__pdj.loadIndex(json); // load a specific index object
await window.__pdj.exportZip();     // export current data as a zip
await window.__pdj.clear();         // wipe IndexedDB — reset to empty
```

Typical loop: `counts()` to see what's loaded -> `clear()` to reset ->
`loadMock()` (or load a real index) -> re-check `counts()` and the transcript.

## 5. Inspect IndexedDB directly

The data of record is IndexedDB DB `pocketdj`. Inspect it via:

- DevTools - Application - IndexedDB - `pocketdj` (stores: sources, items, art, meta).
- Or `browser_evaluate` reading the stores programmatically (the app uses `idb`).

Cover art lives in the `art` store as blobs (never in the SW cache), so missing
art is an IndexedDB / `art.cache` problem, not a build/cache problem.

## Loading data while debugging

- Mock data: `npm run gen:mock` -> writes `public/mock-index.json`, then use the
  in-app "Load demo data" button or `window.__pdj.loadMock()`.
- A real index: the indexer (`.claude/skills/analog-indexer/`) produces
  `index-out/index.json`; load it via `window.__pdj.loadIndex(json)` or the
  in-app Import button.
