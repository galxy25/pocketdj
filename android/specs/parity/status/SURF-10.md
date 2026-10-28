state: implemented

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
