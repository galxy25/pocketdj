state: merged

# ANS-PB-6 HeldQueue resumption

- [x] HeldQueue.kt: snapshot -> MediaItems (songId/title/artist/clip length) + MediaItemsWithStartPosition (index, positionMs); file loader for the isRecent root
- [x] ResumptionProvider: single decode (removed duplicate load); loadHeld()/restore(held)
- [x] PlaybackService.onPlaybackResumption: built off Main (single-thread executor), arms forwarding player
- [x] SequencerForwardingPlayer: matching setMediaItems -> restore + resumeFromHold (never clears a live run)
- [x] onGetLibraryRoot isRecent -> cheap root; onGetChildren(recent root) -> one child from the snapshot file (no AppGraph)
- [x] Manifest: androidx.media3.session.MediaButtonReceiver (MEDIA_BUTTON)
- [x] Tests: HeldQueueTest (6), ResumptionSnapshotTest (+1), SequencerForwardingPlayerTest (+3). Full suite 5606 tests, 0 failures; assembleDebug + assembleRelease green.

Notes: artwork is not in the snapshot, so items carry no art URI (HeldQueue takes an artFor hook, unused). Build needs -Pkotlin.daemon.jvmargs=-Xmx4g locally (Kotlin daemon OOM otherwise). Emulator step not run (shared emulator).

## Questions for Levi
None.

## Review

- MAJOR consumeResumption skipped mic/arbiter gates -> fixed: micGate + permitted() run first; a refusal swallows the set, emits the verdict, restores/starts nothing. Tests: resumptionHonoursTheMicCaptureGate, resumptionHonoursTheSwitchboardArbiter.
- MAJOR arm never expires / swallowed later real load -> fixed: one-shot (any set clears it), 2 s TTL, in-app (callerInternal) sets never consume it. Inverted old test (aForeignSetIsPassedThroughAndClearsTheArm); added aStaleArmNeverSwallowsALaterMatchingLoad, anInAppControllerSetNeverConsumesTheArm.
- MAJOR onPlaybackResumption built whole AppGraph -> fixed: reads the snapshot file via HeldQueue.load on the worker (one decode, no graph); graph is built only in restoreForResumption when the matching set arrives. KDoc records that Media3 owns System UI's recent root.
- MINOR 3 s boot-notification teardown -> fixed: re-checks (1 s, max 12) while a resumption is armed or a start is pending.
- MINOR artwork -> fixed with caveat: art resolved from catalog/AlbumArtworkStore when the process already has an AppGraph (AppGraph.peek()); a cold boot has none by design (finding 3 forbids building the graph). Not unit-tested (needs AppGraph).
- MINOR executor future never completes -> fixed: whole task in try/catch -> setException; RejectedExecutionException caught.
- MINOR decode-once test -> fixed: PlaybackSessionStore.loadCount asserted == 1; port loads asserted empty.
- NIT KDoc -> fixed.

Fixes applied. Suite 5610 tests (was 5606, +4), 0 failures; assembleDebug green.
