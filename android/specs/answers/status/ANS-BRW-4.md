state: implemented

# ANS-BRW-4
- [x] "Find my listening pockets" SwitchRow (writes ANSWERED=true then ENABLED) shown when recs on, consent text when off, pockets sync error when on (polled 1s; syncError is a plain field)
- [x] RecommendationsSectionTest (4 tests); full suite 5415 tests, 0 failures

Notes: only owned files touched. Build needs -Pkotlin.daemon.jvmargs=-Xmx6g under load.

## Questions for Levi
None.
