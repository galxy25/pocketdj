state: implemented

# P2-SURF-4 status
- [x] IntentSongMatcher (port of iOS) + tests
- [x] CollectionNameMatcher (strict, 922ea73c) + tests
- [x] MediaSearchResolver rewritten: Any = strict collection -> clear-winner song -> Browse; Song focus plays best; shuffle kept; lastPlayedAt tie-break
- [x] ShellGraph: song rows cached per catalog identity
- [x] testDebugUnitTest + assembleDebug green: 6434 tests, 0 failures (new: IntentSongMatcherTest + CollectionNameMatcherTest)

## Notes / deviations
- `MediaSearchResolver.tier` kept (Android Auto browse search uses it); voice resolution no longer does.
- preferSong (playing song / collection members) is supported by the matcher + resolver but not wired in ShellGraph (no cheap handle to the audible owner there); default none.
- "Pocket phrase" door reserved for P2-POC-16 (comment in resolver).
- Behaviour change: prefix of a collection name now plays ("warm" -> "Warmup") as on iOS; token-coverage matching dropped. Test updated.
- Onboarding veto + ensureReady already live in ShellActions (unchanged); SearchPlayBridge already routes through the same MediaSearchHandler.

## Questions for Levi
- none
