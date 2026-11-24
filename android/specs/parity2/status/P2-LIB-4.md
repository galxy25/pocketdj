state: implemented

# P2-LIB-4: In-app store album page + recognizer edition swap + rejected-MUT reconnect

## Summary
- G15 rejected MUT: `RejectedMut` (pattern `AM <METHOD> <path> -> 401|403`, Worker msg / Http body only, so our gateway's
  `{"error":"unauthorized"}` never matches), `MutRejectionHandler` (serialised; clears only when the rejected token IS the
  stored one and its fingerprint was not already cleared), `AppleMusicTokens.onAppleAuthRejected` (default no-op,
  `DefaultAppleMusicTokens` wires it), `AMPlaylistSyncClient.runJob` calls it on a matching failure.
  Settings > Apple Music syncing shows "Reconnect Apple Music" (`am-reconnect-button`) while the flag is set and no token is stored.
- G13 edition swap: `RecognizerEdition` (iOS `editionMatches` + `preferredStoreID`), `AppleMusicRecognitionPort.preferredEdition`
  (default keeps the id; BrowseGraph adapter searches the catalog). `RecognitionAddController.add` order: swap -> add to AM library
  -> rip+burn with the chosen id (optional `catalogSongIdFor` re-resolves the indexed id). Tri-state setting: never chosen = no swap.
- G12 `AlbumPreviewScreen` + store-owned `AlbumPreviewController` (add single-flight, Download with ONE shared poll loop for all
  albums, exits when idle, retries only tracks not on device), pure `AlbumDownloadState`/`AlbumPreviewUnavailable`/`AlbumPreviewPresentation`
  (ownership via `AlbumOwnership` only). Route `storeAlbum/{storeId}?...`, `StoreAlbumRouter` (SharedFlow) so the recognizer sheet,
  New releases rows and Discover album rows all open it.

## Tests
New: AlbumPreviewControllerTest (18), RecognizerEditionTest (11), RejectedMutTest (11) = 40 new JVM tests.
Full `:app:testDebugUnitTest :app:assembleDebug` green: 7064 tests, 0 failures. `:app:assembleRelease` green.

## Files touched outside the owned list (all minimal/additive)
- di/BrowseGraph.kt (recognizer port override `preferredEdition`)
- screens/shazam/ShazamResultSheet.kt (optional `onOpenStoreAlbum`, dismisses the sheet then routes)
- screens/discover/DiscoverAlbumResultsList.kt + DiscoverResultsList.kt (row tap opens the page via optional `onOpenAlbum`;
  in-place expand remains when null)
- shell/ShellNavigation.kt, screens/foryou/NewReleasesScreen.kt, screens/settings/AppleMusicSettingsScreen.kt (shared touchpoints)

## Deviations
- Tier 1 of the tracklist is the catalog REST `albums/{id}/tracks` (dev token only) rather than MusicKit; tier 2 is `/album-tracks`.
- Discover album rows now open the page on tap instead of expanding in place (the page has the tracklist).
- Per-track explicit badge omitted: `albumTracks` rows carry no explicit flag.
- Reconnect flag lives in settings (`amMutNeedsReconnect`); the row is derived `flag && no token`, so any successful sign-in hides it.
- `one-at-a-time.sh --no-quiesce-fin` was refused (14GB LM Studio models resident); ran with the default quiesce.
- Emulator steps not run (no emulator use per instructions).

## Questions for Levi
- None blocking. Should Discover album rows keep an in-place expand alongside the new page navigation?
