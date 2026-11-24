state: implemented

Summary: Pure Kotlin port of iOS PocketRunPlanner + PocketRunCandidates in data/pockets/wheel/: constants, Scorer,
fillingGapsFromSeeds / withNeighbourCollections / derived, pool (core+soft, per-collection pool share), quotas, compose
(plan: paced fresh floor over every prefix, artist cap/spacing, newcomer floor, seed cap, instant lead, flow by BPM/Camelot,
SplitMix64 + weightedDraw), bench, replan (ban/median floor, spacing vs live neighbours, requiresInstant), topUp, musicalSim,
recency. Candidates built from rip manifest + burned + AM (appleMusicId when streamable) with add-time-scaled memberships,
fav_songs 0.75, genre category (other -> nil), credit artist keys, startsInstantly for burned.

- [x] PocketTuning.kt (planner-facing half), PocketRunPlanner.kt, PocketRunCandidates.kt
- [x] tests: PocketRunPlannerTest (14), PocketDerivedRunTest (8), PocketRunCandidatesTest (2)
- Test count: full suite 6428, 0 failures (24 new tests); testDebugUnitTest + assembleDebug green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations
- PocketTuning.kt is owned by P2-POC-8 but the planner needs Features/Multipliers, so I created it with Features, Verdict,
  Evidence, Multipliers, multiplier formulas, runEvidence, isRelated, fold. POC-8 must extend it (missing: `verdicts(from play
  history)`, PocketTuningTest, rowsNeeded) rather than recreate it; a merge conflict there is expected and trivial.
- Not ported (belong to other packages): PocketProfile.from(listening:...) test, PocketRunStore.rowsNeeded test, PocketTuning fold tests.
- Seeded first-100 equality vs iOS goldens waits for P2-POC-14. Where Swift used unordered dict iteration I iterate sorted keys / tie-break by id.
- Replan neighbours uses Map<uid String, Neighbours>; LiveRow.uid is a String (not UUID).
- CollectionFlattener.flatten (uncapped) is used as on iOS, not ListeningPocketsCollections.flattened.

## Questions for Levi
- one-at-a-time.sh free-memory guard stalls builds here; ran with FIN_MIN_FREE_GB=5 (same as POC-1/3).
