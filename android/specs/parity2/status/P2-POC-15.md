state: reviewed

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

## Review
- MixFacadeImpl skips settings push -> fixed (new `pushSettings` param, wired in MixGraph to `MixSettingsPush.pushAll`; called before startItems)
- First song loses run tag -> fixed (PocketRunStore publishes provisional viaMix state before `playThroughMix`, rolls back on <10 or throw)
- Fallback caption not shown / stale -> partly fixed: cleared on start/stop/dismiss/end. Rendering it is a wheel-UI concern (no consumer in this package); StateFlow `mixCaption` is the contract.
- Tests missing -> fixed (3 store tests, 2 facade tests incl. 9 vs 10 gating and settings push)
- NIT autoDJBlockedReason -> rejected (no Android mixing-together mode yet)

fixes applied
