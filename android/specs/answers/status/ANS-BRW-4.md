state: merged

# ANS-BRW-4
- [x] "Find my listening pockets" SwitchRow (writes ANSWERED=true then ENABLED) shown when recs on, consent text when off, pockets sync error when on (polled 1s; syncError is a plain field)
- [x] RecommendationsSectionTest (4 tests); full suite 5415 tests, 0 failures

Notes: only owned files touched. Build needs -Pkotlin.daemon.jvmargs=-Xmx6g under load.

## Questions for Levi
None.

## Review
- MINOR tests trivial -> fixed: extracted pure pocketsRows(recOn, pocketsOn, err) consumed by the composable; 3 tests pin hidden-when-recs-off, consent, error-only-when-on
- MINOR write ordering -> fixed: pockets writes serialized by a Mutex (last tap wins); test added
- NIT consent flash / idle poll -> fixed: nullable initial state (no consent until first emission); poll only while pockets on. syncError StateFlow left as follow-up (file not owned)

fixes applied. Suite 5419 tests (was 5415), 0 failures; assembleDebug OK.
