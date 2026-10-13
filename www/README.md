# pocket-dj.com (marketing site)

Static site served at https://pocket-dj.com and https://www.pocket-dj.com from the
`PDJ_WWW_BUCKET` S3 bucket behind the `PDJ_CF_WWW` CloudFront distribution
(see `scripts/lib/aws-env.sh`; `POCKETDJ_ENV=blue` is the default, `green` is the llc account).

- `index.html` — landing page + feature tour
- `support.html` — support page (App Store "Support URL")
- `icon.png`, `img/` — app icon, App Store badge, screenshots (pulled from the App Store Connect
  screenshot sets, resized to 600 px / 1200 px WebP)

Preview locally: `python3 -m http.server 8765 --directory www`

## Deploy (not automated; run by hand)

```bash
source scripts/lib/aws-env.sh            # POCKETDJ_ENV=green source ... for the llc account
aws s3 sync www "s3://$PDJ_WWW_BUCKET" --profile "$PDJ_PROFILE" \
  --exclude README.md --exclude '.*' \
  --cache-control 'public, max-age=300'
aws cloudfront create-invalidation --profile "$PDJ_PROFILE" \
  --distribution-id "$PDJ_CF_WWW" --paths '/*'
```

`aws s3 sync` infers Content-Type from the extension (`.webp` → `image/webp`, `.svg` →
`image/svg+xml`). Deploy to whichever account currently serves DNS (blue `011183829623`:
bucket `pocketdj-www-011183829623`, CF `E9L9V188S55F7`; green `623170744161`: bucket
`pocketdj-www-623170744161`, CF `ELX7JB4JIT29F`), or both while the migration mirrors them.
