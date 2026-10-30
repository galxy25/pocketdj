state: implemented

# ANS-PB-4 Skip-count sink consumers
- [x] PlayCountService facade (snapshot of plays/skips/lastPlayed from PlayStatsStore; skipPenalty; withSkips)
- [x] ForYouInputsFactory.build reads PlayCountService (history-derived skip rebuild removed) on IO
- [x] ForYouSongListScreen collection path fallback feedback carries the skip penalty (zone path rides inputs.zoneFeedback)
- [x] ForYouSkipInputsTest (3 tests)
- [x] gradle green: 5276 tests (3 new in ForYouSkipInputsTest), 0 failures
Files touched outside owned: none.
