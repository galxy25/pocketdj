state: in-progress

# P2-MM-1 Mix Mode ph1a: temporary-hold ledger, AssetOrigin, pin funnel, npMix settings keys

- [x] BurnModels: TemporaryHold, AssetOrigin (explicit/buffer/incidental), BurnDocument.temporaryHolds (additive-optional)
- [x] TemporaryHolds.kt: pure TemporaryHoldLedger (noteCreated/pin/pinAll/forget, picked-folder rules)
- [x] BurnStore: holds StateFlow, pin funnel (burn, burnWhenRipped, burnStems, burnStemPart, adopt*), removal drops holds
- [x] MixStreamLoader: open/openStems(origin), explicit-join upgrade + pin, StreamAdopter origin
- [x] NpMixSettings.kt (iOS-verbatim keys/defaults)
- [x] Tests
- [ ] Green build (testDebugUnitTest, assembleDebug)

## Notes / deviations
- AssetOrigin has a third case Incidental (as iOS). It is the default for burnStemPart / adoptStreamed* at the
  BurnStore level so existing callers (Stem Lock lane in MixGraph, DSP stem source) keep legacy permanent behaviour.
  MixStreamLoader defaults to explicit("mix") as specified.
- BurnStore takes `bufferTtlHours` / `keepPickedFolderBuffers` provider lambdas (defaults 48 h / false). ServicesGraph
  is NOT yet wired to NpMixSettings (no buffer-origin caller exists until P2-MM-4/5); wire when the lane lands.
- Touched outside owned files: test/.../BurnTestSupport.kt (Rig.store params), MixStreamLoaderTest.kt (adopter fake
  signature + 3 origin tests).
- Sweep (TemporarySweep.kt) is a later package; BurnStore exposes dropHold/pin/pinAllTemporary/onTemporaryHoldsChanged for it.

## Questions for Levi
- none
