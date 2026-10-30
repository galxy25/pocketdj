# pocket-dj.com (marketing site)

Static site served at https://pocket-dj.com and https://www.pocket-dj.com from the
`PDJ_WWW_BUCKET` S3 bucket behind the `PDJ_CF_WWW` CloudFront distribution
in the **green** account 623170744161 (profile `llc`). Cut over 2026-10-13; blue's www
distribution no longer carries the hostnames. Deploy to GREEN ONLY.

- `index.html` — landing page + feature tour
- `support.html` — support page (App Store "Support URL")
- `icon.png`, `img/` — app icon, App Store badge, screenshots (pulled from the App Store Connect
  screenshot sets, resized to 600 px / 1200 px WebP); Android shots in `img/android/` (emulator
  captures, 600×1333 WebP, loaded only once a visitor picks the Android tab); `google-play-badge.png`
  is Google's official badge, unaltered
- `/android/` on S3 (NOT in git, never synced from here): the sideload APKs, `PocketDJ.apk` (stable
  latest) and `latest.json`. Publish with `android/scripts/publish-apk.sh [release-out dir]` after
  `android/scripts/release-aab.sh`.

Google Play badge: one flag, `data-play` on `<html>` in `index.html`. `review` shows the badge unlinked
with "Coming soon · in review"; flip it to `live` once the listing is public. Screenshot platform:
`data-platform` (Apple by default; Android is remembered per viewer in `localStorage['pdj.www.platform']`
and can be forced with `?platform=android`).

Preview locally: `python3 -m http.server 8765 --directory www`

## Deploy (not automated; run by hand)

```bash
POCKETDJ_ENV=green source scripts/lib/aws-env.sh   # green only — the site lives there now
aws s3 sync www "s3://$PDJ_WWW_BUCKET" --profile "$PDJ_PROFILE" \
  --exclude README.md --exclude '.*' --exclude 'android/*' \
  --cache-control 'public, max-age=300'
aws cloudfront create-invalidation --profile "$PDJ_PROFILE" \
  --distribution-id "$PDJ_CF_WWW" --paths '/*'
```

`aws s3 sync` infers Content-Type from the extension (`.webp` → `image/webp`, `.svg` →
`image/svg+xml`). Green: bucket `pocketdj-www-623170744161`, CloudFront `ELX7JB4JIT29F`
(d3cxthv1ih70b5.cloudfront.net). Never deploy the site to blue.
