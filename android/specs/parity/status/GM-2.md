state: implemented

# GM-2 Gem Collector core (pure)

- [x] PlayRecency, PuzzleSettings (lenient per-field serializer, iOS wire tokens, summaryLine)
- [x] PuzzleSampler (RawInputs -> Inputs.fromRaw, pool/poolStats/poolCount/sample), PuzzleCandidate
- [x] PuzzleSimilarity (default non-balanced path; SimilarityFamilies balance mode intentionally not ported - In Da Zone only)
- [x] PuzzleDecisionStore (coalesced writer, write generation, flush/flushAsync, union reload, 20k cap, recordBatch)
- [x] PuzzleRecEventBridge + RecPuzzleEventWire
- [x] Tests: PlayRecency, PuzzleSettings, PuzzleSampler (incl. playability), PuzzleSimilarity, PuzzleDecisionStore, PuzzleRecEventBridge

## Notes / deviations
- Enum names are UPPER_CASE Kotlin constants carrying iOS wire strings (Bias.FAVOR, MembershipMode.IN_ANY, Similarity.STRICT).
- Decision ids/roundIds are uppercase UUID strings (iOS shape); reload dedupes case-insensitively.
- PuzzleDecisionStore takes (file, scope, writeContext): production should pass the Games mainScope and Dispatchers.IO; tests use virtual time.
- RecPuzzleEventWire lives in PuzzleRecEventBridge.kt (no GameKind yet; GAME_ID const = "collectorsPuzzle"). GM-1/rec package may move it.
- Extra test-only file: PuzzleTestFixtures.kt. No files outside owned set touched.
