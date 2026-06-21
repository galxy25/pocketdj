# Streaming + song-recognition integration

PocketDJ can play and search music from **three** streaming services and identify a
song playing in the room with **ShazamKit**:

| Source | Capability | Third-party SDK needed? | Account/subscription |
| --- | --- | --- | --- |
| **Apple Music** | search · play · resolve-for-recognition | none (MusicKit ships with iOS) | Apple Music subscription |
| **Spotify** | account-link · play (App Remote) | Spotify iOS SDK (`SpotifyiOS`) | Spotify **Premium** |
| **YouTube** | search (Data API) · embedded playback | player needs `youtube-ios-player-helper`; search needs none | none (free) |
| **ShazamKit** ("?♪?" button) | listen + identify the playing song | none (ShazamKit ships with iOS) | none |

Everything below is **additive and behind feature flags**. The app **compiles and
ships today without any of these configured** — every provider falls back to a
no-op stub that reports "Not available" in Settings, and the "?♪?" button shows a
"not available in this build" message if ShazamKit isn't entitled. This document
is the checklist of what **you, the developer/operator**, must configure to turn
each one on.

> Team / bundle id used throughout: **`net.pocketdj.app`**, team **`EC27UF79GL`**.

---

## 0. How the integration is wired (what's already in the repo)

These modules were added on the `native-streaming` branch:

- `apple/PocketDJ/Services/Streaming/` — the `StreamingProvider` seam plus
  `AppleMusicProvider`, `SpotifyProvider`, `YouTubeProvider` (each real impl behind
  `#if canImport(...)`, with a no-op `#else` stub), the `StreamingSearch` /
  `SongRecognizer` seams, the YouTube Data-API search client, and the embedded
  player view.
- `apple/PocketDJ/Services/Shazam/` — the `ShazamRecognizer` state machine
  (`#if canImport(ShazamKit)`) + the pure, unit-tested catalog matcher.
- `apple/PocketDJ/Views/Shazam/` — the **"?♪?"** `ShazamButton` (placed at the TOP
  of the Browser list) + its result sheet.
- `apple/PocketDJ/State/StreamingStore.swift` — owns the provider set, routes
  OAuth redirects (`.onOpenURL`) and scene-phase lifecycle. Injected in
  `PocketDJApp.swift`.
- `apple/PocketDJ/Views/SettingsView+Streaming.swift` — the **"Streaming accounts"**
  Settings section: one row per provider with a **Log in / Log out** button, or a
  "Not available" note when its SDK/creds are absent.
- `apple/PocketDJ/PocketDJ.entitlements` — carries the MusicKit + ShazamKit
  entitlements (wired via `CODE_SIGN_ENTITLEMENTS` in `project.yml`).

Feature gating, so the default build is inert:

- **Spotify** — `#if canImport(SpotifyiOS)`; `SpotifyCredentials.isConfigured`
  (Info.plist `SpotifyClientID` + `SpotifyRedirectURL` non-empty).
- **YouTube** — search gated on `YouTubeCredentials.canSearch` (Info.plist
  `YouTubeAPIKey`); account-link on `canLink` (also `YouTubeOAuthClientID`).
  Embedded playback gated on `#if canImport(YouTubeiOSPlayerHelper)`.
- **Apple Music** — `#if canImport(MusicKit)` **and** the build-time flag
  `PocketDJAppleMusicEnabled == YES` (Info.plist). Off by default so
  `MusicAuthorization.request()` is never called until you provision MusicKit.
- **ShazamKit** — `#if canImport(ShazamKit)`; entitlement only enforced when
  signing for a device.

---

## 1. Info.plist permissions + entitlements added in `apple/project.yml`

The following were added to the `PocketDJ` target. **Active in every build:**

| Key | Where | Why |
| --- | --- | --- |
| `INFOPLIST_KEY_NSMicrophoneUsageDescription` | `settings.base` | Mic prompt for the "?♪?" ShazamKit listen. Prompt only fires when you tap the button with ShazamKit entitled. |
| `INFOPLIST_KEY_NSAppleMusicUsageDescription` | `settings.base` | Apple Music prompt for MusicKit. Prompt only fires when Apple Music is enabled **and** the user taps Connect. |
| `CODE_SIGN_ENTITLEMENTS: PocketDJ/PocketDJ.entitlements` | `settings.base` | Points the target at the entitlements file carrying `com.apple.developer.musickit` + `com.apple.developer.shazamkit`. Enforced only when signing for device/distribution. |

**Commented placeholders** (activate per the steps below):

- `INFOPLIST_KEY_PocketDJAppleMusicEnabled: "YES"` — flip on **after** enabling
  MusicKit on the App ID to wake `AppleMusicProvider`.
