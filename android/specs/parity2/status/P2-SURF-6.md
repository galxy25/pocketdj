state: reviewed

Summary: SEARCH_ACTION / MEDIA_SEARCH intent filters route to ShellRoute.BrowseSearch(query) via MediaSearchIntentHandler;
MainActivity.onProvideAssistContent attaches schema.org MusicRecording JSON-LD + webUri while Now Playing is visible
(AssistContent.nowPlayingVisible set from ShellContent); "Add to Home screen" menu row (PinShortcut.kt, label <= 25, reserved
Now Playing ids never) on pocket and playlist detail overflow menus; widget previewLayout + previewImage fallback.

Tests: 6 new (AssistContentTest); suite 7843 tests, 0 failures. :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease green.

Deviations / files touched outside owned set (minimal, additive):
- assistant/MediaSearchHandler.kt (intent handler branch), shell/ShellNavigation.kt (visibility effect),
  screens/playlists/PocketDetailScreen.kt + PlaylistDetailScreen.kt (menu row; the overflow menu lives there, not in CollectionBurnBar.kt, which is untouched).
- Added res/drawable/widget_preview_image.xml. Setlist detail has no pin row (not requested).
- WEB_URI is https://pocket-dj.com/ (assumed).

## Questions for Levi
- Is https://pocket-dj.com/ the right webUri for assistant attribution?

## Review
- MINOR PinShortcut result ignored -> fixed: row hidden when launcher pinning unsupported; Toast shown when request() returns false.
- MINOR AssistContent process-global boolean -> fixed: shell now publishes the current route (SideEffect, no dispose reset); visibility derived at assist time via isNowPlayingVisible (test added). webUri https://pocket-dj.com/ remains an open question for Levi.
- NIT setlist detail has no pin row -> documented, scope unchanged (iOS parity not requested for setlists).

fixes applied. Suite 7844 tests, 0 failures (+1).
