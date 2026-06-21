# Apple Music + Shazam setup (MusicKit / ShazamKit)

These two providers use **system frameworks** (MusicKit, ShazamKit) — there is no
third-party SDK to add and **no client secret / API key on device**. The default
build compiles and runs with both features *dormant*; they light up only after the
portal toggles + entitlement + Info.plist usage strings below exist.

## What's in this module

| File | Role |
|---|---|
| `AppleMusicProvider.swift` | `StreamingProvider` + `StreamingSearch` + `SongRecognizer`. Real MusicKit behind `#if canImport(MusicKit)`, no-op stub otherwise. Dormant until `PocketDJAppleMusicEnabled = YES`. |
| `AppleMusicCatalog.swift` | Pure mapping `AppleMusicSongRow → StreamingTrack / IndexSong`. `IndexSong` is **Decodable-only**, so rows are built by decoding a JSON object; `length` is **ms** (seconds × 1000); ids are namespaced `am:<storeID>`. |
| `SongRecognizer.swift` | The third capability protocol (catalog resolution), reusing `StreamingTrack`. |
| `../Shazam/ShazamRecognizer.swift` | `@MainActor @Observable` `SHManagedSession` state machine for the "?♪?" button. |
| `../Shazam/ShazamCatalogMatch.swift` | Pure normalized title/artist → catalog `IndexSong` matcher. |
| `../../Views/Shazam/ShazamButton.swift` / `ShazamResultSheet.swift` | The mic button + result sheet. |

## Compile-without-credentials behavior

- **Apple Music**: `AppleMusicCredentials.isEnabled` reads `PocketDJAppleMusicEnabled`
  from Info.plist. Absent / not "YES" ⇒ `state == .unavailable` and
  `MusicAuthorization.request()` is **never** called (so a missing
  `NSAppleMusicUsageDescription` cannot crash the default build).
- **Shazam**: the button renders always; `start()` only touches the mic at runtime,
  where it needs the entitlement + `NSMicrophoneUsageDescription`.

## To actually enable (per developer / when provisioning)

### Apple Developer portal (team EC27UF79GL, App ID `net.pocketdj.app`)
1. Enable **MusicKit** App Service on the App ID.
2. Enable **ShazamKit** App Service on the App ID.
   (Both are manual toggles; `-allowProvisioningUpdates` mints the profile after.)

### Entitlements
`PocketDJ/PocketDJ.entitlements` already carries both keys; wire once in
`project.yml`:

```yaml
CODE_SIGN_ENTITLEMENTS: PocketDJ/PocketDJ.entitlements
```

### Info.plist (project.yml)
Scalar usage strings go in as `INFOPLIST_KEY_*` under `targets.PocketDJ.settings.base`:

```yaml
INFOPLIST_KEY_NSAppleMusicUsageDescription: "PocketDJ uses Apple Music to search and play tracks you own."
INFOPLIST_KEY_NSMicrophoneUsageDescription: "PocketDJ listens briefly to identify the song that's playing."
PocketDJAppleMusicEnabled: YES      # opt-in flag; remove/NO keeps Apple Music dormant
```

`PocketDJAppleMusicEnabled` is a custom Info.plist key (not an `NS…` system key),
so it can be added as a plain `INFOPLIST_KEY_PocketDJAppleMusicEnabled: YES` too.

### Subscription
On-demand catalog playback requires the device Apple ID to have an active
subscription whose `MusicSubscription.current.canPlayCatalogContent == true`.
Search and recognition work without it; playback surfaces a friendly note when it's
missing.

## Notes
- Apple Music auth is a **native consent sheet**, not OAuth — `handleCallback(url:)`
  is always a no-op for this provider; nothing to register in `CFBundleURLTypes`.
- ShazamKit uses the **public** Shazam catalog (no developer token).
- Deployment targets (iOS 18 / macOS 15) clear MusicKit's (16/13) and ShazamKit's
  (15/12) floors, so no `#available` branch is needed at call sites.
