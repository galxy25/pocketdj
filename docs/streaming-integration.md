# Streaming + song-recognition integration

PocketDJ can play and search music from a linked **Apple Music** subscription and identify a
song playing in the room with **ShazamKit**:

| Source | Capability | Third-party SDK needed? | Account/subscription |
| --- | --- | --- | --- |
| **Apple Music** | search · play · resolve-for-recognition | none (MusicKit ships with iOS) | Apple Music subscription |
| **ShazamKit** ("?♪?" button) | listen + identify the playing song | none (ShazamKit ships with iOS) | none |

> **History:** earlier milestones scaffolded **Spotify** (App Remote SDK) and **YouTube**
> (Data API search + embedded WebView player) streaming providers; both were **removed**.
> Spotify streaming needs the App Remote SDK + a Premium account and only controls the Spotify
> app (no audio buffer for the Mix engine); YouTube added a WebView player + API-key management
> for limited value. Apple Music + the rip server cover streaming. The provider architecture
> below still leaves room to add another backend later (`StreamingProviderKind` / `PlaybackBackend`).

Everything below is **additive and behind feature flags**. The app **compiles and
ships today without any of these configured** — the provider falls back to a
no-op stub that reports "Not available" in Settings, and the "?♪?" button shows a
"not available in this build" message if the ShazamKit framework isn't present. This document
is the checklist of what **you, the developer/operator**, must configure to turn
each one on.

> Team / bundle id used throughout: **`com.levi.pocketdj`**, team **`EC27UF79GL`**.

---

## 0. How the integration is wired (what's already in the repo)

- `apple/PocketDJ/Services/Streaming/` — the `StreamingProvider` seam plus
  `AppleMusicProvider` (real impl behind `#if canImport(MusicKit)`, with a no-op `#else`
  stub), the `StreamingSearch` / `SongRecognizer` seams, and `StreamingTrack` /
  `StreamingError`. `StreamingProviderKind` is `appleMusic`-only.
- `apple/PocketDJ/Services/Shazam/` — the `ShazamRecognizer` state machine
  (`#if canImport(ShazamKit)`) + the pure, unit-tested catalog matcher.
- `apple/PocketDJ/Views/Shazam/` — the **"?♪?"** `ShazamButton` (placed at the TOP
  of the Browser list) + its result sheet.
- `apple/PocketDJ/State/StreamingStore.swift` — owns the provider set
  (`[AppleMusicProvider()]`), routes any OAuth redirect (`.onOpenURL`) and scene-phase
  lifecycle. Injected in `PocketDJApp.swift`.
- `apple/PocketDJ/Playback/` — `TrackPlaybackProvider` + `PlaybackCoordinator`: orders
  **Apple Music first** (for Apple-Music-source songs, when ready) then the **rip server**
  (terminal fallback). `PlaybackBackend` is `ripServer` / `appleMusic`.
- `apple/PocketDJ/Views/SettingsView+Streaming.swift` — the **"Streaming accounts"**
  Settings section: one row per provider with a **Log in / Log out** button, or a
  "Not available" note when its SDK/creds are absent.
- `apple/PocketDJ/PocketDJ.entitlements` — **intentionally empty** (`<dict></dict>`).
  Neither MusicKit nor ShazamKit uses a `.entitlements` key; declaring
  `com.apple.developer.musickit`/`shazamkit` is invalid and breaks device/distribution
  signing. MusicKit is turned on by the **MusicKit App Service** on the App ID plus the
  `NSAppleMusicUsageDescription` string; ShazamKit needs only `NSMicrophoneUsageDescription`.

Feature gating, so the default build is inert:

- **Apple Music** — `#if canImport(MusicKit)` **and** the build-time flag
  `PocketDJAppleMusicEnabled == YES` (set in the **base Info.plist**). Off by default so
  `MusicAuthorization.request()` is never called until you provision MusicKit.
- **ShazamKit** — `#if canImport(ShazamKit)` only; no entitlement.

---

## 1. Info.plist permissions in `apple/project.yml`

The following were added to the `PocketDJ` target. **Active in every build:**

| Key | Where | Why |
| --- | --- | --- |
| `INFOPLIST_KEY_NSMicrophoneUsageDescription` | `settings.base` | Mic prompt for the "?♪?" ShazamKit listen. Prompt only fires when you tap the button (ShazamKit needs no entitlement). |
| `INFOPLIST_KEY_NSAppleMusicUsageDescription` | `settings.base` | Apple Music prompt for MusicKit. Prompt only fires when Apple Music is enabled **and** the user taps Connect. |
| `PocketDJAppleMusicEnabled` | **base Info.plist** (`info:` `properties:` block, beside `UIBackgroundModes`) | Opt-in flag that wakes `AppleMusicProvider`. **Must** be a real Info.plist key — `INFOPLIST_KEY_PocketDJAppleMusicEnabled` silently no-ops because `INFOPLIST_KEY_*` only injects Apple's *known* keys, not custom ones. |

