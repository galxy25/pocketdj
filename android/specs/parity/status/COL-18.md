state: implemented

# COL-18 - History > Pockets screen

- [x] ListeningPocketLabeler (provider > cloud snapshot > feature label > "Earlier place"; collectionNames local-only; chips/bpm/when/last text)
- [x] ListeningPocketsScreen (Recurring / Recent newest-first, stale banner, pull-to-refresh -> refreshNow, empty + "Pockets aren't available yet.", opt-in offer)
- [x] ListeningPocketDetailScreen (What defines it / When & where / songs; Play via shellActions.playSongIds source "pocket"; Save as playlist -> collections.createPlaylist(title, songIds))
- [x] HistoryScreen: Pockets tab gate wired (rec engine AND pockets ON, or once as unanswered opt-in offer), detail hosted in History, search row hidden on Pockets
- [x] Tests: ListeningPocketLabelerTest (8), PocketsTabGateTest (6) = 14 new; full suite 5075 tests, 0 failures; assembleDebug OK

## Notes / deviations
- Touched outside owned files (additive): PocketsSettings.LISTENING_POCKETS_ANSWERED (iOS listeningPocketsChoice != nil); CollectionsGraph opt-in `choose` also sets ANSWERED; PocketsOptInView gained optional title/lead params.
- With a location engine ACTIVE the device is authoritative (unknown id -> "Earlier place", as iOS); cloud snapshot is used when no engine is active (always, on Android today - Noop provider). This matches iOS and the practical acceptance order.
- Opt-in "Not now" leaves pockets off; the Settings toggle (not in this package) should also set ANSWERED when it flips.
- Not emulator-verified (forbidden here).

## Questions for Levi
None.
