# User profiles (CloudKit) + the public rip server — the beta-distribution release

Status: **implemented** on `feat/user-profiles-public-rip` (2026-07-18).
Goal: PocketDJ becomes distributable to OTHER beta testers — each user gets a synced
identity + session data via their own iCloud account, and the iMac rip server leaves the
Tailnet so testers' devices can reach it, hardened for the open internet.

The release bundles four features:

1. **User profiles + iCloud session sync** (CloudKit private DB)
2. **Public rip server** (Tailscale Funnel `:10000`, tiered tokens, rate limits)
3. **Browse ▸ Discover** — search all of Apple Music, one-tap Add → shared rip catalog
4. **Up Next ▸ collection button** — the durable-session ghost-state fix

---

## 1. User profiles + iCloud session sync

### Identity: `ProfileStore`

`apple/PocketDJ/State/ProfileStore.swift` — `pocketdj-profile.json` in Application
Support: `{ schemaVersion, id (durable random UUID, minted once), name, createdAtMs }`.

- **NAME OWNERSHIP.** `SettingsStore.pocketDJName` stays the wired-everywhere read path
  (`collections.performerName`, the jukebox DJ line). The profile is the *synced source
  of truth*: `onNameApplied` (wired in `PocketDJApp.init`) mirrors profile → settings +
  collections on every local edit AND every cloud pull. A pre-profile device migrates its
  existing `pocketDJName` into the profile at first launch (`migrateIfNeeded`).
- Settings ▸ **Profile** panel (replaces the old PocketDJ-name section): name field
  (edits flow through `profile.setName`), **Sync with iCloud** toggle
  (`settings.cloudSyncEnabled`, default ON), **Sync now** + status line (last summary ·
  time, "iCloud unavailable", or the last error).

### Sync engine: `CloudSyncService`

`apple/PocketDJ/Services/CloudSync/` — document-level sync of the session-data JSON
files against the user's **private** CloudKit database, container
`iCloud.com.levi.pocketdj`. Zero server cost, zero shared storage, per-Apple-ID.

**Registry** (record key → Application Support file → post-pull apply):

| key | file | pull applies via |
|---|---|---|
| `profile` | pocketdj-profile.json | `ProfileStore.reloadFromDisk` (+ name mirror) |
| `collections` | pocketdj-collections.json | `CollectionsStore.reloadFromDisk` (+ Spotlight reindex) |
| `edits` | pocketdj-edits.json | `EditsStore.reloadFromDisk` |
| `play-stats` | pocketdj-play-stats.json | `PlayStatsStore.reloadFromDisk` |
| `play-history` | pocketdj-play-history.json | `PlayHistoryStore.reloadFromDisk` |
| `mix-sessions` | pocketdj-mix-sessions.json | `MixSessionStore.reloadFromDisk` (guarded: never mid-recording) |
| `playback-session` | pocketdj-playback-session.json | file-only (see ordering) |
| `mix-decks` | pocketdj-mix-decks.json | file-only (see ordering) |

**Excluded by design:** settings (device-specific security-scoped bookmarks), burns,
studio documents + all media (they reference device-local files), streaming tokens
(Keychain), catalog caches (re-fetchable).

