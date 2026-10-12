# Remote endpoint config (schema v1)

Status: shipped on `feat/remote-endpoints` (2026-10-12). Purpose: move PocketDJ between AWS
accounts — **blue** `011183829623` ↔ **green** `623170744161` — and back, **without an app
release**. Companion to `docs/aws-migration-plan.md` (on `feat/aws-green`).

## The problem

Every client hardcoded account-bound hosts: the prod/dev CloudFront distributions, two API
Gateway ids, and S3 bucket hosts whose names embed the account id. A new account gets new
values for all of them, so every installed build would keep calling the old account forever.

## The document

One JSON document. Committed per environment as `config/endpoints.<env>.json`
(`config/endpoints.blue.json` = today's values; green adds `config/endpoints.green.json`).

```json
{
  "v": 1,
  "env": "blue",
  "endpoints": {
    "catalogBase":          "https://d2p4cubg6se03u.cloudfront.net",
    "catalogBaseDev":       "https://djictbz9w796r.cloudfront.net",
    "ripsBase":             "https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com",
    "amPlaylistSyncBase":   "https://ynwdaa8vh2.execute-api.us-west-2.amazonaws.com",
    "recEngineBase":        "https://n5ordrwfe9.execute-api.us-west-2.amazonaws.com",
    "listeningPocketsBase": "https://n5ordrwfe9.execute-api.us-west-2.amazonaws.com",
    "diagLogsBase":         "https://pocketdj-logs-011183829623.s3.us-west-2.amazonaws.com",
    "searchConfigURL":      "https://d2p4cubg6se03u.cloudfront.net/search-config.json"
  },
  "aliases": { "catalogBase": [], "catalogBaseDev": [] }
}
```

| Key | Required | Used by | What it is |
|---|---|---|---|
| `catalogBase` | yes | Apple, Android | Prod CloudFront: `current-index.json`, `apple-music-index.json`, `digital-index.json`, `/art`, `/lyrics`, `timbre.json`, `favorites-seed.json` |
| `ripsBase` | yes | Apple, Android, PWA | Public rips bucket: `rips/manifest.json`, `rips/<id>.mp3`, waveforms, instrument packs |
| `amPlaylistSyncBase` | yes | Apple | API Gateway → `pocketdj-am-playlist-sync` |
| `recEngineBase` | yes | Apple | API Gateway → `pocketdj-rec-engine` |
| `diagLogsBase` | yes | Apple | Private diag bucket (TestFlight `DiagLog` SigV4 PUT) |
| `catalogBaseDev` | no → `catalogBase` | Apple, Android | Dev CloudFront (local `.dev` builds only) |
| `listeningPocketsBase` | no → `recEngineBase` | Apple | `/pockets` routes (same HTTP API today) |
| `searchConfigURL` | no → `catalogBase/search-config.json` | Apple, Android | Names the OpenSearch host (`{host,region,index}`) |

`aliases.catalogBase` / `aliases.catalogBaseDev`: optional lists of extra catalog **hosts** whose
persisted URLs should be rebased onto this doc's bases (see "Persisted URLs").

### Validation (all three clients, identical rules)

Canonical implementation: `src/config/endpointSchema.ts` (also used by
`scripts/validate-endpoints.ts`, which `deploy.sh` runs before publishing). Swift:
`EndpointConfig.decode` (`apple/PocketDJ/Support/RemoteEndpoints.swift`). Kotlin:
`EndpointConfig.decode` (`android/.../data/config/RemoteEndpoints.kt`).

A document is accepted only if:

- it is a JSON object with `v == 1` (number, not `"1"`/`true`) and a non-empty `env`;
- every **required** key is present;
- every known key present (required or optional) is an `https` URL with **no** userinfo, port,
  query or fragment, whose host is on the allowlist:
  `pocket-dj.com`, `*.pocket-dj.com`, `*.cloudfront.net`,
  `<id>.execute-api.us-west-2.amazonaws.com`, `pocketdj-*.s3.us-west-2.amazonaws.com`.

One bad URL rejects the **whole** document (no partial application). Unknown top-level or
endpoint keys are ignored (forward compatible). Absent optional keys derive from the **same**
document — never from the compiled-in blue values, so a green doc can't half-fall-back to blue.
Trailing slashes are trimmed.

## Where clients fetch it — the stable URL

**`https://app.pocket-dj.com/config/endpoints.json`** (native clients).
The PWA fetches the same file **same-origin** (`<BASE_URL>config/endpoints.json`).

Why this URL:

- `app.pocket-dj.com` is the prod PWA host: CloudFront over the prod web bucket
  (`pocketdj-prod-web-<acct>`), which `scripts/deploy.sh` already owns. It is our own domain,
  so the URL is account-independent: the `pocket-dj.com` Route 53 zone moves with the account
  (migration plan, phase 4) and the name keeps resolving to whichever account serves the app.
- `pocket-dj.com` (apex) exists but is a **separate** site (a different bucket/distribution, not
  deployed by this repo; `/config/endpoints.json` there is a 403). Using it would add a second
  deploy path for no gain, so it is not used.
- `jukebox.pocket-dj.com` is the dev bucket under `/jukebox` — wrong lifecycle.
- The `*.cloudfront.net` names are exactly what we are trying to escape.

Caveat: the app host's SPA fallback answers a **missing** file with `index.html` and **200**. All
clients parse the body and reject non-JSON, so a missing doc is just "rejected (not json)".

## Resolution order + lifecycle

1. **Launch, synchronously:** last-good accepted doc (persisted) → else compiled-in defaults
   (= `config/endpoints.blue.json`; tests pin the equality on all three platforms).
   - Apple: `Application Support/pocketdj-endpoints.json` (raw doc + seen catalog hosts; the doc
     is re-validated on load, so a tampered cache falls back to compiled-in).
   - Android: `filesDir/pocketdj-endpoints.json`, same shape.
   - PWA: `localStorage["pdj.endpoints.v1"]`.
2. **Launch, async (never blocks):** fetch the remote doc (10 s timeout, local HTTP cache
   bypassed). Accepted → becomes active immediately and is persisted as the new last-good.
   Rejected / HTTP error / offline → ignored; the current config stays.
3. **Foreground:** refetch, throttled to once per 15 minutes (Apple `scenePhase == .active`,
   Android `MainActivity.onStart`, PWA `visibilitychange`).

### When does a change take effect?

Call sites read the resolver **at request time** (`Config.ripsBase` etc. are computed; stores
that used to capture a base URL at init now hold only an optional test override and read
`Config` live: `RipsStore`, `InstrumentPackStore`, `RecEngineClient`, `ListeningPocketsClient`,
`AMPlaylistSyncClient`, `MusicUserTokenService`, `DiagLog`). So a new config applies to the
**next** request. In-flight work is not torn down:

- a background download already resumed keeps its URL (TransferCoordinator records persist the
  absolute URL);
- an Apple Music sync job already polling keeps its job URL (`poll` captures it once); a job
  re-attached on a later launch after a flip gets a 404 from the new account → `jobGone` →
  a fresh submit;
- the online-search host config (`SearchConfig`) is memoized per resolver *generation*: the next
  search after a flip re-reads `searchConfigURL`.

On Android a changed config also re-reads the rips manifest; the PWA does the same via
`onEndpointsChange`. On Apple the manifest refreshes on its normal cadence (same content in
both accounts after the data sync).

### Persisted URLs

Settings ▸ Sources stores built-in catalog sources as absolute URLs
(`https://d2p4cubg6se03u.cloudfront.net/current-index.json`). They are **not** rewritten on disk;
instead `SourceConfig.url` (Apple) / `AppSettingsStore.decodeSources` (Android) rebase them at
read time when the host is a known catalog host: the compiled-in blue host, any host in the
doc's `aliases`, or any catalog host a previously accepted config used (persisted history — so
a source saved while on green still rebases after flipping back to blue). Prod-tier hosts go to
`catalogBase`, dev-tier to `catalogBaseDev`; custom user sources pass through untouched.

