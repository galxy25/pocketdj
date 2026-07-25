# Jukebox join — Universal Links enablement (manual, one-time)

The app supports joining an in-progress jukebox from a shared link two ways (Levi 2026-07-25):

1. **Custom scheme `pocketdj://jukebox/<id>`** — works TODAY, no setup. The web guest page's
   "Open in the PocketDJ app" banner uses it, and the app parses it via `JukeboxLink`.
2. **Universal Link `https://jukebox.pocket-dj.com/<id>/`** — the nicer UX (the https link the user
   already has opens the app if installed). Needs the two one-time steps below; until then the app
   still joins via the custom scheme, so the feature is fully functional without this.

## Step 1 — enable Associated Domains on the App ID (developer portal, Levi)

developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → `com.levi.pocketdj`
→ enable the **Associated Domains** capability → Save. (Automatic signing then updates the
provisioning profile on the next archive.)

## Step 2 — host the apple-app-site-association file on the jukebox domain

`apple-app-site-association` (this dir) must be served, with `Content-Type: application/json` and
NO redirect, at:

    https://jukebox.pocket-dj.com/.well-known/apple-app-site-association

The jukebox domain is CloudFront over the `pocketdj-dev-web-<acct>` bucket with origin path
`/jukebox`, so the public `/.well-known/...` path maps to the S3 key `jukebox/.well-known/...`:

```bash
ACCT=011183829623
aws s3 cp scripts/jukebox-site/apple-app-site-association \
  s3://pocketdj-dev-web-$ACCT/jukebox/.well-known/apple-app-site-association \
  --profile levi --content-type application/json --cache-control "max-age=300" --only-show-errors
aws cloudfront create-invalidation --distribution-id E123GKAO9JVETP \
  --paths '/.well-known/apple-app-site-association' --profile levi
```

## Step 3 — add the entitlement + re-ship

Once Step 1 is done (so signing won't fail), add to each app entitlements file
(`apple/PocketDJ/PocketDJ.entitlements`, `PocketDJ-CarPlay.entitlements` for iOS,
`PocketDJ-macOS.entitlements`) :

```xml
<key>com.apple.developer.associated-domains</key>
<array>
  <string>applinks:jukebox.pocket-dj.com</string>
</array>
```

then `apple/scripts/testflight*.sh`. Verify: tapping `https://jukebox.pocket-dj.com/<id>/` on a
device with the app installed opens the app to the join sheet (not Safari).
