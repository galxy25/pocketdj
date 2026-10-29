state: in-progress

# ANS-MIX-1 Auto-DJ stream failure cooldown
- [x] MixStreamLoader.canStream(songId, forAuto): 2s, 2s, 3s then 120s default; consecutiveFailures reset on completion
- [x] StreamDecks: transientlyUnloadable + loadStreaming(engine.autoMixing) use forAuto; port interface default param
- [x] MixGraph LoaderAutoSeams canStream passes forAuto=true (1-line touch outside owned files)
- [x] Tests: MixStreamLoaderTest (schedule + reset), StreamDecksTest (forAuto flavour)
- [ ] gradle green
Server-down cooldown (60s) unchanged. Manual loads keep 120 s.