- A `CFBundleURLTypes` / `LSApplicationQueriesSchemes` block — the Spotify +
  YouTube **OAuth redirect schemes**. These are *arrays*, so they cannot be
  injected as scalar `INFOPLIST_KEY_*` values; the placeholder block in
  `project.yml` shows exactly what to paste once you switch to an explicit
  `Info.plist` (comment out `GENERATE_INFOPLIST_FILE`, uncomment the `info:` block).

After editing `project.yml`, always re-run:

```sh
cd apple && xcodegen generate
```

---

## 2. Apple Developer portal — App ID capabilities (MusicKit + ShazamKit)

Both are manual portal toggles; `-allowProvisioningUpdates` cannot self-provision
App Services.

1. **developer.apple.com → Certificates, IDs & Profiles → Identifiers →
   `net.pocketdj.app`.**
2. Under **App Services / Capabilities**, enable:
   - **MusicKit** — register the app's bundle id as a MusicKit app service.
     (No key file is downloaded for the on-device MusicKit flow — the developer
     token is minted automatically by the OS for an entitled app. A MusicKit
     *private key* `.p8` is only needed if you build a **server**-side Apple Music
     API; the in-app provider here does not.)
   - **ShazamKit** — enable the ShazamKit app service. The **public** Shazam
     catalog (what the "?♪?" button uses) needs no developer token; only a
     *custom* catalog would.
3. Regenerate / let Xcode refresh the **provisioning profile** so it carries both
   entitlements. (`PocketDJ.entitlements` already declares the keys; the profile
   must match for a device build.)

**Checklist**

- [ ] MusicKit enabled on `net.pocketdj.app`.
- [ ] ShazamKit enabled on `net.pocketdj.app`.
- [ ] Provisioning profile regenerated with both.
- [ ] In `project.yml`, uncomment `INFOPLIST_KEY_PocketDJAppleMusicEnabled: "YES"`,
      then `xcodegen generate`.

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

## 3. Spotify dashboard

1. **developer.spotify.com/dashboard → Create app.** Note the **Client ID**.
   (The iOS App Remote flow uses **no client secret on device** — do not ship one.)
2. **App settings → iOS → Bundle ID:** add `net.pocketdj.app`.
3. **Redirect URIs:** add **exactly** `pocketdj://spotify-login-callback`.
   The scheme (`pocketdj`) must also be a `CFBundleURLTypes` entry (step 1) and is
   what `SpotifyProvider.handleCallback` matches.
