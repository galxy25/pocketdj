state: merged

# PB-7 status
- [x] QueueReorder (pure: window 200, uid-resolved move, clamp, origin route, layout rule)
- [x] NowPlayingSearch (tokenized, exact > prefix > contains, caps 25/10) + search bar/results UI
- [x] UpNextList (drag handle, swipe/X remove by uid, row menu), PlayedList (Rewind / Play now fresh copy)
- [x] Expanded layout (>=600dp or landscape), Open set list / origin button, screen wiring
- [x] Jukebox inserts via sequencer (JukeboxQueue seam + JukeboxPlacement); MediaController removed from data/jukebox
- [x] Tests: QueueReorderTest, UpNextUidEditsTest (real sequencer), NowPlayingSearchTest, JukeboxPlacementTest (~27 tests); full suite 2216 green

## Deviations / notes
- Touched outside owned files: data/jukebox/JukeboxGraph.kt (one line: wires SequencerJukeboxQueue).
- Placement/seam types (JukeboxQueue, JukeboxPlacement) live in JukeboxRepository.kt; JukeboxPlacementTest is in test/data/jukebox.
- Row X/swipe removes by the row's own uid (identity captured at render), a no-op if already gone; stricter than re-resolving by offset.
- Jukebox snapshots (now playing/up next) now read from the sequencer + PlaybackController, not a MediaController.
- Jukebox context uses PlayContext(source="jukebox") - no constant added to PlayEvents.kt.
- NowPlayingSeams.playedList no longer invoked by the screen (PlayedList is called directly).
- Compose UI is emulator-unverified (emulator not used per instructions).

## Questions for Levi
- None.

## Review
- MAJOR JukeboxPlacement idle test replaced a sounding album -> fixed: place() takes ForeignPlayback (nowPlaying set while sequencer idle) and adopts it into a one-row run (SetlistSequencer.adoptForeign, resumes at the live position) before inserting; only truly-idle starts a run. Tests: JukeboxPlacementTest.foreignPlaybackIsAdoptedNotReplaced, SequencerJukeboxQueueTest.foreignPlaybackIdleSequencer_isAdoptedAndRequestQueuesAfterIt
- MINOR startRun skipped recording guard -> fixed: applyPlacement checks AudioFocusPolicy.mayStartPlayback() and surfaces "Recording in progress"
- MINOR Open set list used playNow -> fixed: CollectionsStore.materializeNowPlayingSetlist (all rows, titles, repeats; no revision/source change); test added
- MINOR add-search no-op when sequencer idle -> fixed: addRows adopts sounding audio or starts a run via playQueue
- MINOR random-slot test vacuous -> fixed: randomSlots deleted; SequencerJukeboxQueueTest runs production queue on real SetlistSequencer, asserts range 2..4 and final position
- MINOR Up Next eager column -> fixed: LazyColumn keyed by uid, height-bounded (520dp) so it nests in the compact page scroll
- NIT played menu -> fixed: Play again next/last + "Nothing played yet" empty state
- Suite: 2221 tests, 0 failures (was 2216); assembleDebug OK

fixes applied
