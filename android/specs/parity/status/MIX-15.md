state: reviewed

# MIX-15 Sessions screen + replay timeline + recordings panel
- [x] MixEventSentences.kt (pure port of iOS MixEventDisplay; unknown kind shows raw string)
- [x] MixReplayTimeline.kt (ReplayClock pure math + TimelineCard + replay controls, 33 ms wall-clock, 0.5-4x, scrub, auto-scroll only while playing/not scrubbing)
- [x] MixSessionsScreen.kt (list, Current badge, swipe delete, long-press rename/delete, detail w/ recordings panel via RecordingPlayer + scrub bar + per-take delete)
- [x] Tests: MixEventSentencesTest (14) + ReplayTimelineTest (8) = 22 new; suite 3993 -> 4015, 0 failures; assembleDebug green

## Deviations / notes
- Detail is shown inside MixSessionsRoute (local state + BackHandler); MixRoutes.kt untouched.
- Unknown-kind events are shown (raw kind) rather than filtered as on iOS, per acceptance.
- Load-card tap jumps the playhead (no song-metadata sheet) and CSV export omitted: needs catalog/Browse wiring outside owned files.
- Horizontal wrapped layout for tablets not ported (single vertical list everywhere).

## Questions for Levi
- None.

## Review
fixes applied
- MAJOR stale current-session counts -> fixed: rows built from store.sessionsNewestFirst + durationMs/playedSongIds/events/startedAt (SessionRowText.rows), recomputed on sessions/currentId/playedRevision + 1 s tick; detail header uses store.playedSongIds. Test: SessionRowDataTest (live current session non-zero).
- MINOR rememberSaveable -> fixed: openId, replayMs, speed saved (playing intentionally restarts paused; list scroll already saveable).
- MINOR status ledger -> fixed: docs/ARCHITECTURE-ANDROID.md MIX-15 row = PARTIAL (omits CSV export, load-card sheet, tablet layout); emulator pass pending (integrator).
- MINOR take delete/tags/time -> fixed: empty session folder removed, per-take tags mix-recording-play-/delete-<id>, start time shown.
- NIT unknown-kind count -> accepted, documented (unknown events are shown, so counted).
- NIT test rename -> renamed ReplayClockTest; Compose UI scrub test not added (no emulator allowed).
Tests: 4015 -> 4016, 0 failures; assembleDebug green.
