state: implemented

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
