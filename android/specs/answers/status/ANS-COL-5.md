state: reviewed

# ANS-COL-5 Favorites ratings pull paginated + Failed list paginated

- [x] Pull paginated: 20 batches x 250 per pass from persisted PULL_CURSOR (pref "favoritesPullCursor"), wraps; local hearted + pending ids always included; failed/rate-limited page leaves cursor unchanged
- [x] Only the page reconciled (absence != unfavorite kept); lastSyncedAtMs per page; State.pullDone/pullTotal exposed and shown as "Checked x of y songs this lap" in Settings
- [x] Failed write-back list shows 20 rows + "Show all (N)"
- [x] 5 new tests in FavoritesSyncServiceTest (total JVM tests 5278, 0 failures)

Notes: locally-hearted extras can add batches beyond 20 (bounded by local favorites). Cursor is an index into catalog sorted by songId. No files outside owned set touched. Build needed `--no-daemon -Pkotlin.compiler.execution.strategy=in-process` due to machine memory pressure (no repo change).

## Review
fixes applied
- MINOR unbounded page cap -> fixed: fixed budget of 20x250 distinct ids per pass; local/pending ids first (capped at half budget, rest covered by the lap), remainder from cursor. Test: 600 off-page favorites, GETs <= 20.
- MINOR index cursor drifts -> fixed: cursor is the last covered songId (pref favoritesPullCursorId, binary search resume, "" = lap start). Test: ids inserted before the cursor do not shift resume.
- MINOR in-memory pullDone/pullTotal -> fixed: loadProgress() seeds from persisted cursor (Settings LaunchedEffect); cleared when two-way is off; caption shown only when two-way is on.
- NIT baseline count -> baseline 5278, now 5282 (+4 tests added in review; 0 failures).
- NIT duplicate AM ids -> fixed: ids deduped so repeats take no slots; test added.
