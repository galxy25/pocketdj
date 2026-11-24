state: merged

## Summary
- `PocketBestMatch` (data/pockets/wheel): kernels (kt/kd/km/kl), quality, continuity (negated when recent skip rate > 0.5), cloudBoost 1.15, tiers rich / neighbourhood / cloud / history(cold) / empty, best + up to 3 alternatives with distinct dominant collections, `blend`, `modeNow`, `recentActivity`, `cloudProfile`. Constants per design.
- `PocketWheelController`: `refresh`, `profileForMode`, `refreshIfStale`, `playBest`, `playMoment`, `playAlternative`, `momentsNow` (±1 h), summaries; all inputs are seams (car, motion, trip guess, cloud results, empty fallback, play, clock, tz). `modeNow` order: Android Auto (UI_MODE_TYPE_CAR probe) -> motion (`motionNow` seam, null until P2-POC-11/12) -> trip guess.
- `PocketProfile.fromMoment` / `fromListening`; `InThePocketScorer.usableNumeric` is the one shared "defining or coverage >= 0.6" helper (used by cloudProfile and fromListening; no copies, existing scorer tests green).
- `PocketsGraph.wheelController` (lazy, wired) + `emptyFallbackProfile` (T4: most recent collection, else fav_songs). `play` seam left for the run store (P2-POC-7) wire-up: returns false until set.
- Debug "Pocket: status" now appends best-match tier/caption/detail/alternative count.

## Tests
26 new (PocketBestMatchTest). Full suite 6674 tests, 0 failures; `:app:testDebugUnitTest :app:assembleDebug` green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations / touched outside owned files
- PocketProfile.kt (additive builders), CollectionsGraph.kt (`carConnected` private -> internal), DebugScreen.kt (status button extended).
- Tier enum named HISTORY (iOS "history") for the roadmap's "cold" tier; iOS wire token kept.
- `PocketsPlayListener.kt` not changed (car probe reused through CollectionsGraph.carConnected).

## Questions for Levi
None.
