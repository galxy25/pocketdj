# Offline-first catalog cache + conditional refresh — Design

**Status:** Proposed (design review)
**Fixes:** index/source playlists disappearing after background→foreground; cold relaunch
showing an empty UI while it re-downloads a catalog it already had.

---

## 1. Root cause (confirmed)

The native app is **not offline-first**, and a refresh is allowed to **replace good data with
empty/partial data**:

- `RootView.task` → `AppModel.loadIfNeeded()`. On a cold launch `state == .idle`, so it goes
  `.loading` → `fetchIndex()` → a **full network download of every enabled source**, with an
  **empty UI** until it finishes (`AppModel.swift:61–83`, `RootView.swift:91`).
- `CatalogService` already keeps a per-source on-disk cache
  (`Application Support/catalog-cache/<sha256(url)>.json`), but it's used **only as a fallback
  when a fetch throws** — never to render instantly (`CatalogService.swift:31–41`).
- `fetchIndex()` loops sources and **silently skips** any that fail
  (`AppModel.swift:121–133`); the merged result is assigned **atomically** to `indexPlaylists`
  (`AppModel.swift:70`). So a source that times out on a slow relaunch is dropped, and
  `indexPlaylists` is overwritten with the smaller set → **the index playlists vanish**.
- There is **no scene-phase reload** (`PocketDJApp.swift` `.onChange(of: scenePhase)` only pokes
  streaming + transfers). So a genuinely-alive app keeps its state — but **iOS routinely kills
  backgrounded apps**, making "switch away and back" a **cold relaunch** that hits the path
  above. That's why the background-resume symptom and the force-quit symptom are the **same bug**.

`.failed` (or `.loading`) also hides the catalog entirely, masking any data that's actually still
in memory or on disk.

---

## 2. Principles

1. **The on-disk cache is the source of truth for what's on screen.** The app renders from it
   immediately and never shows empty when a cache exists.
2. **The network only ever *upgrades* the cache** — after a *complete*, *newer* fetch. A refresh
   must never reduce the visible catalog/playlists to an empty or partial set.

---

## 3. Design

### A. Instant render from cache (fixes the empty cold-start)
On launch, **before any network**, synchronously load + merge each enabled source's cached index
from disk → populate `catalog` / `indexPlaylists` / `sourceTags` → `state = .loaded`. The UI shows
the full last-known catalog instantly. Then kick a background refresh (B). True first launch with
no cache is the only time we show a loading/empty state.

### B. Conditional refresh (only re-pull when newer)
Persist a **validator** with each cached source and use a conditional GET:
- Store `{ schemaVersion, index, lastModified, etag, cachedAt }` (wrap the cached bytes, or a
  sidecar `<hash>.headers.json`).
- Refresh request adds `If-Modified-Since: <lastModified>` (+ `If-None-Match: <etag>` when present).
- **304 Not Modified** → keep the cache as-is (no re-decode, no re-write); just bump `cachedAt`.
- **200** → decode, write cache + validator, swap into the published state.
- The catalog indexes deploy as `Cache-Control: no-cache` and sit on S3/CloudFront, which return
  **Last-Modified** and honor **If-Modified-Since** — so conditional GET works today. ETag is used
  opportunistically if present. Reuse `RipsStore.httpDateFormatter` (RFC-1123) for parsing.

### C. Non-destructive refresh (fixes the disappearing playlists)
- Build the merged catalog into a **local** value; assign to the published properties **only on a
  complete success** — i.e. *every* enabled source resolved via network **or** its cache.
- Per source, on a network failure: use that source's disk cache; if it has **no** cache, **keep
  the prior in-memory copy** for that source rather than dropping it.
- Net effect: a slow/flaky/offline refresh leaves the visible catalog + playlists **unchanged**.
  `indexPlaylists` only changes when a newer, complete index actually arrives.

### D. Non-destructive state model (fixes `.failed` hiding everything)
Render whenever any cache/in-memory catalog exists. Surface refresh status as a **non-destructive
hint**, not an empty screen:
- `refreshing` (subtle spinner), `freshAt(date)` ("Updated 2h ago"), `offlineStale` ("Offline —
  showing saved catalog"), `error` only when there is genuinely nothing cached.
- `reload()` (Settings "Reload catalog", Retry) keeps showing current data while it refreshes;
  it no longer blanks via `state = .idle`.

### E. Refresh on resume (optional, now safe)
Because refresh is conditional + non-destructive, we can add a `scenePhase == .active` →
`refresh()` so the catalog stays current — without the current blank-and-refetch. (Usually a cheap
304.)

---

## 4. Implementation surface

- **`CatalogService.swift`**
  - `loadCached(for:) -> (IndexJSON, Validator)?` and a `Validator { lastModified, etag, cachedAt }`.
  - `writeCache` also persists the validator (atomic).
  - `loadIndex` → `refresh(using validator:)`: conditional GET, 304 short-circuit, return cached on
    any network failure (never throw when a cache exists).
  - Mirror `RipsStore.httpDateFormatter`.
- **`AppModel.swift`**
  - `seedFromCache()` — synchronous, merges cached sources, sets state `.loaded` instantly.
  - `loadIfNeeded()` → seed-from-cache (if present) → background `refresh()`.
  - `refresh()` — conditional per-source; assemble into a local; assign atomically only on full
    success; keep prior per-source value on failure.
  - `refreshStatus` published for the badge; `reload()` no longer resets to `.idle`.
- **Views** — a small status badge (Browse/Playlists header). Playlists `sourcesSection` keeps the
  current "hide when empty" (empty only happens on true first-launch-offline now).
- **Tests**
  - cache round-trip incl. validator; 304 keeps `indexPlaylists`; offline keeps `indexPlaylists`;
    one-source-fails keeps the other source's playlists; cold-start renders from cache (no `.loading`
    when a cache exists); first-launch-offline shows the error/empty state.

---

## 4b. Scope decisions (2026-06-30)
- **Implement A–D, no status badge** — silent offline-first; minimal UI change (Playlists/Browse
  just never blank when a cache exists). No `refreshStatus` surfaced in UI.
- **No resume refresh (skip E)** — refresh only on cold launch + the Settings "Reload catalog"
  button. (Foreground stays instant from memory; iOS-kill relaunch seeds from cache + refreshes.)

## 5. Notes / risks
- Builds on the **existing** per-URL disk cache (`sha256(url)`) — no new cache location.
- Schema-version the cache so a format change is a cache-miss, not a crash.
- Keep the 12s/30s timeouts; with offline-first they no longer cause an empty UI, only a slower
  background refresh.
- `Config.environment` flips dev/prod base URLs — cache is keyed by full URL, so dev/prod don't
  collide.
