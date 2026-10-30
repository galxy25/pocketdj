state: implemented

ANS-BRW-3: Filter clause op change keeps values (iOS FilterSheet parity, Q32).
- [x] ClauseReducer.changeOp = c.copy(op = op); only changeField clears values
- [x] ClauseEditorTest: replaced old drop-values test with 3 keep-values/field-clears tests (13 tests in class)
- Full suite 5598 tests; one unrelated flaky failure under load (ReleaseFeedServiceTest.cachePersistsAcrossRelaunch...), passes in isolation. assembleDebug green.
- Only owned files touched. No manifest/proguard changes (assembleRelease not needed).
