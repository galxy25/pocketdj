state: reviewed

ANS-BRW-3: Filter clause op change keeps values (iOS FilterSheet parity, Q32).
- [x] ClauseReducer.changeOp = c.copy(op = op); only changeField clears values
- [x] ClauseEditorTest: replaced old drop-values test with 3 keep-values/field-clears tests (13 tests in class)
- Full suite 5598 tests; one unrelated flaky failure under load (ReleaseFeedServiceTest.cachePersistsAcrossRelaunch...), passes in isolation. assembleDebug green.
- Only owned files touched. No manifest/proguard changes (assembleRelease not needed).

## Review
- MINOR (IN_LIST -> EQ leaves empty value, engine/online disagree): fixed. ClauseReducer.changeOp seeds `value` from `values.firstOrNull()` when moving to EQ/NEQ with an empty value; values still kept. Test listToEqSeedsValueFromFirstListValue added (suite 5598 -> 5599, 0 failures).
- NIT (emulator step): Android has no >/< ops; adapted step is BPM "is" 120 -> "is not" keeps 120. NOT run on emulator (shared, integrator owns); covered by reducer unit tests only.

fixes applied
