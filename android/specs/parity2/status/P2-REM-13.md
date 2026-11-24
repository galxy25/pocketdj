state: in-progress

# P2-REM-13 Mix Together live

- [x] MixSync.kt: driver over MixSyncCore (gestures -> proposals, anchored starts, drift, held decks, readiness, heartbeat), MixEnginePort, MixTogetherInstaller
- [x] ParityFlags.MIX_TOGETHER (true), RemoteGraph wiring, system-cause wrapping of the lock-screen/headset/focus transport
- [x] MixTogetherSection.kt + MixTogetherBanner.kt, RemoteScreen/MixScreen mounts
- [ ] MixSyncDriftTest green, full suite, assembleDebug
