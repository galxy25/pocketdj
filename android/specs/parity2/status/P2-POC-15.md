state: implemented

# P2-POC-15: Mix-mode best match plays through Mix Auto-DJ

- [x] PocketRunMixPath (threshold 10, slots/collections, items, caption) + tests
- [x] MixFacade.startAutoMixSongs / autoMixLabel; MixFacadeImpl
- [x] PocketRunStore: playThroughMix now suspend, uses PocketRunMixPath, mixCaption StateFlow (fallback caption)
- [x] MixPlayOutcomeBridge.pocketRunTag stamps pocketRun on Mix plays; MixGraph wiring
- [x] PocketsGraph wires playThroughMix / mixOwnsRun
- [x] gradle green: testDebugUnitTest + assembleDebug; 7266 total tests, 7 new (PocketRunMixPathTest); release build not needed (no manifest/gradle/proguard change)

## Notes / touched outside owned files
- MixResolver.loadables(songIds) made public (was private); MixGraph + PocketsGraph wiring (additive).
- No live replan on the Mix path (accepted iOS follow-up). iOS `autoDJBlockedReason` (mixing-together) has no Android analogue.

## Questions for Levi
- None.
