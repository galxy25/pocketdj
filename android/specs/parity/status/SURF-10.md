state: reviewed

# SURF-10 Jukebox host parity gaps
- [x] Played dedup (JukeboxPlayedDedup, wired in JukeboxRepository.derivePlayed)
- [x] Settings > Jukebox "Require access tokens by default" (JukeboxSection, order 510, registered in ShellGraph); create view seeds from it
- [x] listSessions/sessionInfo (client + URLs), repository adopt() with guard, listSessions()
- [x] Default session name "<PocketDJ name>'s Jukebox" (repository + create-view placeholder)
- [x] Seams JukeboxPlacementSink / JukeboxExternalMatch (default no-op), wired but inert
- [x] Tests: 15 new (1635 total, 0 failures); assembleDebug green

## Notes
- PlayedEntry moved from JukeboxRepository nested to top-level JukeboxPlayedEntry (models file).
- JukeboxGraph.kt (not in owned list) touched additively to pass pocketDjName provider.
- adopt() has no UI caller yet (no sessions picker screen in this package); device-only: AM catalog match stage.
- JukeboxUrlsTest extended instead of a new file.

## Questions for Levi
- None.

## Review
- MAJOR ledger row (ARCHITECTURE-ANDROID.md) -> fixed: SURF-10 now PARTIAL with device-only AM search stage and adopt() having no picker UI noted.
- MINOR adopt/start vs bootstrap race -> fixed: commitLock + commitIfFree re-check before persist/commit; bootstrap yields when starting; start aborts (best-effort end) if a session appeared. Test: JukeboxRepositoryAdoptTest.
- MINOR placementSink throw -> fixed: try/catch (rethrow cancellation), falls back to applyPlacement queue edit. Not unit-tested (needs a full catalog/rips match fixture).
- MINOR runCatching swallowing cancellation in computeMatch -> fixed: explicit try/catch rethrowing CancellationException.
- MINOR missing repository adopt tests -> fixed: 4 repository-level tests (persist, hear=false, since=0 poll, 404 clears starting + notice, refuse when other active, bootstrap race consistency). rewind test: rejected as a distinguishing case (JukeboxOnAir has no position, so rewind and tick are identical to the reducer by design); renamed with comment.
- NIT JukeboxGraph -> fixed: import OnboardingPrefs, one-line provider; touchpoint noted (SURF-11 must keep pocketDjName).
- NIT @Volatile seams -> fixed.
- Tests: 1639 total, 0 failures (was 1635, +4); assembleDebug green.

fixes applied
