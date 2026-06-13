---
name: publish-s3
description: Publish/deploy the PocketDJ PWA to AWS S3 (static hosting, optionally behind CloudFront). Use when asked to "publish the app", "deploy to s3", or "ship pocketdj". Covers building, syncing dist/, the critical service-worker cache-header tiers, and SPA-routing fallback. Manual deploy — no AWS creds are wired in the repo.
---

# Publish PocketDJ to S3

PocketDJ is an offline-first PWA. Deploy is: build, then sync `dist/` to a bucket.
The repo has **no AWS credentials wired in** — this is a documented manual deploy.
You need `aws` CLI configured (`aws configure` / a profile) and a target bucket.

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
