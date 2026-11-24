state: implemented

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
