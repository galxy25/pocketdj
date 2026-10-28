state: reviewed

# GM-9 Music with Friends link, models, client, join secret, session file, store

- [x] MwFLink (string-based parse, no android.net.Uri so JVM-testable)
- [x] MwFModels (all-optional wire types + MwFSessionEntry, iOS field names)
- [x] MwFClient (OkHttp; 12 s / 30 s create+end / 6 s unregister; MwFException(code, decoding))
- [x] MwFJoinSecret (+ MwFKeyValue seam; SharedPreferences "pdj-mwf" in GamesGraph)
- [x] MwFSessionFile (atomic pocketdj-mwf-sessions.json)
- [x] MusicWithFriendsStore (StateFlows; MwFHost / MwFQueueSink seams)
- [x] GamesGraph wiring (`friends`, `mwfClient`, `mwfJoinSecret`, reset hook)
- [x] Tests: 39 new (MwFLinkTest 8, MwFClientTest 9, MusicWithFriendsStoreTest 22); suite 3167 green; assembleDebug OK

## Deviations
- MwFClient has its own `/health` probe (JukeboxHealth has no `mwf` field and is not my file).
- Push (register/unregister device + store hooks) not ported: broker speaks APNs only; client methods exist.
- downloadCollection: Android has no provisional-song materialization, so unresolved entries are only counted (MwFDownloadResult.unresolved).
- queueMatchIfPlayable: AM-only matches (no catalog songId) are not queued (no Android AM playable rung).
- Join secret / scored set / queueAccepted live in SharedPreferences "pdj-mwf" (not DataStore) behind MwFKeyValue.
- MwFModelsTest from the roadmap folded into MwFLinkTest.
- `host.profileName()` in GamesGraph returns "" (recovery falls back to "Player"); GM-10 UI can wire the real name.

## Questions for Levi
- none

## Review
fixes applied
- MINOR approve() main-thread match + unguarded external matcher -> fixed (withContext(Dispatchers.Default); external.match try/catch, CancellationException rethrown). Test: approveMatchesOffCallerThreadAndSurvivesExternalMatcherThrowing.
- MINOR disk IO on caller thread / unsynchronized session file -> fixed (`friends` warmed on IO in GamesGraph.init; MwFSessionFile load/save/delete @Synchronized).
- MINOR recovery always "Player" -> fixed (mwfDisplayName persisted at create/join, cleared on eraseAll; recovery uses it, then lastState member name, then profileName, then "Player"). Test: recoveryReusesRememberedDisplayName.
- MINOR ledger row -> fixed (docs/ARCHITECTURE-ANDROID.md GM-9 row set DONE with deviations).
- NIT re-download count / empty pocket -> fixed (MwFHost.pocketSongIds; added counts only new songs; no pocket when nothing resolves). Test: redownloadReportsOnlyNewSongsAndEmptyCollectionMakesNoPocket.
- NIT per-route timeouts -> fixed (callTimeoutsPerRoute asserts 30/12/30/6 s via interceptor).
- Tests: 3167 -> 3171, 0 failures; assembleDebug OK.
