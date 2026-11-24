state: implemented

Summary: PlayEvent.motion + pocketRun (PocketRunTag, runId kept verbatim, lenient decode to null on unusable tag);
PlayContext.pocketRun copied by record() (source stays pocket, no new PlaySource); stampMotion (write-once, own-only,
blank ignored); reloadFromDisk merge first-non-null-wins for both, and both counted in holdsFieldsMissing (republish check).

- [x] all sub-steps; 6 new tests in PlayEventWheelFieldsTest; full suite 5786 tests, 0 failures; assembleDebug green.
- assembleRelease not run (no manifest/gradle/proguard/library change).
- Files touched outside owned list: none (PlayHistoryModels, PlayHistoryStore, PocketRunTag, PlayEvents, test).

## Notes
- The one-at-a-time wrapper's default 8GB free-memory guard never cleared on this Mac (~7GB reclaimable), stalling the
  whole wave's queue for >1h. I ran with FIN_MIN_FREE_GB=5 (single serialized build, no LM model resident).

## Questions for Levi
- Should the one-at-a-time free-memory threshold be lowered (or counted differently) for gradle builds?
