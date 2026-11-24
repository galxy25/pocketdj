state: implemented

# P2-REM-8 - Jukebox panel Hero | Remote switch, remote links, retired token, showcase seed

- [x] JukeboxHubScreen: Hero | Remote segmented switch pinned above the child (child scrolls under it); `jukeboxPanelMode` persisted ("Jukebox Hero"/"Remote"); flips to Remote when a session goes active; switch + Remote half hidden until ParityFlags.REMOTE
- [x] PocketDjDestination.fromToken("Remote") -> Jukebox; LastSectionStore.restore also sets the panel to Remote on that token
- [x] `pocketdj://remote`, `pocketdj://remote/join/<code>` -> DeepLink.Remote -> Jukebox tab + RemotePanelRequests (parked until the hub consumes; joins via RemoteStarters.current)
- [x] RemoteShowcaseSeed + DEBUG `--es pdj.seedRemote showcase`: this device = Backseat controller over LoopbackHub, in-memory "Car" speaker playing the set 1:37 in; hub shows Remote while the seed runs even with the flag off
- [x] JukeboxHubModeTest (11 tests); full suite 7467 tests, 0 failures; assembleDebug OK. assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations / files outside the owned list
- Touched shared: ShellNavigation (host JukeboxHubScreen), DeepLinkParser, DeepLinkDispatcher (new `wantsRemoteShowcase` ctor param, default off), di/ShellGraph.kt (passes it; not a listed touchpoint, additive).
- DebugScreen not touched (seed is intent-driven). Switch is pinned atop the panel content, not inside the shell TopAppBar (the bar is shell-owned and shared by all tabs).
- Wrapper refused `--no-quiesce-fin` (LM Studio models loaded); ran with default quiesce.
- Emulator step not run (emulator not used).

## Questions for Levi
- None.

Summary: implemented; JVM suite 7467 tests (11 new in JukeboxHubModeTest), 0 failures.
