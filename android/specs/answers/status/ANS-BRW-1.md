state: reviewed

# ANS-BRW-1 Discover: Play on ripped rows; serverless album adds

- [x] DiscoverRowState (ripped = hit.ripped || manifest has id; trailing precedence PLAY/PAUSE/WORKING/ADDED/ADD)
- [x] Song row: play/pause via PlaybackController.play(queueAlbumContext=false); long-press Play Next/Last (only when a queue runs) via ShellActions.enqueueSong
- [x] Album + enabled whenever results show; help = addHelp("album", canAddToLibrary); removed ALBUM_NEEDS_SIGN_IN
- [x] No-MUT add already records LibraryWrite.SKIPPED_NO_CONNECTION (BrowseGraph token map); test added
- [x] Tests: DiscoverRowStateTest (6), DiscoverAddControllerTest +1

## Files outside owned set (minimal, additive)
- (none after review: ShellActions/ShellGraph seam removed; row calls sequencer directly)

## Deviations
- iOS "Add to Catalog" backfill menu item and AddToPlaylistMenu not ported (out of scope).
- Immediate-submit IME hook left out (BrowseScreen.kt polish-gated).

## Summary
Ripped Discover rows play/pause via PlaybackController.play; long-press Play Next/Last via ShellActions.enqueueSong; album + enabled with results (no sign-in gate); no-MUT adds record SKIPPED_NO_CONNECTION. Build + unit tests green; DiscoverRowStateTest 6 + DiscoverAddControllerTest 14 (+1 new).

## Questions for Levi
None.

## Review
fixes applied
- MINOR ripped-row play metadata/feedback -> fixed: songs missing from the merged catalog play via playQueue with a QueueEntry carrying hit title/artist/length; catalog songs use play() and NotPlayable/Failed now show an inline error under the row. PlaybackController untouched.
- MINOR ShellGraph/ShellActions hot-file seam -> fixed: reverted both; row calls sequencer.insertNextInQueue/appendToQueue directly (as PlayedList does).
- MINOR weak tests -> fixed: BrowseGraph token map extracted to pure `libraryWriteToken`, tested for Ok/NeedsUserToken/Failure; dead `albumAddEnabled(hasAnyTrackSource)` removed. Not done: Compose UI wiring tests (no Compose test harness in unit suite); ShellActions.enqueueSong test moot (removed).
- NIT long-press/ripple on non-actionable rows -> fixed: combinedClickable enabled only when ripped && queueRunning. Phase caption on spinner not added.
Tests: 5281 passed, 0 failed (+1).
