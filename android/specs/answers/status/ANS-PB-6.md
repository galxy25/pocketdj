state: implemented

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
