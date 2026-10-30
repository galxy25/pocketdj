state: reviewed

# ANS-PB-4 Skip-count sink consumers
- [x] PlayCountService facade (snapshot of plays/skips/lastPlayed from PlayStatsStore; skipPenalty; withSkips)
- [x] ForYouInputsFactory.build reads PlayCountService (history-derived skip rebuild removed) on IO
- [x] ForYouSongListScreen collection path fallback feedback carries the skip penalty (zone path rides inputs.zoneFeedback)
- [x] ForYouSkipInputsTest (3 tests)
- [x] gradle green: 5276 tests (3 new in ForYouSkipInputsTest), 0 failures
Files touched outside owned: none.

## Review
- MINOR PlayStatsStore never seeded from history -> fixed: PlayStatsStore.seedFromHistoryIfNeeded (one-shot, historySeededAtMs flag, only when stats empty, clear() stamps it); called in ForYouInputsFactory.build on IO.
- MINOR COLLECTION fallback lacked scoped feedback -> fixed: withSkips(stores.feedback.zoneFeedback(route.feedbackContext, inputs.nowMs), inputs.skipPenalty).
- NIT second snapshot / FQ names -> fixed: ForYouFeedInputs.skipPenalty carried; PlayCountService imported.
- NIT factory wiring untested -> partial: tests assert inputs carry skipPenalty and seed feeds the snapshot; build() needs AppGraph, not extracted.
fixes applied. gradle green: 5279 tests (+3), 0 failures.
