state: in-progress

# P2-REM-8 - Jukebox panel Hero | Remote switch

- [x] JukeboxHubScreen (Hero | Remote switch above content, persisted `jukeboxPanelMode`, flips on session active)
- [x] PocketDjDestination retired "Remote" token -> Jukebox; LastSectionStore flips panel mode on it
- [x] pocketdj://remote and /remote/join/<code> (DeepLink.Remote, dispatcher, RemotePanelRequests)
- [x] RemoteShowcaseSeed + `pdj.seedRemote=showcase` (debuggable only), via DeepLinkDispatcher.handle(intent)
- [x] JukeboxHubModeTest
- [ ] full test + assembleDebug
