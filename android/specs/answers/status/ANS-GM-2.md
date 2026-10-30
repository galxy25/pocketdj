state: implemented

# ANS-GM-2 - Remove the In the Pocket debug stub path

- [x] GamesGraph: stubEnabled/debugBridge/stubOptIn/debugRecsEnabled deleted; pocketsBridge = servicesBridge ?: NoPocketsBridge
- [x] pdj.pocketsStub now aliases pdj.pocketsEnable (real LISTENING_POCKETS_ANSWERED/ENABLED settings writes); pdj.pocketsRecsOff removed (opt-in uses real recEnabled)
- [x] PocketsServiceHolder (pure): observable bridge + opt-in proxy that replays a pre-wiring choice
- [x] InThePocketScreen: loading spinner (itp-loading) until servicesBridgeFlow is set
- [x] Stale comments fixed (ListeningContext, PocketsBridge, InThePocketStore, PocketsOptInView, DebugScreen)
- [x] GamesGraphBridgeTest (3 tests)

Notes: build needed -Pkotlin.daemon.jvmargs=-Xmx4g (machine under parallel Gradle load; OOM otherwise).
Touched only owned files. Release build with no bridge shows loading rather than "isn't available".
## Questions for Levi
None.
