state: reviewed

# P2-ALB-7 - Album page parity

- [x] `AlbumTrackRow.kt`: row extracted from AlbumDetailScreen; `AlbumTrackRowLayout` pure rules (compact < 600 dp, title lines, keyword truncation 2/3, line-2 composition); two-line phone row, columns on tablets; long-press via combinedClickable
- [x] `AlbumQueueMenu.kt`: album queue menu button (Play next / Play last / Add to playlist) beside the track count + track long-press leading actions
- [x] `AlbumDetailScreen.kt`: artist hotlink (`onOpenArtist`), Stemify button (needs rip server; shared CollectionBurnController progress + over-cap confirm), "Add to Apple Music again" / "In your Apple Music library" (`AlbumLibraryState`), track long-press menu (AddToPlaylistMenu)
- [x] `ShellNavigation.kt`: ALBUM_ROUTE passes `onOpenArtist` (direct push, album stays underneath)
- [x] `CollectionBurnBar.kt`: extracted the stem-confirm + summary dialogs into public `CollectionBurnDialogs` (behavior unchanged for the bar)
- [x] `AlbumTrackRowLayoutTest`: 14 tests. Full suite 7037 tests, 0 failures; assembleDebug green. No manifest/gradle/proguard/library change, so assembleRelease not run.

## Deviations
- No window-size-class library in the project (and none added): "Compact" is `screenWidthDp < 600`, the Material boundary.
- Album queue menu is a DropdownMenu; "Add to playlist" opens the existing album AddToCollectionSheet.
- Ran one-at-a-time.sh WITHOUT --no-quiesce-fin: the wrapper refused to start with LM Studio models loaded; default quiesce + `lms unload --all` per Levi's "builds win" policy.
- No emulator run (instructions): uiautomator/tap/long-press steps unverified on device.

## Questions for Levi
None.

## Review
- MINOR retry runs in composable scope -> fixed: launched on graph.appScope, flag reset in finally, CancellationException rethrown.
- MINOR canAddToLibrary from settings.hasAppleMusic -> rejected: Discover's add flow (DiscoverResultsList.kt:294) and BrowseGraph's library contributor (canContribute) use the same `hasAppleMusic` source, so it matches.
- NIT FlowRow spacers -> fixed: removed, using spacedBy(8.dp, CenterHorizontally). Stemify stays text-only (iOS parity).
- NIT compose/emulator coverage -> not done (emulator off-limits; left for integrator).

Fixes applied. Build + 7037 tests, 0 failures, assembleDebug green (no tests added; no MAJOR).
