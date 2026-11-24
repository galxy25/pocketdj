state: reviewed

- [x] AutoUpNext (source port, rows, tab node, playNow, per-row commands) + AutoId.UpNext / UpNextRow (`upnext`, `upnext:<uid>`)
- [x] AutoBrowseTree: Up Next root entry (only while rows are upcoming), root-limit fold into Playlists
- [x] AutoLibraryCallback: row tap = jumpToUpcoming, upNextCommand, onUpNextChanged (signature-filtered notifyChildrenChanged)
- [x] PlaybackService: SequencerListener -> onUpNextChanged, 3 command buttons (setCommandButtonsForMediaItems), custom-command handler
- [x] AppAutoUpNextSource + UpNextRows; pdj.autoPick=upnext:<uid> in AutoBrowseDebug
- [x] Tests: AutoUpNextTest (18). Full suite 7673 tests, 0 failures; assembleDebug green.

## Summary
Android Auto gets an "Up Next" node listing the sequencer's unplayed rows keyed by uid (repeated songs are distinct). Tap = Play now (jumpToUpcoming); per-row buttons Play next / Move to end / Remove call moveUpcomingNext / moveUpcomingToEnd / removeUpcoming on Main. The sequencer's onQueueChanged/onTransition/session hooks re-notify `upnext` only when row identity/order changed, and the root when the entry appears/vanishes. No Media3 Timeline (D11).

## Deviations / touched outside owned files
- PlaybackService.kt (shared touchpoint), AppAutoServices.kt (AppAutoUpNextSource), AutoLibraryCallback.kt, AutoBrowseDebug.kt: additive.
- Up Next sits at the root only while rows are upcoming (like iOS's contextual button), ahead of the tabs; when the host's root-children limit has no room it folds into the top of Playlists (Continue keeps priority).
- Remove button uses ICON_MINUS (this Media3 has no X-mark icon). assembleRelease not run (no manifest/gradle/proguard/library change).
- No "Now Playing" header row (Auto shows its own now-playing).

## Questions for Levi
- Root placement of Up Next on hosts with a 4-item root limit (folds into Playlists); acceptable?

## Review
- MINOR PlaybackService listener leak -> fixed (listener kept, hooks.remove in onDestroy).
- MINOR root/Playlists count stale, 100-row signature cap -> fixed (signature includes total count; count change re-notifies root+tabs via notifyLibraryChanged). Tests: countChange_pastTheRowCap_stillNotifies, updated queueChange tests.
- NIT notifiedReady guard -> fixed (whole notify path guarded; test beforeCatalogReady_queueEditsDoNotNotify).
- NIT Now Playing header / icon / emulator smoke -> not changed; emulator smoke is device-only (integrator owns emulator).

fixes applied
