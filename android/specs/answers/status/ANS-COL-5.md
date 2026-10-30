state: implemented

# ANS-COL-5 Favorites ratings pull paginated + Failed list paginated

- [x] Pull paginated: 20 batches x 250 per pass from persisted PULL_CURSOR (pref "favoritesPullCursor"), wraps; local hearted + pending ids always included; failed/rate-limited page leaves cursor unchanged
- [x] Only the page reconciled (absence != unfavorite kept); lastSyncedAtMs per page; State.pullDone/pullTotal exposed and shown as "Checked x of y songs this lap" in Settings
- [x] Failed write-back list shows 20 rows + "Show all (N)"
- [x] 5 new tests in FavoritesSyncServiceTest (total JVM tests 5278, 0 failures)

Notes: locally-hearted extras can add batches beyond 20 (bounded by local favorites). Cursor is an index into catalog sorted by songId. No files outside owned set touched. Build needed `--no-daemon -Pkotlin.compiler.execution.strategy=in-process` due to machine memory pressure (no repo change).