Other persisted absolute URLs (in-flight transfer records, Jukebox snapshots' `streamUrl`,
catalog offline-cache keys) keep the old host until refreshed. Keep the old account's buckets
readable for a cut-over window.

## Observability

- Apple diag log (TestFlight/Debug, S3 `diag/*`): `[endpoints] launch env=blue source=cached
  fetch=not fetched` right after the `[launch]` line, then `[endpoints] checked|changed …` after
  the launch fetch and whenever a foreground fetch changes the backend.
- Apple Settings ▸ Debug ▸ **Backend**: the same summary + a "Re-check endpoints" button.
- Android Settings ▸ About ▸ **Backend** row; logcat tag `PocketDJ`, `[endpoints] …`.
- PWA: `console.info("[endpoints] …")` after the launch fetch; Settings modal footer
  "Backend: blue (remote, accepted)".

## Publishing (scripts/deploy.sh)

`scripts/deploy.sh <dev|prod>` validates `config/endpoints.${PDJ_ENDPOINTS_ENV:-blue}.json`
with the client rules and uploads it to `s3://<web bucket>/config/endpoints.json` with
`Cache-Control: public,max-age=300`, `Content-Type: application/json`. The site sync excludes
`config/*` so `--delete` never removes it. The whole-site deploy invalidates `/*`.

