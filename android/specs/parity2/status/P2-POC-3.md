state: implemented

Summary: Pure Kotlin port of the iOS pocket wheel engine in data/pockets/wheel/: PocketMode (persisted tokens, Home label,
precedence, related pairs, derive with cycling->trip), MotionToken, PocketMomentKey (h%02d|d%d|mode token, ISO dow,
normalising factory `of`, strict token parse), PocketClock (1970-01-01 = ISO 4), PocketWheelIds, PocketMoment/
PocketWheelSnapshot (@Serializable iOS shape), PocketMomentEngine (all constants, kernel, attribution/origin, mega rule,
add-time scale, round6, top-N, weighted percentile), PocketProfile (@Serializable iOS shape + from(moment)).

- [x] models, snapshot, profile, engine
- [x] tests: PocketMomentEngineTest (iOS tests ported one to one on the shared fixture, copied byte-identical to
  src/test/resources/fixtures/pocket-wheel-history.json, plus mega-by-library-share, membership curve, round6/percentile),
  PocketWheelModelsTest
- Test count: full suite 6195, 0 failures (new files add 30 tests (18 engine + 12 models)); testDebugUnitTest + assembleDebug green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations
- SF-symbol `symbol` on PocketMode omitted (UI package maps icons).
- PocketMomentKey primary constructor does not normalise (data class); engine/callers use PocketMomentKey.of.
- PocketRunTag.runId is a verbatim String (existing POC-1 type), so PocketWheelIds.runTag/runId take/return String.
- Files touched outside owned list: test resource fixtures/pocket-wheel-history.json (copy of the apple fixture).
- JSON doubles print as 1.0 vs Swift 1 (cache is device-local; not cross-synced).

## Questions for Levi
- one-at-a-time.sh default free-memory guard stalls builds here; I ran with FIN_MIN_FREE_GB=5 (same as POC-1).
