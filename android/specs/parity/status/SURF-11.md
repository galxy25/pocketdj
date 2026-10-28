state: reviewed

# SURF-11 — Jukebox guest (JukeboxLink, joined list, join panel, Tune In)

- [x] JukeboxLink (3 iOS forms, strict id, stateUrl fallback), parseLoose for manual join
- [x] JukeboxGuestState (lenient per-array decode, updatedAt, isMine, canTuneIn) + TuneInSeekMath
- [x] JukeboxGuestClient (cache-busted state read, 404/410 Ended, 429 RateLimited, submit {title,artist,clientId}, apiBase fallback)
- [x] JoinedSessionsStore (iOS-shaped JSON, sync in-memory + serialized persistence, own DataStore file)
- [x] JoinedSessionsStrip, JukeboxJoinScreen (4 s poll while composed, Tune In/re-tune via PlaybackController.playUrl, Leave), "Join by link or id" dialog on Jukebox tab
- [x] Wiring: deepLinkSeams.joinJukebox (ShellGraph), JUKEBOX_JOIN_ROUTE + resolver lookup (ShellNavigation)
- Tests: 60 new (JukeboxLink 23, JoinedSessionsStore 9, TuneInSeekMath 9, GuestClient 11 via MockWebServer, GuestStateDecode 8); suite 3188 green, assembleDebug OK.

## Files touched outside owned list
- shell/ShellNavigation.kt: JUKEBOX_JOIN_ROUTE/jukeboxJoinRoute, pushRouteFor(JukeboxJoin), GraphRouteLookup.jukeboxSessionJoined, title, composable (additive).

## Deviations
- state.json never publishes request clientId (server leaks none), so "mine" = clientId match if ever present, else request ids returned by our own submits, else title|artist key (iOS behaviour).
- JoinedSessionsStore lives on its own DataStore file, reachable via JukeboxGraph.joinedSessions(ctx) without constructing the player-bound JukeboxGraph (deep link/resolver safe).
- Tune In stop uses PlaybackController.stop() (stops whatever the controller plays; only called when we started the stream).

## Questions for Levi
- Tune-in seek trusts guest clock vs server updatedAt; large clock skew is only clamped to [0,length]. Fine, or use the HTTP Date header?

## Review
- MAJOR Stop button didn't stop audio -> fixed: entry-scoped JukeboxTuneIn.stop() stops the stream; test stopButtonStopsTheStream.
- MAJOR stop() wiped held queue / stopped foreign audio -> fixed: PlaybackController.stopUrl(url) only stops when mediaId == "url:"+url, never abandons a run; tests onlyTheTuneInItemIsStoppable.
- MAJOR stop on composition dispose / not saved across recreation -> fixed: tune-in state lives in a ViewModel scoped to the nav entry; stops on Stop/Leave/ended/entry pop (onCleared), not on dispose; test poppingTheEntryStopsButRecompositionDoesNot.
- MAJOR JoinedSessionsStore load/persist race -> fixed: load and persist serialize on writeLock and persist merges disk first; tests writeBeatingTheLoadKeepsPersistedSessions, readLandingBeforeWriteStillMerges.
- MINOR seekMs null position -> fixed: returns 0; elapsed capped at 5 s; tests updated/added.
- MINOR status ledger -> fixed: SURF-11 row DONE (emulator steps not run), SURF-4 joinJukebox note updated.
- MINOR Join by link in LiveView -> fixed: strip shown when hosting a live session.
- NIT poll keyed on link, myIds/myKeys saveable -> fixed.

Tests 3188 -> 3196, 0 failures; assembleDebug OK.
fixes applied
