# YouTube streaming — developer setup

PocketDJ's YouTube provider is **opt-in** and compiles/ships **without** the
player helper pod or any credentials. Two independent capabilities, each with its
own gate:

| Capability | Backend | Needs | Without it |
|---|---|---|---|
| **Search** | `YouTubeService` — Data API v3 | a Data API **key** | provider `.unavailable`; Settings shows a note |
| **Playback** | `YouTubePlayerView` — `YTPlayerView` (WKWebView) | the **youtube-ios-player-helper** package | a "player not linked" placeholder renders |
| **Account-link** | `YouTubeProvider.login()` — Google OAuth (PKCE) | an **iOS OAuth client id** | Log-in button is inert/`.unavailable` |

Search + embedded playback are anonymous and work **without** OAuth. Linking the
user's Google account (OAuth) is OPTIONAL — it unlocks *their* playlists/likes and
is how we "connect our app to their account".

> ToS, important: YouTube content may only be played through the **official
> embedded player** (`YTPlayerView`/IFrame). Do **not** extract, proxy, download,
> or background-only the audio stream, and don't hide the player chrome — that
> violates the YouTube API Services Terms. The player must behave "nearly
> identical to a player embedded on a webpage in a mobile browser". One
> `YTPlayerView` plays at a time (no concurrent playback); private videos can't be
> played (unlisted can). Reuse one player and `cueVideoById:` rather than making
> new instances.

---

## 1. Google Cloud setup

1. Go to <https://console.cloud.google.com> → create / pick a project.
2. **APIs & Services ▸ Library ▸ enable "YouTube Data API v3".**
3. **APIs & Services ▸ Credentials ▸ Create credentials ▸ API key.** Restrict it:
   *Application restrictions* → **iOS** (your bundle id `net.pocketdj.app`);
   *API restrictions* → **YouTube Data API v3**. This key powers **search**.
4. **Create credentials ▸ OAuth client ID ▸ iOS** (only if you want account-link).
   - Bundle ID: `net.pocketdj.app`.
   - Google generates a client id like `1234-abcd.apps.googleusercontent.com` and
     its **reversed** form `com.googleusercontent.apps.1234-abcd` — that reversed
     string is the **redirect URL scheme** the app registers (step 3 below).
   - There is **no client secret** on device — iOS uses the OAuth **PKCE** flow.
   - Configure the **OAuth consent screen** (scope
     `https://www.googleapis.com/auth/youtube.readonly`); add yourself as a test
     user while it's unverified.

### Quota / ToS limits to know

- `search.list` costs **100 units**; default quota is **10,000 units/day** →
  **~100 searches/day**. Debounce search-as-you-type and cache results.
  `videos.list` (durations) costs 1 unit.
- API keys authorize **public data only**; OAuth is required for a user's private
  resources. Never embed an unrestricted key in a shipped build.

## 2. Add the player helper (playback only)

The SPM product/module is `YouTubeiOSPlayerHelper`, which
`#if canImport(YouTubeiOSPlayerHelper)` gates on in `YouTubePlayerView.swift`:

- In `apple/project.yml`, uncomment the `YouTubeiOSPlayerHelper` package
  (`packages:`) and the `- package: YouTubeiOSPlayerHelper` dependency under
  `targets.PocketDJ.dependencies`, then `xcodegen generate`.
- CocoaPods alternative (if not using XcodeGen/SPM):
  `pod "youtube-ios-player-helper", "~> 1.0"`.

iOS only — `YTPlayerView` is UIKit/WKWebView. On macOS the view falls back to an
"Open in YouTube" link.

## 3. Info.plist — credentials + OAuth redirect scheme

In `apple/project.yml`, comment out `GENERATE_INFOPLIST_FILE: "YES"` for the
`PocketDJ` target and uncomment the `info:` block (template already in the file),
migrating the existing `INFOPLIST_KEY_*` values in. The effective plist must
contain:

```xml
<!-- Read at runtime by YouTubeCredentials -->
<key>YouTubeAPIKey</key>
<string>AIza...your-data-api-key...</string>
<key>YouTubeOAuthClientID</key>
<string>1234-abcd.apps.googleusercontent.com</string>

<!-- OAuth redirect: the scheme is the REVERSED client id -->
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>net.pocketdj.app.youtube</string>
    <key>CFBundleURLSchemes</key>
    <array><string>com.googleusercontent.apps.1234-abcd</string></array>
  </dict>
</array>
```

`YouTubeAPIKey` empty ⇒ provider stays `.unavailable` (safe default). Add the key
to enable search; add the OAuth client id + URL scheme to enable account-link.

## 4. Run

`xcodegen generate`, then build. Settings ▸ **Streaming accounts** ▸ **YouTube**:
- With a key only: search works; the Log-in button drives the OAuth sheet
  (`ASWebAuthenticationSession`, PKCE) when a client id is also present.
- The redirect comes back via the reversed-client-id scheme through
  `PocketDJApp`'s `.onOpenURL` → `StreamingStore.handleCallback(url:)` →
  `YouTubeProvider.handleCallback(url:)` (token exchange is wired there).
- Playback: present `YouTubePlayerView(videoID:)` for a chosen
  `StreamingTrack.providerTrackID`.

---

## How it stays compiling without any of the above

| Layer | Without pod / creds | With pod + creds |
|---|---|---|
| `YouTubePlayerView.swift` | `#else` placeholder (no pod) | real `YTPlayerView` embed |
| `YouTubeProvider.swift` | `.unavailable` when no API key; PKCE scaffold inert | OAuth sheet + token exchange |
| `YouTubeService.swift` | always present (pure URLSession); throws `.notConfigured` with no key | live Data API search |
| `project.yml` | package + `info:` block commented out | both uncommented |
| Settings row | "Not available" + reason note | Log in / Log out + status |

`YouTubeCredentials` reads `Info.plist` (no hardcoded secrets), so credentials are
build-time config, never source. The provider conforms to the same
`StreamingProvider` seam as Spotify, so the Settings UI and registry are
provider-agnostic.

## Remaining wiring (scaffold TODOs)

- `YouTubeProvider.handleCallback(url:)`: exchange the auth `code` + PKCE verifier
  at `https://oauth2.googleapis.com/token`, persist via `StreamingTokenStore`,
  fetch the channel title for the account label, set `.linked(account:)`.
- `YouTubeProvider.pkceChallenge`: replace the placeholder with a real
  SHA256→base64url (`import CryptoKit`).
- Optional `videos.list` lookup to fill `StreamingTrack.durationSeconds`.
