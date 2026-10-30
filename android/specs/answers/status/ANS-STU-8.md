state: merged

# ANS-STU-8 Profile custom-audio source part B: Demuxer "Save to Pocket DJ library" + Add-to

- [x] DemuxSave (DemuxStore.kt): chooseStems (burned set else demux cache, full set only), durationOrNull, save -> ProfileAudioStore.ingest(kind=DEMUX)
- [x] DemuxTimeline: share-arrow (IosShare) button left of follow, spinner while saving
- [x] DemuxScreen: wires save (original = session.audioFile, burned stems else cache, catalog bpm/key/camelot) then opens existing AddToCollectionSheet with the new pdj_ id
- [x] Tests: DemuxSaveTest (7)

## Files touched outside owned list
None.

## Notes
- Mix decks cannot play non-mp3 demux originals (STU-7 limitation); Now Playing/pocket play works.
- Emulator step not run (shared emulator).

## Questions for Levi
None.

## Summary
The Demuxer now saves the loaded demux (original + stems) as a Pocket DJ profile item and immediately presents the Add-to sheet, matching iOS saveDemux.

## Review
- MINOR save cancelled when leaving screen: fixed (save now runs on a process-scoped SupervisorJob scope; completion posts to Main, opens Add-to if still shown, else toasts "Saved to Pocket DJ library").
- MINOR emulator step not run: rejected for this pass (shared emulator owned by integrator); must be run at the merged tip. Remerge runs in ProfileSourceStore.onChanged before ingest returns the id.
- NIT no feedback on failed save: fixed (toast "Couldn't save this demux" when audio present and id null).

fixes applied