**CloudKit shape.** One `PDJDoc` record per key in the default zone of the private DB,
recordName `doc-<key>`, fields `payload` (CKAsset — documents can exceed the ~1 MB
in-record limit), `modifiedAtMs` (Double, the WRITER's file mtime), `deviceName`
(String). Everything is **fetch-by-record-ID** (`CKDatabase.records(for:)` with
`desiredKeys` for the cheap meta probe) — no CKQuery, so the classic
"recordName is not queryable" schema trap can't occur.

**Doctrine.**
- **LWW per document**, mtime-based with ±2 s skew slack: cloud newer → pull; local
  newer → push; else in-sync. A watermark (`pocketdj-cloudsync-state.json`) prevents a
  fresh pull's new mtime from bouncing identical bytes back up.
- **Pull safety:** before overwriting, the local file is backed up to `<name>.pre-cloud`
  (the user-data-safety rule).
- **Launch ordering** (the load-bearing bit): stores decode their documents in
  `PocketDJApp.init`, so a pull must *re-apply*. Reloadable stores get a
  `reloadFromDisk()` seam. The two durable-session stores read their snapshots LATER
  (RootView's launch task) — so RootView **awaits `syncAtLaunch()`** (deadline-bounded,
  8 s; the pass continues in background past the deadline) *before*
  `restorePersistedSessionIfIdle()` / `restorePersistedMixIfIdle()`. A brand-new device
  therefore restores the CLOUD session, not an empty one.
- **Push triggers:** the launch pass, a throttled foreground pass (≥5 min gap), a
  push-only fire-and-forget on scenePhase `.background` (after the existing store
  flushes, so the freshest bytes upload), and Settings ▸ Profile ▸ Sync now.
- **Off** under `PDJ_USE_FIXTURE` (tests must never touch a real account), when the
  toggle is off, or when no iCloud account is signed in (gracefully re-checked per pass).
- **Known v1 limits (accepted):** whole-document LWW means the most recently active
  device wins per document — interleaved same-document edits on two devices don't merge
  (play-history is shaped for a future event-union merge; see its installId doc). A pull
  landing mid-edit is bounded by the backup file + the "local newer wins" comparison.

**Testing seam.** `CloudDocDatabase` protocol; the real `CKCloudDocDatabase` is
`#if canImport(CloudKit)`. Unit tests drive the full engine against an in-memory
implementation (`PocketDJTests/CloudSyncServiceTests.swift`) — no account, no network.

### Entitlements / portal state

- All three app entitlement files (CarPlay=iOS, macOS, base=visionOS) declare
  `com.apple.developer.icloud-services = [CloudKit]` + container
  `iCloud.com.levi.pocketdj`. Widgets don't touch CloudKit.
- The **ICLOUD capability is already enabled** on App ID `com.levi.pocketdj` — done
  headlessly via the ASC API (`POST /v1/bundleIdCapabilities`, capabilityType ICLOUD).
- The **container** has no public ASC API; it registers via Xcode automatic signing
  (`-allowProvisioningUpdates`) on the first device/archive build. If that ever fails:
  Developer portal ▸ Identifiers ▸ iCloud Containers ▸ `iCloud.com.levi.pocketdj` (one
  time), then rebuild.
- **CloudKit schema:** materializes just-in-time in the *Development* environment on
  first save from a debug build. Before TestFlight users can sync, deploy it to
  *Production* once: CloudKit Console ▸ pocketdj container ▸ Deploy Schema Changes.

---

## 2. Public rip server (Tailscale Funnel `:10000`)

The rip server leaves the Tailnet so beta testers can rip/stream/Discover. Its many
write endpoints made "just funnel it" unacceptable — public mode is a hardened mode.

### Ports on the iMac (Funnel is per-PORT — all three HTTPS ports now in use)

| port | what | reach |
|---|---|---|
| 443 | `tailscale serve` → rip server | **Tailnet-only** (kept — Levi's original path) |
| 8443 | Funnel `/jukebox` → jukebox broker | public |
| **10000** | **Funnel → rip server** | **public** (new) |

### Server hardening (`scripts/rip-server.mjs`)

- **`RIP_PUBLIC=1`** refuses to boot without BOTH tokens, and refuses equal tokens
  (a leaked user token must not be the admin token).
- **Two tiers.** `RIP_TOKEN` (user — beta testers): `/rip`, `/rip-collection`,
  `/stemify`, `/stemify-cancel`, `/rip-cancel`, `/status`, `/jobs`, `/hls` (+ `?token=`),
  `/search`, `GET /am-sync/<id>`. `RIP_ADMIN_TOKEN` (admin — Levi only; a superset
  credential accepted everywhere): the corpus-scale mutators — `/backfill-cuts`,
  `/retag-cuts`, `/backfill-beatgrids`, `/stemify-collection`, `/backfill-stems`,
  `/analysis`, `/ingest-digital`, `POST /am-sync`. Wrong tier → 403 (authenticated,
  wrong tier — distinct from 401).
- **Rate limits** (public mode, user tier only — admin automation like the nightly
  indexers is exempt): per-IP sliding windows, GET 600/min (HLS segments + 2 s job
  polls are chatty by design), POST 30/min (POSTs enqueue real capture work).
  `x-forwarded-for`-aware (Funnel proxies). Plus a 32 MB request-body cap.
- **Secrets** live in `~/.pocketdj/rip-server.env` (chmod 600; the server reads it at
  boot, real env wins) — never in the repo or the checked-in launchd plist.

### Rollout (one-time, ON the iMac)

```
scripts/setup-rip-funnel.sh
```
Idempotent: generates + persists both tokens (re-runs keep existing ones), writes
`RIP_PUBLIC=1`, kickstarts the launchd agent, verifies `/health` shows `auth+public`,
mounts `tailscale funnel --bg --https=10000 http://127.0.0.1:8787`, prints the public
base + both tokens (distribute the USER token to testers; the admin token goes only in
Levi's own Settings ▸ Rip server).

### Client

`Config.ripServerBase` → `https://levis-imac.tail2e2bdf.ts.net:10000` (Funnel URLs are
publicly resolvable). Settings ▸ Rip server token: Levi pastes the admin token; beta
testers the user token. Everything that only reads the public S3 rips bucket keeps
working with no token at all.

### Verification

`scripts/test/rip-auth-e2e.mjs` (hermetic; stubbed iTunes) — boot refusals, tier map
(401/403/200), rate-limit trip + admin exemption, `/search` mapping. Plus
`stream-e2e.mjs` still green (HLS + `?token=`), and a live iTunes proxy spot-check.

---

## 3. Browse ▸ Discover (search Apple Music, Add → shared catalog)

- Server: `GET /search?q=` — an iTunes Search API proxy on the rip server (user tier,
  rate-limited). Hits are annotated against the live rip manifest: each carries the
  `amrec_<storeId>` songId the add flow rips under, plus `ripped`/`url` when the capture
  already exists. The iMac proxies so clients need one base URL + token, and so
  annotation is server-side.
- App: **Discover** is a third Browse mode (alongside the catalog/online modes). Search
  → results with artwork/title/artist/album/duration; **＋ Add** fires the EXISTING
  `POST /rip` ad-hoc flow (recognizer's `amrec_` path) and rides the server's durable
  conc-1 FIFO queue — multiple beta users are served fairly by arrival order. Already-
  ripped hits show their in-catalog state. (Implementation: `Views/BrowseDiscover.swift`
  + `RipsStore` discover client; see the code for the exact UI wiring.)
- The rip lands in `rips/manifest.json` (public bucket) ⇒ every user can stream/burn it.

## 4. Up Next ▸ collection button (ghost-state fix)

Restored durable sessions used to be editable ONLY from the Now Playing widget — the
richer collection view was unreachable ("ghost state"). Now:

- `playNow` records `nowPlayingOriginId` (threaded from the playlist/pocket/album/
  artist/source-playlist play sites); `CollectionsStore.originCollection` maps a run's
  `sourceSetlistId` → `(kind, collection id)`.
- `SetlistPlayer` captures the origin per run (`originProvider`, same doctrine as
  `historyContextProvider`) and persists it in the durable snapshot
  (`SourceRef.originKind/originId`, optional keys — old snapshots still decode).
  `restore()` rehydrates it.
- `NowPlayingPanel`'s "Up next (N)" header shows a playlist-icon button (a11y id
  `np-open-collection`) that routes through the existing `IntentRoute`/`pendingRoute`
  mechanism (new `setlist`/`album`/`artist`/`sourcePlaylist` cases) to the origin's
  editable view. Re-validated against live stores at render — a deleted origin hides
  the button.

---

## Beta-tester onboarding (the point of all this)

1. TestFlight invite (apple-publish flow, all platforms).
2. Tester signs into iCloud (profile + session sync just works; no account = app still
   fully functional, device-local).
3. Give them the rip-server USER token → Settings ▸ Rip server (URL is baked). That
   unlocks rip-on-demand, live HLS, and Discover.
4. One-time on our side: deploy the CloudKit schema to Production (§1) and run
   `setup-rip-funnel.sh` (§2).
