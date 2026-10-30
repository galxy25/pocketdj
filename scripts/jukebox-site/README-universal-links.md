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
. scripts/lib/aws-env.sh   # POCKETDJ_ENV=blue (default: account 011183829623, profile levi) | green
aws s3 cp scripts/jukebox-site/apple-app-site-association \
  s3://$PDJ_DEV_WEB_BUCKET/jukebox/.well-known/apple-app-site-association \
  --profile "$PDJ_PROFILE" --content-type application/json --cache-control "max-age=300" --only-show-errors
aws cloudfront create-invalidation --distribution-id "$PDJ_CF_DEV" \
  --paths '/.well-known/apple-app-site-association' --profile "$PDJ_PROFILE"
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

## Android App Links (`assetlinks.json`)

`.well-known/assetlinks.json` (this dir) is served at
`https://jukebox.pocket-dj.com/.well-known/assetlinks.json` (200, `application/json`, no redirect) and lets
the Android app's `autoVerify` intent filter (`jukebox.pocket-dj.com`) open `https://` jukebox links directly.
It must list EVERY signing cert users can install: debug (filled in), the direct-signing release key
(`keytool -list -v -keystore <release.jks>`), and the Play App Signing cert (Play Console -> App integrity).
Replace the two `REPLACE_WITH_*` entries, then publish both well-known files in one step:

```bash
scripts/publish-jukebox-wellknown.sh      # uploads AASA + assetlinks, invalidates CloudFront, curls both
adb shell pm verify-app-links --re-verify com.levi.pocketdj
adb shell pm get-app-links com.levi.pocketdj    # jukebox.pocket-dj.com: verified
```
(The `.well-known/apple-app-site-association` here is a copy of the root file, kept in sync for the script.)
