# CarPlay app

A CarPlay audio-app surface for PocketDJ: **Browse → Play → Add-to**, driven from the same
app-scoped stores as the phone (one shared Now Playing).

## What it does

A **tab bar** (`CPTabBarTemplate`) with four tabs:

- **Playlists / Pockets / Albums** — each a `CPListTemplate`; tap a collection to drill into its
  songs (a **▶ Play all** row on top). Tap a song → an action sheet: **Play now** / **Add to
  pocket-or-playlist**.
- **Search** — a `CPSearchTemplate` over **title + artist** only (no advanced filter/sort — that
  stays in the full app / History mode).

Everything plays through the same unified sequencer the phone uses (via `IntentServices`), so the
head unit's `CPNowPlayingTemplate` and the phone stay in sync. Plays are recorded to History with
the correct source (a CarPlay playlist play shows as "Playlist · <name>").

## Architecture

- **`PocketDJ/CarPlay/CarPlayModel.swift`** — the template-agnostic core: turns the shared stores
  into row lists (browse/songs/search) and routes the two writes (play, add-to). No `CarPlay`
  import, so it unit-tests on the plain host (`CarPlayModelTests`) and compiles on every platform.
- **`PocketDJ/CarPlay/CarPlayScene.swift`** (`#if os(iOS)`) — `CarPlaySceneDelegate`
  (`CPTemplateApplicationSceneDelegate`) + `CarPlayController`, a thin adapter that maps
  `CarPlayModel.Row`s to `CPListItem`/`CPListTemplate`, fetches artwork (→ `UIImage`), and drives
  the action sheet / search / Now Playing.
- The CarPlay scene runs OUTSIDE the SwiftUI environment, so it reaches the shared stores through
  **`IntentServices.shared`** (set once in `PocketDJApp.init`), NOT its own — same escape hatch as
  `TransferCoordinator.shared`. It must never construct stores (that forks a second catalog graph).

## Scene wiring (project.yml)

- An **explicit** `UIApplicationSceneManifest` (in `targets.PocketDJ.info.properties`) declares
  ONLY the CarPlay scene role (`CPTemplateApplicationSceneSessionRoleApplication` →
  `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`) with `UIApplicationSupportsMultipleScenes: true`.
  We do **not** declare the window role — SwiftUI's `WindowGroup` still provides the phone window
  (verified: the phone app launches unchanged). Scene-manifest **generation is turned OFF**
  (`INFOPLIST_KEY_UIApplicationSceneManifest_Generation: NO`) so the two don't collide.

## The entitlement (action required to ship to a real car)

`com.apple.developer.carplay-audio` is required for the app to present CarPlay templates on a head
unit. **Apple must grant the CarPlay App Service on the App ID** (`com.levi.pocketdj`, team
EC27UF79GL) before a **device/TestFlight** build can sign with it — an ungranted entitlement breaks
signing ("not found and could not be included in profile").

So today it is **scoped to the simulator SDK only**
(`CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*] = PocketDJ-CarPlay.entitlements`); iOS device /
TestFlight builds keep the empty base `PocketDJ.entitlements` and **sign green**.

**To ship to a real car:**
1. Request the CarPlay entitlement from Apple: <https://developer.apple.com/contact/carplay/>
   (choose the **audio** app category).
2. Once granted, enable the CarPlay capability on the App ID in the Developer portal.
3. Move the `com.apple.developer.carplay-audio` key from `PocketDJ-CarPlay.entitlements` into the
   base `PocketDJ.entitlements` (and drop the simulator-only override in `project.yml`).

## Get it onto your iPhone (to test in your car)

> **The gate:** CarPlay only appears on a **real head unit** once Apple has **granted** the
> `com.apple.developer.carplay-audio` entitlement (step 1). You can install the app on your iPhone
> before then, but the CarPlay screen won't show in the car until the grant *and* a build that
> embeds the entitlement. (The **CarPlay Simulator** works today with no grant — see below.)

1. **Request the entitlement** (one-time; Apple grants it in ~days, not instant):
   <https://developer.apple.com/contact/carplay/> → choose **Audio**. Use the bundle id
   `com.levi.pocketdj`.
2. **After Apple grants it:**
   - In **Certificates, Identifiers & Profiles → Identifiers → `com.levi.pocketdj`**, enable the
     **CarPlay** capability and save (regenerates provisioning).
   - Move the `com.apple.developer.carplay-audio` key from `PocketDJ-CarPlay.entitlements` into the
     base `PocketDJ.entitlements`, and delete the `[sdk=iphonesimulator*]` override in `project.yml`
     (I can do this edit for you in one commit once you confirm the grant).
3. **Build + install on the iPhone** (pick one):
   - **TestFlight** (wireless — easiest for the car): `apple/scripts/testflight.sh` archives +
     uploads (see the `apple-publish` skill); install via the TestFlight app on your phone.
   - **Direct install:** plug in the iPhone → `xcodegen generate` → open `PocketDJ.xcodeproj` →
     pick your iPhone as the destination → **Run** (Xcode auto-provisions with
     `-allowProvisioningUpdates`).
4. **In the car:** connect (cable or wireless CarPlay) → **PocketDJ** appears on the CarPlay home.

### What I can / can't automate here

- ✅ **Build / archive** (`xcodebuild`) and the entitlement/plist edits in step 2 — I can do these.
- ⚠️ **Device signing** needs the CarPlay entitlement **provisioned on the App ID**, which doesn't
  exist until Apple grants it — so a device/TestFlight build with CarPlay **can't sign** until then.
  (That's exactly why the entitlement is simulator-gated today.)
- ❌ **Enabling CarPlay is not self-serve** — it's a **manual request** Apple reviews (step 1), not a
  checkbox I can toggle in the portal.
- 🔐 The Apple Developer portal / the request form are **logged into your Apple ID** (2FA). I can
  drive them with browser automation to **fill the CarPlay request form** or **check whether the
  App ID already has CarPlay enabled**, but that acts on your account — I'll only do it if you say
  go, and you may need to clear a 2FA prompt.

### ⚠️ Gotcha: automatic signing rewrites the entitlements files

A device build with **automatic signing** (Xcode, or `xcodebuild -allowProvisioningUpdates`) will
**rewrite the `.entitlements` files** as a side effect — reformatting them and injecting
capabilities it thinks are needed. In particular it may add `com.apple.developer.carplay-audio` to
`PocketDJ-macOS.entitlements` (wrong — macOS has no CarPlay). If a build dirties them, just
`git checkout apple/PocketDJ/PocketDJ*.entitlements` to restore the intended files. The
canonical state: base `PocketDJ.entitlements` **empty**, macOS file = sandbox keys only, CarPlay
key lives ONLY in `PocketDJ-CarPlay.entitlements` until Apple grants the capability.

## Verifying in the CarPlay Simulator (manual — can't be driven headlessly)

The CarPlay UI is a separate external display, so it can't be screenshotted via `simctl`. To verify:

1. `xcodegen generate` (from `apple/`), open `PocketDJ.xcodeproj`, run PocketDJ on an iOS simulator.
2. In **Simulator.app** → menu **I/O ▸ External Displays ▸ CarPlay**.
3. The CarPlay home screen opens; tap **PocketDJ**. You should see the Playlists · Pockets · Albums
   · Search tabs; drill into a collection, Play all, tap a song → Play now / Add to….

The template-agnostic logic (list building, play routing, add-to, search) is covered by
`CarPlayModelTests` in the always-run unit bundle, so regressions there are caught without the sim.