To publish **only** the endpoint doc (the flip):

```bash
CONFIG_ONLY=1 PDJ_ENDPOINTS_ENV=green scripts/deploy.sh prod
```

(no build, no site sync; uploads the doc and invalidates `/config/*`). Also publish to `dev` if
dev builds should follow. `deploy.sh` targets the account of the AWS profile it runs under
(`AWS_PROFILE_OVERRIDE`, default `levi`).

`deploy.sh` also now serves `search-config.json` `no-cache` (it was `immutable, 1 year`, which
pinned clients to a stale OpenSearch host). The Apple client additionally bypasses its local
URL cache for that file.

## Flip runbook

Prereqs: green stack up and data synced (migration plan phases 2–3); `config/endpoints.green.json`
committed with green values and passing `npx tsx scripts/validate-endpoints.ts config/endpoints.green.json`.
Add the blue catalog hosts to green's `aliases` only if you want them rebased explicitly (the
compiled-in blue host is always known).

**Blue → green**

1. While `app.pocket-dj.com` is still served by **blue**:
   `CONFIG_ONLY=1 PDJ_ENDPOINTS_ENV=green scripts/deploy.sh prod` (blue profile).
2. Also publish the same doc into **green's** prod web bucket (green profile, e.g.
   `AWS_PROFILE_OVERRIDE=<green> CONFIG_ONLY=1 PDJ_ENDPOINTS_ENV=green scripts/deploy.sh prod`),
   so the URL answers identically before and after the DNS move.
3. Clients pick it up on next launch, or within 15 min of foregrounding (+ ≤5 min HTTP max-age).
   Verify: Settings ▸ Debug ▸ Backend reads `env=green source=remote`; S3 diag log shows
   `[endpoints] changed env=green`.
4. Then (phase 4) move the `pocket-dj.com` zone / repoint `app.pocket-dj.com` at green's
   distribution. Both buckets carry the green doc, so nothing changes for clients.
5. Leave the blue resources up until old builds (without this feature) age out — see the
   migration plan's shim question.

**Green → blue (rollback)**: the same with `PDJ_ENDPOINTS_ENV=blue`, published to whichever
account(s) currently serve `app.pocket-dj.com` (both, during cut-over).

**Emergency:** if the endpoint doc itself is broken, clients ignore it and keep their last-good
config; deleting the object makes the SPA fallback answer with HTML, which is also ignored.

## What cannot be remote-configured

- **Builds released before this feature** (App Store 1.0.0–1.0.2, existing TestFlight/Android
  builds) — they only know their hardcoded blue hosts. They need old-account shims or an update.
- **The config URL itself** (`app.pocket-dj.com`) — the bootstrap. Moving off that domain needs a
  release. It survives an account move because the domain moves with us.
- **The PWA's own origin** — the PWA loads its catalog, art and search proxy origin-relative from
  whichever distribution serves it; only `ripsBase` is remote-configured there. Moving the PWA is
  a DNS move of `app.pocket-dj.com`.
- **Credentials**: the diag-writer key (Keychain/credsync), the read-only search key, the
  rec-engine enrollment secret (`Config.recEngineEnrollSecret`, compiled in), and the
  owner iCloud hash. The green rec Lambda must keep the same `REC_ENROLL_SECRET`, and the green
  diag bucket needs a green key delivered the existing way.
- **The OpenSearch host** stays in `search-config.json` (already remote, served from
  `catalogBase`) rather than this doc: `*.aoss.us-west-2.on.aws` is not on the allowlist, and the
  baked fallback host in `SearchService.swift` / `esClient.ts` remains blue.
- **Universal Links / associated domains** (`jukebox.pocket-dj.com`) — entitlement, domain-based,
  not account-bound.
- **User-configured** rip-server / jukebox URLs — never shipped, nothing to flip.
