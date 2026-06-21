# Spotify streaming — developer setup

PocketDJ's Spotify provider is **opt-in** and compiles/ships **without** the SDK or
any credentials (the `#else` stub in `SpotifyProvider.swift` makes the provider
permanently `.unavailable`, and Settings shows a "Not available" note instead of a
Log-in button). Follow these steps only when you want real Spotify playback.

Requires: a **physical iOS device** (the Spotify app isn't on Simulator), the
**Spotify app installed**, and a **Spotify Premium** account (Premium is required
for on-demand App-Remote playback; Free accounts only get shuffle).

---

## 1. Register the app in the Spotify Developer Dashboard

1. Go to <https://developer.spotify.com/dashboard> and **Create app**.
2. Select the **iOS** SDK.
3. Set the **Bundle ID** to `net.pocketdj.app` (must match `PRODUCT_BUNDLE_IDENTIFIER`).
4. Add a **Redirect URI** — *exactly* `pocketdj://spotify-login-callback`.
   The scheme (`pocketdj`) is what ties the dashboard, the Info.plist
   `CFBundleURLTypes`, and `SpotifyRedirectURL` together — all three must match.
5. Copy the **Client ID** (a 32-char hex string). There is **no client secret** on
   device — the iOS SDK uses the App-Remote / implicit flow.

## 2. Add the SDK

Either path produces the module `SpotifyiOS` that `#if canImport(SpotifyiOS)` gates on:

- **SPM (preferred):** in `apple/project.yml`, uncomment the `SpotifyiOS` package
  (`packages:`) and the `- package: SpotifyiOS` dependency under
  `targets.PocketDJ.dependencies`, then `xcodegen generate`.
- **xcframework:** download `SpotifyiOS.xcframework` from
  <https://github.com/spotify/ios-sdk/releases> and drag it into the target's
  **Frameworks, Libraries, and Embedded Content** (Embed & Sign).

> The older guide ships a `SpotifyiOS.framework` + a bridging header + the `-ObjC`
> linker flag. The xcframework / SPM module is the modern equivalent and needs no
> bridging header for Swift `import SpotifyiOS`.

## 3. Info.plist — URL scheme, query scheme, credentials

In `apple/project.yml`, comment out `GENERATE_INFOPLIST_FILE: "YES"` for the
`PocketDJ` target and uncomment the `info:` block (template already in the file),
migrating the existing `INFOPLIST_KEY_*` values in. The effective plist must contain:

```xml
<!-- Lets the Spotify app hand the OAuth token back to us -->
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>net.pocketdj.app.spotify</string>
    <key>CFBundleURLSchemes</key>
    <array><string>pocketdj</string></array>
  </dict>
</array>

<!-- Lets the SDK detect whether Spotify is installed -->
<key>LSApplicationQueriesSchemes</key>
<array><string>spotify</string></array>

<!-- Read at runtime by SpotifyCredentials -->
<key>SpotifyClientID</key>
<string>YOUR_DASHBOARD_CLIENT_ID</string>
<key>SpotifyRedirectURL</key>
<string>pocketdj://spotify-login-callback</string>
```

`SpotifyClientID` empty ⇒ provider stays `.unavailable` even with the SDK linked
(safe default). Fill it to go live.

## 4. Run

`xcodegen generate`, then build to a real device. Settings ▸ **Streaming
accounts** ▸ **Log in** hands off to the Spotify app (OAuth), the redirect comes
back through `PocketDJApp`'s `.onOpenURL`, and `SpotifyProvider` connects its App
Remote. `play(uri:)` then drives playback (`spotify:track:…`).

---

## How it stays compiling without any of the above

| Layer | Without SDK / creds | With SDK + creds |
|---|---|---|
| `SpotifyProvider.swift` | `#else` stub — no-op, `isAvailable == false`, state `.unavailable` | real `SPTSessionManager` + `SPTAppRemote` impl |
| `project.yml` | SDK package + `info:` block commented out; default `GENERATE_INFOPLIST_FILE` | both uncommented |
| Settings row | "Not available" + reason note | Log in / Log out + status |
| Default app build | unchanged — Spotify is fully inert | streaming live |

`SpotifyCredentials` reads `Info.plist` (no hardcoded secrets), so credentials are
build-time config, never source.
