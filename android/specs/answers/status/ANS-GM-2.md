state: merged

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

## Review
- MINOR recommendationsEnabled proxy race: fixed (holder mirrors the target into a StateFlow; captured flow follows a later-wired target). Test recommendationsEnabledObservesLateWiredTarget.
- MINOR endless spinner on null bridge: fixed (10 s timeout falls back to NoPocketsBridge; iOS "isn't available" branch restored for NoPocketsBridge && !enabled; a late real bridge still wins). Wiring-side try/catch in CollectionsGraph not added (screen-side fallback covers it).
- MINOR vacuous GamesGraphBridgeTest: fixed (late-target race, parsePocketsEnable, inert-bridge, timeout-bound tests added).
- NIT pocketsStub parsing: fixed (shared GamesGraph.parsePocketsEnable used by both extras). Note: emulator recipe `-e pdj.pocketsStub true` now also needs Recommendations enabled.

fixes applied