4. **Premium:** the test/listening Spotify account **must be Premium** — App-Remote
   on-demand playback requires it (the provider maps the failure to "A Spotify
   Premium account is required to control playback.").
5. **Scopes requested by the app:** `app-remote-control`, `user-read-playback-state`.
6. **Link the SDK** (one of):
   - SPM: in `project.yml`, uncomment the `SpotifyiOS` package + the matching
     `- package: SpotifyiOS` dependency, OR
   - drag `SpotifyiOS.xcframework` (from github.com/spotify/ios-sdk/releases) into
     the target's Frameworks.
   The provider gates on `#if canImport(SpotifyiOS)`.
7. **Info.plist** (via the `info:` block in `project.yml`): set
   `SpotifyClientID` = your client id, `SpotifyRedirectURL` =
   `pocketdj://spotify-login-callback`, add `pocketdj` to `CFBundleURLTypes`, and
   `spotify` to `LSApplicationQueriesSchemes` (so the app can hand off to / detect
   the Spotify app). Then `xcodegen generate`.

**Checklist**

- [ ] Spotify app created; Client ID copied.
- [ ] Bundle id `net.pocketdj.app` added.
- [ ] Redirect URI `pocketdj://spotify-login-callback` added (verbatim).
- [ ] Test account is **Premium**.
- [ ] `SpotifyiOS` linked (SPM or xcframework).
- [ ] Info.plist: `SpotifyClientID`, `SpotifyRedirectURL`, `CFBundleURLTypes`
      (`pocketdj`), `LSApplicationQueriesSchemes` (`spotify`); `xcodegen generate`.

### Spotify login flow (how it works)
- Tap **Log in** on the Spotify row → `SPTSessionManager.initiateSession` hands off
  to the installed Spotify app (or App Store / web fallback).
- The redirect `pocketdj://spotify-login-callback` re-enters via
  `PocketDJApp.onOpenURL` → `StreamingStore.handleCallback` → the Spotify provider.
- On success the access token is set on `SPTAppRemote`, which `connect()`s; state
  goes `linked` → `connected`. Scene-phase: background `disconnect()`, active
  `reconnectIfNeeded()` (Spotify requires dropping App Remote when backgrounded).

---

## 4. Google Cloud — YouTube

YouTube has two independent pieces. **Search** needs only an API key; **account
link** additionally needs an OAuth client; **embedded playback** needs the helper
pod but no credentials.

1. **console.cloud.google.com → APIs & Services → Library → enable
   "YouTube Data API v3".**
2. **Credentials → Create credentials → API key.** Restrict it to the YouTube Data
   API. This is the **search** key (`YouTubeAPIKey`).
   - Quota note: `search.list` costs **100 units** of the default 10,000/day
     (~100 searches/day) — debounce + cache before wiring search-as-you-type.
3. *(Optional, only for account-link / the user's own playlists)* **Credentials →
   Create credentials → OAuth client ID → iOS.** Bundle id `net.pocketdj.app`.
   Copy the **client id** (`1234-abcd.apps.googleusercontent.com`) into
   `YouTubeOAuthClientID`. Its **reversed** form
   (`com.googleusercontent.apps.1234-abcd`) is the redirect URL scheme — add it to
   `CFBundleURLTypes` (step 1). Configure the OAuth **consent screen** and add the
   scope `https://www.googleapis.com/auth/youtube.readonly`.
4. *(Optional, embedded playback)* link **`youtube-ios-player-helper`**: uncomment
   its package + dependency in `project.yml` (gated by
   `#if canImport(YouTubeiOSPlayerHelper)`), then `xcodegen generate`. iOS only.
   Until then, `YouTubePlayerView` renders a "player not linked" placeholder.

**Checklist**

- [ ] YouTube Data API v3 enabled.
- [ ] API key created + restricted → `YouTubeAPIKey` in Info.plist.
- [ ] *(optional)* iOS OAuth client created → `YouTubeOAuthClientID`; reversed-id
      scheme in `CFBundleURLTypes`; consent screen + `youtube.readonly` scope.
- [ ] *(optional)* `youtube-ios-player-helper` linked; `xcodegen generate`.

### YouTube login / search flow (how it works)
- **Search works without login:** `YouTubeService` calls Data-API
  `search.list?type=video&videoEmbeddable=true` with the API key and maps hits to
  `StreamingTrack`s (videoId carried as `providerTrackID`).
- **Playback** is the embedded `YTPlayerView` (ToS-compliant IFrame player) — we
  never extract or proxy the audio stream.
- **Account link** (optional): tapping **Log in** runs a Google OAuth PKCE flow via
  `ASWebAuthenticationSession`; the redirect comes back on the reversed-client-id
  scheme through `onOpenURL` → the YouTube provider's `handleCallback`. (Token
  exchange is scaffolded; wire `oauth2.googleapis.com/token` to finish.)

---

## 5. ShazamKit — the "?♪?" button

- **Entitlement:** `com.apple.developer.shazamkit` (already in
  `PocketDJ.entitlements`; enable ShazamKit on the App ID per step 2).
- **Mic permission:** `NSMicrophoneUsageDescription` (already injected). The
  recognizer requests mic access itself and renders a clean **denied** state
  (shake + `mic.slash`) that links to Settings.
- **No credentials / no token** for the **public** Shazam catalog.
- **Where:** the button lives at the **top of the Browser list**. Tap → listen
  (`SHManagedSession`) → match against your in-memory catalog (normalized
  title+artist) → result sheet deep-links into the song if it's in your crate, or
  shows the recognized metadata (and notes a linked Apple Music account could play
  it) if not.
- **Without the entitlement / framework:** the button compiles and shows
  "Recognition isn't available in this build." — no crash.

**Checklist**

- [ ] ShazamKit enabled on `net.pocketdj.app` (step 2).
- [ ] (Automatic) mic usage string present — already in `project.yml`.

---

## 6. Build / test (verifies the default, un-provisioned build)

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

Both succeed with **no** SDKs/credentials/entitlements provisioned — the streaming
+ recognition modules are entirely behind `#if canImport`, `@available`, and the
Info.plist feature flags.

---

## TL;DR — what YOU must configure, per source

- **Apple Music:** portal → enable MusicKit on `net.pocketdj.app`; set
  `PocketDJAppleMusicEnabled = YES`. Needs an Apple Music subscription to play.
- **Spotify:** dashboard → Client ID + redirect `pocketdj://spotify-login-callback`
  + Premium; link `SpotifyiOS`; fill `SpotifyClientID`/`SpotifyRedirectURL` +
  `CFBundleURLTypes`/`LSApplicationQueriesSchemes`.
- **YouTube:** Google Cloud → enable Data API v3 + API key (`YouTubeAPIKey`);
  *(optional)* iOS OAuth client + reversed-id scheme; *(optional)*
  `youtube-ios-player-helper` for playback.
- **ShazamKit:** portal → enable ShazamKit on `net.pocketdj.app`. Mic string is
  already wired.
