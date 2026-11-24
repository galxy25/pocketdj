state: reviewed

- [x] CollectionsStore.onPlaybackReplaced + addAcceptedSong
- [x] NowPlayingFeedback (shared rec target)
- [x] NowPlayingSeams.rating = NowPlayingFeedbackRow (np-feedback), installed from BrowseGraph.startRecs
- [x] tile order (beginPlayback after playNow) already correct in playForYouIds
- [x] build + tests (8 new tests; total 6173 incl. these)

## Summary
NowPlayingFeedback (data/recs) is the shared rec target: sequencer row + RecFeedbackStore.scopeForPlaying, null unless a run is live, not held, and no Mix session owns the deck; toggle; accepted adds via CollectionsStore.addAcceptedSong (zone/new/dead ids add nothing; undo never adds). NowPlayingSeams.rating is installed from BrowseGraph.startRecs as NowPlayingFeedbackRow (np-feedback tag, surface nowPlaying). CollectionsStore.onPlaybackReplaced fires at the end of every publishNowPlaying -> RecFeedbackStore.endPlaybackScope (deferred to first store build if the store is cold); playForYouIds already calls beginPlayback after playNow (iOS order), so ForYou files unchanged.

## Deviations / touched outside owned files
- RecFeedbackButtons.kt: additive optional `recorder` param (routes NP taps through the shared record path).
- No ForYou screen edits were needed; no JSON schema changes. Manifest/gradle untouched (no assembleRelease run).
- Thumbs render in the existing deck-cluster rating slot (shuffle/repeat row), not a separate row; NowPlayingDeckCluster untouched.

## Questions for Levi
None.

## Review
- MAJOR addAcceptedSong membership check -> fixed (membership guard under the store lock, resolved + raw ids; returns false for existing members; test repeatAcceptNeverDuplicatesMembership covers playlist + pocket).
- MINOR onPlaybackReplaced hook race -> fixed (hook installed synchronously in AppGraph.collections lazy block; endRecPlaybackScope always resolves the store; pending flag removed).
- MINOR thumbs placement / recorder param -> rejected as a code change: documented deviation (thumbs sit in the deck-cluster rating slot; the recorder param is a small additive optional). produceState hop kept (avoids main-thread file read).

fixes applied
