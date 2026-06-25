---
name: apple-publish
description: Publish the native PocketDJ iOS app to TestFlight from the command line (local archive → distribution-sign → upload to App Store Connect). Use when asked to "publish to testflight", "ship a testflight build", "upload to testflight", "make a testflight build", "release a beta", or to get a new build onto iPhone/iPad over the air. Sibling of apple-build (which produces local/simulator builds); this one does App Store Connect distribution.
---

# Publish PocketDJ to TestFlight (iOS)

This is the **local-archive** path — build on this Mac, then push the signed `.ipa`
straight to App Store Connect. **No Xcode Cloud.** (Xcode Cloud's "Grant Access to
Your Source Code" dialog wants to clone every dependency repo incl. the public
`weichsel/ZIPFoundation` you can't admin — skip it entirely; nothing here needs it.)

One command does everything:

```bash
cd apple
ASC_KEY_ID=C2G2V625FZ ASC_ISSUER_ID=69a6de86-a921-47e3-e053-5b8c7c11a4d1 \
  ./scripts/testflight.sh
```

`scripts/testflight.sh` runs: `xcodegen generate` → `xcodebuild archive` (Release,
iOS, distribution-signed via cloud signing) → `xcodebuild -exportArchive` with
`destination=upload` to deliver to App Store Connect using the API key. Build number
defaults to a unix timestamp (`CURRENT_PROJECT_VERSION`), so uploads never collide.

## Prerequisites (one-time)

1. **Full Xcode**, not just Command Line Tools. The script checks `xcodebuild -version`
   and errors with the fix if it's pointing at CLT:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   # (or per-shell: export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer)
   ```
2. **App Store Connect App record** — Apps → ＋ → New App, bundle id `com.levi.pocketdj`.
   App ID `6784031333`, name "Pocket DJ - Rip, Burn, Mix".
3. **MusicKit App Service** enabled on the App ID `com.levi.pocketdj` (developer.apple.com →
   Identifiers). Without it Apple Music is dead in the TestFlight build even though it signs.
4. **App Store Connect API key — role MUST be `Admin`.** Cloud signing (minting the
   Apple Distribution cert + App Store profile during export) FAILS with an `App Manager`
   key: `error: exportArchive Cloud signing permission error / No profiles for
   'com.levi.pocketdj' were found`. Create the key under **Users and Access →
   Integrations → App Store Connect API → ＋** (Access: **Admin**), download the
   `AuthKey_<KEYID>.p8` ONCE, and place it at:
   ```
   ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
   ```
   Current key: **Key ID `C2G2V625FZ`** (PocketDJ CI Admin), **Issuer ID
   `69a6de86-a921-47e3-e053-5b8c7c11a4d1`**. The `.p8` is a private key — never commit it
   or paste its contents anywhere; only the Key ID / Issuer ID are non-secret.

To avoid typing the env vars each time, put them in `~/.config/fish/config.fish`:
```fish
set -gx ASC_KEY_ID     C2G2V625FZ
set -gx ASC_ISSUER_ID  69a6de86-a921-47e3-e053-5b8c7c11a4d1
```
then just run `apple/scripts/testflight.sh`.

## After upload

- Build processes server-side (~5–15 min); you get an email when it's ready.
- **Export compliance is pre-answered.** `project.yml` sets
  `ITSAppUsesNonExemptEncryption: false` in the base Info.plist, so builds land as
  **"Ready to Submit"** with no per-build encryption question. (PocketDJ uses only
  exempt HTTPS/TLS encryption.)
- **Auto-distribution to the "Alphas" internal group is automatic.** The Alphas group
  (Internal Testing) has **Build Distribution = "Automatic for Xcode Builds"**, and the
  script uploads via Xcode — so every new build is shared with Alphas with no extra step.
  Testers install/update over the air via the TestFlight app (no cable). To add testers:
  TestFlight → Internal Testing → Alphas → Testers → ＋.

## Versioning

- **Build number** auto-increments (unix timestamp) — fine for iterating within a version.
- **Marketing version** is `MARKETING_VERSION` in `project.yml` (currently `0.1.0`). Bump
  it when you want a new user-facing version (e.g. `0.1.0` → `0.2.0`), then run the script.

## Troubleshooting

- **`Cloud signing permission error` / `No profiles for 'com.levi.pocketdj'`** → the API
  key isn't `Admin`. Recreate it with the Admin role (see prereq 4).
- **`accessing build database ...build.db: disk I/O error` / `*.dependency-scan.dia` /
  `PocketDJ-dependencies-1.json doesn't exist`** → corrupt DerivedData (often from an
  interrupted prior archive). Clear it and retry:
  ```bash
  rm -rf ~/Library/Developer/Xcode/DerivedData/PocketDJ-*
  ```
- **`method` value rejected by `-exportArchive`** → Xcode 26 wants `app-store-connect`
  (already used). On older Xcode change it to `app-store` in the script's ExportOptions heredoc.
- **Exit 0 but it actually failed** → don't pipe the script through `tail` (that masks the
  real exit code). Run it directly; `set -euo pipefail` then surfaces failures.
- **Archive `CodeSign failed … missing Xcode-Username`** → the ARCHIVE step had no API key, so
  `-allowProvisioningUpdates` looked for an Apple ID signed into Xcode (none, headless). FIXED:
  the script now passes `-authenticationKey{Path,ID,IssuerID}` to the archive too (cloud signing).
- **Archive `CodeSign failed … errSecInternalComponent` (ONE-TIME keychain bootstrap)** → two
  things only an interactive session can establish: (a) there is NO **Apple Distribution** cert
  in the keychain (only Apple Development — App Store needs Distribution), and (b) `codesign`
  can't reach the signing key's private key headlessly. BOTH are solved by **one Xcode.app
  archive**: open `apple/PocketDJ.xcodeproj`, ensure the Apple ID is in Xcode ▸ Settings ▸
  Accounts (team EC27UF79GL), pick **Any iOS Device**, **Product ▸ Archive**; click **Always
  Allow** on each keychain prompt. That mints the Distribution cert + grants permanent CLI key
  access — and you can **Distribute ▸ App Store Connect** right there to ship that build. After
  that one GUI archive, `testflight.sh` runs fully headless for every future build.

## Related

- **apple-build** skill — local/simulator/Mac builds (no distribution).
- **apple-test** skill — unit + XCUITests per device.
- `apple/scripts/testflight.sh` — the pipeline itself.
