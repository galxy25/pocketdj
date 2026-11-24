state: reviewed

# P2-SOC-1: Jukebox Timeless + Mix antenna + NP Share + History multi-select Share

- [x] JukeboxUrls.config, JukeboxClient.createSession(timeless)/configure, JukeboxLifecycle + mergeLifecycle, repository start(timeless)/setTimeless
- [x] JukeboxScreen: create toggle + live toggle "Timeless — never expires" + 24 h / 7 d footer copy; expiry line shows Timeless; hostKey never rendered
- [x] MixBroadcastButton (testTag mix-broadcast), placed in Mix top bar beside Record; repository.ensureBootstrapped() so the "no session?" check doesn't race the persisted-session load
- [x] NowPlayingShare (np-share button under transport; forSong else forTitleArtist; hidden with nothing playing)
- [x] SelectionBar gained a Share action (selection-share) -> ShareText.forSongs, so Browse AND History get it; History gained multi-select (row menu "Select", tap/long-press routing, scope history-playback)
- [x] JukeboxTimelessTest (15 tests)

## Test count
15 new tests (full suite now 7471, 0 failures); testDebugUnitTest + assembleDebug green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations / files outside owned set (minimal, additive)
- ui/selection/SelectionUi.kt: Share button + SelectionBarSemantics.shareText.
- screens/history/HistoryRowMenu.kt (new SELECT action), screens/history/HistorySelection.kt (new, pure helper).
- No Hero/Remote "half" switch exists in JukeboxScreen, so the antenna opens the Jukebox tab (Tab route).
- NP has no overflow menu; Share is an inline TextButton under the transport row.
- The build wrapper refused `--no-quiesce-fin` (7GB LM Studio model loaded); built with default quiescing, which restored Fin afterwards.

## Questions for Levi
None.

## Review
- setTimeless no in-flight guard (MINOR) -> fixed: `UiState.timelessPending` claims a single in-flight call (second tap dropped), switch shows the requested value optimistically and is disabled while pending; cleared in finally.
- Share reads base catalog (MINOR) -> partly rejected: `catalogRepository.state.catalog` IS the MergedCatalog History uses (same source), so no id is lost to a different catalog. Real defect fixed: Share is now enabled only when `shareText` resolves non-null.
- Antenna fire-and-forget (MINOR) -> accepted as is (disclosed deviation; no Hero/Remote switch exists).
- pruneKey identityHashCode (NIT) -> fixed: keyed on `orderedEvents.hashCode()` (content).
- Tests: +2 (selectionShare_nullWhenNothingResolves, timelessPending_defaultsIdle); JukeboxTimelessTest 15 -> 17, suite 7473, 0 failures; testDebugUnitTest + assembleDebug green.

fixes applied
