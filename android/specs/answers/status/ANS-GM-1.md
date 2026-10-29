state: implemented

# ANS-GM-1 — In the Pocket golden cross-platform test (Q31)

## Summary
A shared fixture now proves the Kotlin `InThePocketScorer` equals the Swift one.
- `apple/Tests/Fixtures/inthepocket-golden-input.json` (identical copy in `android/app/src/test/resources/fixtures/`): 58 cases — cloud (seeds 1..8, time-only, exclusions + familiarity, cloud round-learning exact/relaxed key, collections with membership/candidates/live pull/`collection` learning, trip, weekend, big/zero seeds), history (place narrowing, bucket-only, skips, local round-learning, soft collection membership), cold, plus nothingPlayable / notEnoughCandidates / unknown playable ids / same-artist diversity.
- `apple/Tests/Unit/InThePocketGoldenTests.swift`: WRITER mode (`PDJ_WRITE_GOLDEN=1`, forwarded as `TEST_RUNNER_PDJ_WRITE_GOLDEN=1`) runs `InThePocketScorer.build` per case and writes `android/app/src/test/resources/fixtures/inthepocket-golden-expected.json`; ASSERT mode (default) re-runs and compares to the committed file (1e-9) so Swift drift is caught too; plus a determinism test.
- `InThePocketGoldenTest.kt`: asserts mode, targets (dim/value/label/weight), bpmBand, picks (ids, scores 1e-9, why strings), chips, failures for every case; and a breadth test (all 3 modes, both failures, collection targets, 3 and 4 picks, seeds vary).
- Result: ZERO mismatches — Kotlin port matched Swift on all 58 cases first run; no Kotlin changes needed. Mutation check: perturbing an expected score by 6e-5 fails the Kotlin test.

## Commands / counts
- Swift (My Mac, ad-hoc signing): writer `TEST_RUNNER_PDJ_WRITE_GOLDEN=1 bash apple/scripts/test-macos.sh build-mactest -only-testing:PocketDJTests/InThePocketGoldenTests` then assert run (no env): both "Executed 2 tests, with 0 failures". Regenerate with the writer command only when scorer behaviour changes on purpose.
- Android: `./gradlew :app:testDebugUnitTest :app:assembleDebug` green; 5213 tests, 0 failures/errors (+2 from InThePocketGoldenTest).

## Findings (Swift, not fixed — outside owned files)
- **Swift scorer tie-break is ulp/Dictionary-order dependent for collection membership.** `MembershipPull.cosine` sums over `profile`/`m` dictionaries; members of ONE collection tie mathematically (cosine of a one-entry vector is scale-free) and differ only by ulp noise that varies run to run (`profileNorm` summed in random dict order). So two builds with the same Input+seed can pick different songs (observed in cloud-collections cases), contradicting the "pure and deterministic / replayable" contract in InThePocketScorer's header. Suggested fix (Swift + Kotlin together): sum in sorted-key order and/or quantise scores (e.g. round to 1e-9) before the sort so the id tie-break decides. Kotlin is stable only because its maps iterate in insertion order, but it can diverge from Swift on such exact ties. The golden fixture sidesteps this on purpose: every collection member has distinct familiarity (plays/skips) so no mathematical ties exist (see `separation_plays` in the generator logic; comment in the Swift test header).

## Files touched
Only owned files (fixtures x3, InThePocketGoldenTests.swift, InThePocketGoldenTest.kt) + this status file. `apple/project.yml` untouched (Tests/Fixtures already bundled as resources).

## Questions for Levi
- Want the Swift (and Kotlin) scorer tie-break made order-independent (finding above)? It would change which of several equal-scored songs get picked, so existing seeds would replay differently; the golden would be regenerated.
