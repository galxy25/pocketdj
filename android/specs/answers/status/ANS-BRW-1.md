state: implemented

# ANS-BRW-1 Discover: Play on ripped rows; serverless album adds

- [x] DiscoverRowState (ripped = hit.ripped || manifest has id; trailing precedence PLAY/PAUSE/WORKING/ADDED/ADD)
- [x] Song row: play/pause via PlaybackController.play(queueAlbumContext=false); long-press Play Next/Last (only when a queue runs) via ShellActions.enqueueSong
- [x] Album + enabled whenever results show; help = addHelp("album", canAddToLibrary); removed ALBUM_NEEDS_SIGN_IN
- [x] No-MUT add already records LibraryWrite.SKIPPED_NO_CONNECTION (BrowseGraph token map); test added
- [x] Tests: DiscoverRowStateTest (6), DiscoverAddControllerTest +1

## Files outside owned set (minimal, additive)
- shell/ShellActions.kt: `queueSink` + `enqueueSong(item, next)`
- di/ShellGraph.kt: wires queueSink to the sequencer insertNext/append

## Deviations
- iOS "Add to Catalog" backfill menu item and AddToPlaylistMenu not ported (out of scope).
- Immediate-submit IME hook left out (BrowseScreen.kt polish-gated).

## Summary
Ripped Discover rows play/pause via PlaybackController.play; long-press Play Next/Last via ShellActions.enqueueSong; album + enabled with results (no sign-in gate); no-MUT adds record SKIPPED_NO_CONNECTION. Build + unit tests green; DiscoverRowStateTest 6 + DiscoverAddControllerTest 14 (+1 new).

## Questions for Levi
None.
