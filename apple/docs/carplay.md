# CarPlay app

A CarPlay audio-app surface for PocketDJ: **Browse → Play → Add-to**, driven from the same
app-scoped stores as the phone (one shared Now Playing).

## What it does

A **tab bar** (`CPTabBarTemplate`) with five tabs:

- **Playlists** — your PocketDJ playlists AND the catalog's Apple Music / source playlists
  (source rows carry a source badge). **Pockets**. Each: tap a collection → its songs with
  **▶ Play all** + **🔀 Shuffle all** on top; tap a song → **Play now** / **Add to pocket-or-playlist**.
- **Albums** and **Artists** — an **A–Z index** (the keyboard-free way to find while driving).
  An artist → their albums (Play all / Shuffle all the whole discography) → an album → its songs.
- **Search** — a category menu (**Songs / Albums / Artists / Playlists**), each opening a scoped
  keyboard search (works parked). A song result plays; album/artist/playlist results drill in. A
  **"Hands-free: ask Siri"** row covers voice while driving ("Play … in PocketDJ" via App Intents).
  Online (OpenSearch) search is deferred — its cold-start is a poor in-car experience.

**Now Playing** (the head-unit card + system Now Playing app) reflects playback started ANYWHERE
(phone or CarPlay) because the engines set `MPNowPlayingInfoCenter.playbackState`. Its **Up Next**
button shows the running queue; tap a row to **Play now / Remove / Play next / Move to end**
("Play now" shifts playback straight to that exact queue row and returns to the Now Playing card).

Everything plays through the same unified sequencer the phone uses (via `IntentServices`), so the
head unit's `CPNowPlayingTemplate` and the phone stay in sync. Playing any playlist/pocket/artist
builds a FRESH snapshot from its current songs (no stored setlist needed; new songs picked up each
play). Plays are recorded to History with the correct source (e.g. "Playlist · <name>", "Artist · <name>").

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

## The entitlement — ALREADY GRANTED ✅

`com.apple.developer.carplay-audio` is required to present CarPlay templates on a head unit.
**The CarPlay Audio App capability is already GRANTED + enabled** on the App ID
(`com.levi.pocketdj`, team EC27UF79GL) — verified in the Developer portal (Identifiers →
com.levi.pocketdj → *CarPlay Audio App (CarPlay framework)* is checked). So there is **no Apple
request to submit** — device/TestFlight builds can sign with CarPlay today.

The entitlement is wired to **both iOS SDKs** (device + simulator) via
`CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]` and `[sdk=iphonesimulator*]` → `PocketDJ-CarPlay.entitlements`.
It's kept out of the **base** `PocketDJ.entitlements` because the base also covers **visionOS**,
which has no CarPlay and would reject the key. macOS keeps its own sandbox entitlements (no CarPlay).

## Get it onto your iPhone (to test in your car)

Because the capability is already granted, this is just **build → install → drive** — no waiting on
Apple.

1. **Build + install on the iPhone** (pick one):
   - **TestFlight** (wireless — easiest for the car): `apple/scripts/testflight.sh` archives +
     uploads (see the `apple-publish` skill); install via the TestFlight app on your phone.
   - **Direct install:** plug in the iPhone → `xcodegen generate` (from `apple/`) → open
     `PocketDJ.xcodeproj` → pick your iPhone as the destination → **Run** (Xcode auto-provisions
     with `-allowProvisioningUpdates`; the profile already includes CarPlay).
2. **In the car:** connect (cable or wireless CarPlay) → **PocketDJ** appears on the CarPlay home →
   Playlists · Pockets · Albums · Search.

### What I can / can't do from here

- ✅ **Portal check** — done: confirmed CarPlay is granted + enabled, and flipped the entitlement on
  for device builds.
- ✅ **Build (simulator) + all the config/entitlement edits** — done.
- ❌ **The signed device build / archive** — the login **keychain is locked** for my non-interactive
  session, so my `xcodebuild` gets to `codesign` and fails with `errSecInternalComponent`. The final
  archive/install is the one step that needs **your** interactive Xcode/Terminal session (step 1).
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
