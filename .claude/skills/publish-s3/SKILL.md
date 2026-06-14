---
name: publish-s3
description: Publish/deploy the PocketDJ PWA to AWS (S3 + CloudFront, dev or prod). Use when asked to "publish the app", "deploy to s3", "ship pocketdj", "deploy dev/prod". One command (scripts/deploy.sh) builds + syncs dist/ with the right cache tiers and auto-invalidates CloudFront; this doc explains the details + the HTTPS/PWA + SPA fallback bits.
---

# Publish PocketDJ to S3 + CloudFront

PocketDJ is an installable, offline-first PWA. Deploy = build, sync `dist/` to an S3
bucket with two cache tiers, and invalidate the CloudFront distribution that fronts it.
**CloudFront matters: a PWA's service worker requires HTTPS**, which the S3 website
endpoint (HTTP only) can't give — so the real URLs are the CloudFront HTTPS ones.

## Quick deploy (this repo)

Infra is already set up: AWS profile **`levi`** (region **us-west-2**), two public
static-website buckets, two CloudFront distributions, and `scripts/deploy.sh`.

```bash
scripts/deploy.sh dev      # build + sync + invalidate dev
scripts/deploy.sh prod     # build + sync + invalidate prod
SKIP_BUILD=1 scripts/deploy.sh dev   # reuse existing dist/
```

Live HTTPS URLs (CloudFront):

- **dev:**  https://djictbz9w796r.cloudfront.net  (distribution `E123GKAO9JVETP`)
- **prod:** https://d2p4cubg6se03u.cloudfront.net  (distribution `E1SP8M1SIF7Q8D`)

`deploy.sh` shells out to `aws --profile levi`, so a **background agent can run it**.
Overridable env: `AWS_PROFILE_OVERRIDE`, `AWS_REGION_OVERRIDE`, `CF_ID_DEV`,
`CF_ID_PROD`, `SKIP_BUILD`.

The rest of this doc explains exactly what `deploy.sh` does and why.

## 1. Build (+ ensure the seed exists)

```bash
npm run build      # tsc -b && vite build  ->  dist/
```

`dist/` contains: `index.html`, hashed `assets/*`, `sw.js`, `workbox-*.js`,
`registerSW.js`, `manifest.webmanifest`, static svgs, and the bundled catalog json.

**The seed.** The deployed site shows data with no console: on first boot the app
auto-seeds IndexedDB from `public/current-index.json` (`src/lib/dataActions.ts
seedIfEmpty`), which Vite copies into `dist/`. `deploy.sh` also ensures
`public/mock-index.json` exists (so the in-app "Load demo data" button works) by running
`npm run gen:mock` if it's missing. To ship a fresh catalog, copy the indexer's
`index-out/full/index.json` to `public/current-index.json` before building.

## 2. Sync to the bucket — two cache tiers

The SW uses `registerType: 'autoUpdate'`. Users only get a new deploy if the browser can
fetch a **fresh** shell (`sw.js` / `registerSW.js` / `index.html` /
`manifest.webmanifest`); if those are long-cached, users get stuck on a stale SW. So
`deploy.sh` does two `aws s3 sync` passes:

**Tier A — hashed assets: immutable, 1-year cache.** Filenames change every build:

```bash
aws s3 sync dist/ s3://<bucket> --profile levi --delete \
  --cache-control "public,max-age=31536000,immutable" \
  --exclude index.html --exclude sw.js --exclude registerSW.js --exclude manifest.webmanifest
```

`--delete` cleans up old hashed assets (safe — the SW precache references current hashes).

**Tier B — SW + shell entry points: `no-cache`** (must revalidate every time; these keep
the same names across deploys):

```bash
aws s3 sync dist/ s3://<bucket> --profile levi --cache-control "no-cache" --exclude "*" \
  --include index.html --include sw.js --include registerSW.js --include manifest.webmanifest
```

`deploy.sh` also re-`cp`s `manifest.webmanifest` with
`--content-type application/manifest+json` so the PWA is installable.

## 3. Invalidate CloudFront

`deploy.sh` invalidates the whole distribution (`--paths "/*"`) per env so the new
`index.html` + hashed assets propagate together (avoids serving a stale shell that points
at just-deleted asset hashes):

```bash
aws cloudfront create-invalidation --distribution-id <CF_ID> --paths "/*" --profile levi
```

## 4. SPA routing fallback (client-side routes)

The app uses client-side routes (`/browse`, `/map`, `/map/:albumId`). A direct hit /
refresh on those must serve `index.html` (HTTP 200):

- **S3 website hosting:** error document = `index.html` (already configured).
- **CloudFront:** custom error responses mapping **403** and **404** → `/index.html`
  with response code **200**. (CloudFront over a private bucket returns 403 for missing
  keys.)

## Verify the deploy

Open the CloudFront HTTPS URL, hard-refresh, and confirm in DevTools → Application →
Service Workers that a new SW activates (it should, given the no-cache shell). Confirm
the catalog renders with no console errors (the auto-seed populated IndexedDB). Then run
the `test`/`debug` skills' verification flow against the live URL if needed.

Note: cover art and index data are user-side IndexedDB — only the app shell + the seed
json ship to S3; there's nothing else to deploy.
