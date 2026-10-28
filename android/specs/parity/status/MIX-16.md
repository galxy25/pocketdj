state: implemented

# MIX-16 Integrations: Jukebox <-> Mix, MixPlayOutcomeBridge, MixFacadeImpl
- [x] MixPlayOutcomeBridge (deck-keyed, async event resolution, verdict table)
- [x] MixJukeboxSource + MixJukeboxPort + MixJukeboxSeam; JukeboxRepository prefers the live mix (snapshot, placement, pending drain)
- [x] MixFacadeImpl + MixGraph wiring (bridge hooks, jukebox seam, facade; ports shared with mixViewModel)
- [x] Tests (37 new: bridge 19, source 10, facade 7, repo 1), specs/mix.md
- Suite: 4204 tests, 0 failures; assembleDebug green.

## Deviations / notes
- docs/ARCHITECTURE-ANDROID.md NOT edited (integrator owns it, per instructions): open question #1 resolve + ledger row + new files are left for the integrator.
- Touched outside owned files (minimal): di/ShellGraph.kt (one `.also { it.mixFacade = ... }`), screens/mix/MixViewModel.kt (MixAutoStarter single-crate empty guard, iOS parity).
- Event-id resolution is polled (store records async off the bus) instead of iOS's synchronous record() return.
- JukeboxGraph untouched: repository finds the Mix via process-wide MixJukeboxSeam set in MixGraph.init.
- Jukebox `nowPlaying.positionMs` is sent for the mix (iOS sends nil); guests interpolate from it.
- Emulator steps (broker payload via logcat, History tag) not run: emulator owned by integrator.

## Questions for Levi
- None.
