state: implemented

# P2-SURF-5 status
- [x] AddToCollectionAction.kt: CollectionRef (pocket:/playlist: ids), AddToCollectionResult (iOS dialog strings), AudibleOwner, AddToCollectionAction (pocket -> membership, playlist -> FIRST chapter, member never toggled off, reserved Now Playing refused; goes through AddToActions so Recent / Activity / AM write-back fire)
- [x] ShellActions: addSongToCollection(songId?, collectionId), currentSongId(), NothingPlaying + CollectionNotFound errors, autoMixLine, addLinkSeam / autoMixLinkSeam
- [x] DeepLinkParser/Dispatcher: pocketdj://add?collection=&song= and pocketdj://automix/<pocket|playlist|setlist>/<id>[?shuffle=1] (veto + ensureReady via ShellActions); seams unwired -> honest toast
- [x] shortcuts.xml: custom.actions.intent.ADD_TO_COLLECTION / AUTO_MIX capabilities with queryPatterns (res/values/app_actions.xml); dynamic "Auto-mix <last crate>" shortcut (1 slot, ShortcutsPublisher withAutoMix, on in ShellGraph)
- [x] Tests: AddToCollectionActionTest (16). Total 6664 JVM tests, 0 failures; testDebugUnitTest + assembleDebug + assembleRelease green.

## Files touched outside owned list
- di/ShellGraph.kt (wire seams, audibleSongId, withAutoMix), di/MixGraph.kt (additive mixLiveSong()/mixDeckTitle(), never builds the engine).

## Deviations / notes
- App Actions parameters: the capability url-templates pass raw `collection` / `kind`+`id`; resolving a spoken name to a `pocket:<id>` needs shortcut-bound entities, not done (device-only, best-effort; deep links + launcher shortcut are the reliable doors). Unverified on a device.
- Result toast for deep-link auto-mix uses "Auto-mixing X — N burned songs." (", shuffled" added when shuffle, as iOS).
- "this song": Mix wins only when it is active (isRunning/autoMixing) and has a live-deck song; otherwise the sequencer row (playing or paused).

## Questions for Levi
- App Actions is being wound down; declared anyway (default per roadmap: yes). Say if you'd rather drop the capabilities.
