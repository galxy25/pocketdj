state: implemented

# P2-REM-7 - Remote screen UI

- [x] ParityFlags.REMOTE = false (shared touchpoint; the hub P2-REM-8 gates the Remote half on it, P2-REM-9 flips it)
- [x] RemoteViewModel.kt: `RemoteSessionStarter` seam (+ `RemoteStarters.current`, `None`), pure `RemoteSearch` (cap 25, min 2 chars, 250 ms debounce, case/diacritic fold), `RemoteJoinCode.parse`, `RemoteQueueUi` (upcoming, reordered, dragTarget, strings), `RemoteViewModel` (every control -> RemoteCommand via the controller; never the local player)
- [x] RemoteComponents.kt: peer row/badges, transport row, scrubber (one seek on release), start cards, Up Next list (menu Play Now/Next/Remove, drag handle -> reorder), search row menu
- [x] RemoteScreen.kt: start cards + footer, Join (code/link field, nearby hosts with confirm), invite QR + code (reuses JukeboxQrCard), active: status, paused-here card + Rejoin, Session (Speaker / Remote control chips, Leave), Participants, Now Playing + repeat/shuffle, Up Next, Add Songs
- [x] testTags: remote-view, remote-playpause, remote-prev, remote-next, remote-peer-<id> (+ remote-start-*, remote-rejoin, remote-leave, remote-role, remote-search, remote-add-<songId>, remote-upnext-*)
- [x] 18 new JVM tests; suite 7277 total, 0 failures; assembleDebug OK. assembleRelease not run (no manifest/gradle/proguard/library change).

## Summary
The Remote half of the Jukebox panel, hidden behind `ParityFlags.REMOTE`. `RemoteScreen()` is a hostable composable (no app bar of its own). Start/Join go through the new `RemoteSessionStarter` interface that P2-REM-9's Nearby transport implements and installs into `RemoteStarters.current`; until then Start is disabled with an explanatory footer.

## Deviations / files outside the owned list
- ParityFlags.kt only (declared shared touchpoint).
- "Scan" is the system camera app via the `pocketdj://remote/join/<code>` link (as the audit's R3 design says); no in-app camera scanner (would add CameraX/ML Kit + CAMERA permission). The code field also accepts a pasted link.
- Mix Together section (R11) is not here (P2-REM-12/13). No album thumbnails on rows (text only).
- Drag-reorder sends `Reorder(<full upcoming rid order>)` (not iOS `Move`), per acceptance.
- Emulator step (remote-next advancing the in-memory speaker) not run: emulator not used by this package; the same path is covered by `aRemoteNextAdvancesTheHostNotTheLocalPlayer` over LoopbackHub.

## Questions for Levi
- None.
