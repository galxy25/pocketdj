---
name: publish-s3
description: Publish/deploy the PocketDJ PWA to AWS S3 static hosting (dev or prod). Use when asked to "publish the app", "deploy to s3", "ship pocketdj", "deploy dev/prod". One command (scripts/deploy.sh) builds + syncs dist/ with the right cache tiers; this doc explains the details + SPA fallback.
---

# Publish PocketDJ to S3

PocketDJ is an offline-first PWA. Deploy = build, then sync `dist/` to a bucket.

## Quick deploy (this repo)

Infra is already set up: AWS profile **`levi`** (account `011183829623`, region
**us-west-2**), two public static-website buckets, and `scripts/deploy.sh`.

```bash
scripts/deploy.sh dev      # -> http://pocketdj-dev-web-011183829623.s3-website-us-west-2.amazonaws.com
scripts/deploy.sh prod     # -> http://pocketdj-prod-web-011183829623.s3-website-us-west-2.amazonaws.com
SKIP_BUILD=1 scripts/deploy.sh dev   # reuse existing dist/
```

`deploy.sh` builds (generating demo data if missing), then does the two-tier
cache sync below. **A background agent can run it** — it just shells out to
`aws --profile levi`. Override with `AWS_PROFILE_OVERRIDE` / `AWS_REGION_OVERRIDE`.

To (re)provision a bucket from scratch (new account/region), see the
create-bucket + website + public-policy steps in §4 and the project setup notes.

The rest of this doc explains what `deploy.sh` does and why, plus the manual path.

## 1. Build

```bash
npm run build      # tsc -b && vite build  ->  dist/
```

`dist/` contains: `index.html`, hashed `assets/*`, `sw.js`, `workbox-*.js`,
`registerSW.js`, `manifest.webmanifest`, static svgs, and the demo data json.

## 1. Build

```bash
npm run build      # tsc -b && vite build  ->  dist/
```

`dist/` contains: `index.html`, hashed `assets/*`, `sw.js`, `workbox-*.js`,
`registerSW.js`, `manifest.webmanifest`, and static svgs.

## 2. Sync to the bucket

Replace `<bucket>` throughout.

```bash
aws s3 sync dist/ s3://<bucket> --delete
```

`--delete` removes files that no longer exist in `dist/` (cleans up old hashed
assets). This is fine because the SW precache references current hashes.

## 3. Cache headers — the critical part (auto-updating SW)

The SW uses `registerType: 'autoUpdate'`. Users only get a new deploy if the
browser can fetch a **fresh** `sw.js` / `registerSW.js` / `index.html` /
`manifest.webmanifest`. If those are long-cached, users get stuck on a stale
service worker forever. Two tiers:

**Tier A — hashed assets: long-cache, immutable.** Filenames change on every
build, so they can cache for a year:

```bash
aws s3 cp dist/assets s3://<bucket>/assets --recursive \
  --cache-control "public, max-age=31536000, immutable"
```

**Tier B — SW + shell entry points: SHORT / no-cache.** These keep the same names
across deploys, so they must revalidate:

```bash
aws s3 cp dist/index.html          s3://<bucket>/index.html          --cache-control "no-cache"
aws s3 cp dist/sw.js               s3://<bucket>/sw.js               --cache-control "no-cache"
aws s3 cp dist/registerSW.js       s3://<bucket>/registerSW.js       --cache-control "no-cache"
aws s3 cp dist/manifest.webmanifest s3://<bucket>/manifest.webmanifest --cache-control "no-cache"
```

Recommended order: `sync` everything first, then re-`cp` the Tier-A assets with
the immutable header and the Tier-B files with `no-cache` to overwrite the
defaults. (`no-cache` = must revalidate each time, not "never store".)

If serving via CloudFront, also invalidate the Tier-B paths after deploy:

```bash
aws cloudfront create-invalidation --distribution-id <dist-id> \
  --paths /index.html /sw.js /registerSW.js /manifest.webmanifest
```

## 4. SPA routing fallback (client-side routes)

The app uses client-side routes: `/browse`, `/map`, `/map/:albumId`. A direct
hit / refresh on those paths must serve `index.html` (HTTP 200), or users get a
403/404.

- **S3 static website hosting:** set the website **error document** to
  `index.html` (index document also `index.html`):

  ```bash
  aws s3 website s3://<bucket> --index-document index.html --error-document index.html
  ```

- **CloudFront (recommended for HTTPS):** add custom error responses mapping
  **403** and **404** to `/index.html` with response code **200**. (CloudFront in
  front of a private bucket via OAC typically returns 403 for missing keys.)

## Verify the deploy

Load the site, hard-refresh, and confirm in DevTools - Application - Service
Workers that a new SW activates after a deploy (it should, given the no-cache
headers). Then run the `test`/`debug` skills' verification flow against the live
URL if needed. Note: cover art and index data are user-side IndexedDB — nothing
to deploy there; only the app shell ships to S3.