> `apple/PocketDJ/PocketDJ.entitlements` is **empty** (`<dict></dict>`). MusicKit and
> ShazamKit do **not** use a `.entitlements` key; MusicKit is enabled by the **App Service**
> on the App ID (§2) + `NSAppleMusicUsageDescription`, ShazamKit by the framework +
> `NSMicrophoneUsageDescription` alone. Declaring `com.apple.developer.musickit`/`shazamkit`
> there is invalid and breaks device/distribution signing.

After editing `project.yml`, always re-run:

```sh
cd apple && xcodegen generate
```

---

## 2. Apple Developer portal — App ID capabilities (MusicKit only)

The **MusicKit App Service** is a manual portal toggle; `-allowProvisioningUpdates`
cannot self-provision App Services. **ShazamKit needs no App Service and no
entitlement** for the public Shazam catalog — skip it.

1. **developer.apple.com → Certificates, IDs & Profiles → Identifiers →
   `com.levi.pocketdj`.**
2. Under **App Services**, enable:
   - **MusicKit** — turn on the MusicKit App Service for the bundle id. This is what
     enables MusicKit; there is **no `.entitlements` key** for it. (No key file is
     downloaded for the on-device flow — the developer token is minted automatically
     by the OS. A MusicKit *private key* `.p8` is only needed for a **server**-side
     Apple Music API; the in-app provider here does not.)
   - **ShazamKit** — *not required.* The **public** Shazam catalog (what the "?♪?"
     button uses) needs no App Service, no entitlement, and no developer token; only a
     *custom* catalog would.
3. Regenerate / let Xcode refresh the **provisioning profile** so it carries the
   MusicKit service. (The entitlements file stays empty — the App Service, not an
   entitlement key, is what the profile must match.)

**Checklist**

- [ ] MusicKit App Service enabled on `com.levi.pocketdj`.
- [ ] Provisioning profile regenerated.
- [ ] `PocketDJAppleMusicEnabled: YES` present in the **base Info.plist** (`info:`
      `properties:` block in `project.yml`), then `xcodegen generate`.

> **Simulator note:** entitlements are NOT enforced on the Simulator. The default
> CI build (`CODE_SIGNING_ALLOWED=NO`) builds + runs without any of this. You only
> need the portal steps to run on a **device** or **ship**.

### Apple Music login flow (how it works)
- Tap **Connect** on the Apple Music row → `MusicAuthorization.request()` shows the
  **system consent sheet** (no web view, no redirect).
- On `.authorized`, the provider checks `MusicSubscription.current` and surfaces
  whether the account can play catalog content. Playback is in-process via
  `ApplicationMusicPlayer.shared`; search is `MusicCatalogSearchRequest`.
- The Shazam bridge: when a recognized song isn't in your crate but Shazam
  returns an `appleMusicID`, a linked Apple Music account can resolve + play it
  (`SongRecognizer.resolve`).

---

## 3. ShazamKit — the "?♪?" button

- **No entitlement, no App Service:** the public Shazam catalog needs neither — the
  framework ships with the OS and the recognizer is gated only on
  `#if canImport(ShazamKit)`.
- **Mic permission:** `NSMicrophoneUsageDescription` (already injected). The
  recognizer requests mic access itself and renders a clean **denied** state
  (shake + `mic.slash`) that links to Settings.
- **No credentials / no token** for the **public** Shazam catalog.
- **Where:** the button lives at the **top of the Browser list**. Tap → listen
  (`SHManagedSession`) → match against your in-memory catalog (normalized
  title+artist) → result sheet deep-links into the song if it's in your crate, or
  shows the recognized metadata (and notes a linked Apple Music account could play
  it) if not.
- **Without the framework:** the button compiles and shows
  "Recognition isn't available in this build." — no crash.

**Checklist**

- [ ] (Automatic) mic usage string present — already in `project.yml`. Nothing to
      enable in the portal: no ShazamKit entitlement or App Service is needed for the
      public catalog.

---

## 4. Build / test (verifies the default, un-provisioned build)

```sh
cd apple && xcodegen generate
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme PocketDJ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build-streaming CODE_SIGNING_ALLOWED=NO build
xcodebuild test -scheme PocketDJ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build-streaming CODE_SIGNING_ALLOWED=NO \
  -only-testing:PocketDJTests
```

Both succeed with **no** SDKs/credentials/App Services provisioned (the entitlements
file is empty) — the streaming + recognition modules are entirely behind
`#if canImport`, `@available`, and the Info.plist feature flags.

---

## TL;DR — what YOU must configure

- **Apple Music:** portal → enable the **MusicKit App Service** on `com.levi.pocketdj`
  (no entitlement); set `PocketDJAppleMusicEnabled = YES` in the **base Info.plist**.
  Needs an Apple Music subscription to play.
- **ShazamKit:** nothing to provision — no entitlement, no App Service for the public
  catalog. Mic string is already wired.
