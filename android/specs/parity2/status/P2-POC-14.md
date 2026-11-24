state: implemented

# P2-POC-14 — pocket-wheel-parity.json goldens

- [x] Swift opt-in dump test `apple/Tests/Unit/PocketWheelParityDumpTests.swift` (skipped unless PDJ_DUMP_PARITY=1 / TEST_RUNNER_PDJ_DUMP_PARITY=1)
- [x] Generated `apple/Tests/Fixtures/pocket-wheel-parity.json` with xcodebuild test (iPhone 18 Pro simulator) via one-at-a-time.sh
- [x] Android golden test `PocketWheelParityGoldenTest` (6 tests) reading a copy at `android/app/src/test/resources/fixtures/pocket-wheel-parity.json`
- [x] `:app:testDebugUnitTest :app:assembleDebug` green; 7265 JVM tests, 0 failures (6 new)

## Summary
The golden holds, dumped from the real Swift code: the full wheel snapshot (120 moments, collectionNames, dominanceOrder,
weekShare, totalDirectPlays) on the shared 3-week fixture; 8 best-match cases at fixed Nows (rich/neighbourhood/history tiers,
winner scores, alternatives, a continuity/skip-streak case); the first 100 rows + bench head for seeds 42 and 7 on the
synthetic planner catalogue; and the post-Drake replan (verdict strength, multipliers, bans, 9 replacements, removals).
Android matches numbers at 1e-9 and ids/tokens/strings exactly (snapshot compared via a null==absent tolerant JSON walk).
Both platforms matched on first run: no drift found.

## Deviations / files outside ownership
- `apple/PocketDJ.xcodeproj/project.pbxproj` regenerated with xcodegen to register the new Swift test file (+4 lines).
- The golden is duplicated into `android/app/src/test/resources/fixtures/` (the existing convention, e.g. pocket-wheel-history.json); regenerate both together.
- Regenerate: `TEST_RUNNER_PDJ_DUMP_PARITY=1 one-at-a-time.sh xcodebuild test ... -only-testing:PocketDJTests/PocketWheelParityDumpTests`, then `cp` to the Android resources.
- Infra note: the shared build lock stalled ~1h because two orphaned LM Studio llama-server processes (13.6 GB) tripped the 8 GB free-memory guard of the lock holder; I killed those orphans (per the "builds win" policy).

## Questions for Levi
None.
