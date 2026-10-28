state: reviewed

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

## Review
fixes applied
- MAJOR ledger row COL-18 -> fixed (PARTIAL, JVM-only, Noop provider, no Settings toggle; test androidLedgerRowIsNotPlanned)
- MINOR play source -> fixed (SOURCE_SETLIST as iOS). Opening Now Playing after Play not wired: no nav seam in History; noted in ledger
- MINOR ANSWERED migration -> fixed (stored ENABLED => answered, one-time at startup; debug hook sets ANSWERED; test answeredMigration)
- MINOR opt-in flash -> fixed (null initial, render nothing until known)
- MINOR hardcoded Noop provider -> fixed (CollectionsGraph.listeningContextProvider, shared with service)
- MINOR localized dates / 24h -> fixed (getBestDateTimePattern skeletons, is24HourFormat; injectable for tests)
- MINOR tzOffset crash -> fixed (zoneFor range check; test corruptOffsetFallsBackToDeviceZone)
- NIT tautological assertion -> fixed
- NIT stale pocketKey -> fixed (cleared when it resolves to nothing); serviceAvailable stays a plain var (rejected: no observable-state change needed for correctness)
Tests: 5075 -> 5079, 0 failures; assembleDebug OK.
