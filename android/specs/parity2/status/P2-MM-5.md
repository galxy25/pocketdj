state: implemented

# P2-MM-5 Mix Mode ph2b: session state in the sequencer, lane driving, swap-on-land hand-off, revert-once

- [x] SwapOnLand.kt: pure `decide` (refusals + owed), position math (clip-relative pass-through, side->cut/side re-base on startMs), HandOffLedger (owed, revert-once fallback, own stamp = URL + song), Runner (runway held to first audio, cap 10 s, superseded/paused re-reads, DSP-direct under Stem Lock with stems)
- [x] NpMixCoordinator.kt: SequencerListener + SessionExtra `npMixMode` (play() from npMixModeDefaultOn, stop clears, held restore arms nothing, Mix-tab suspension, coalesced re-plans, landed-step hand-off, pinned ids, `[npmix] lane step=` trace)
- [x] NpMixWiring.kt: production assembly (settings/device-mode mirrors, network watch, Mix-tab observer, DEBUG broadcast `com.levi.pocketdj.DEBUG --es npmix on|off|toggle`)
- [x] NowPlayingDspHost: `engageForHandOff`, `isEngagedFor`
- [x] Tests: SwapOnLandTest (34 across 4 classes), NpMixCoordinatorTest (24)
- [x] `:app:testDebugUnitTest :app:assembleDebug` green: 6223 tests, 0 failures (+58 new; npmix package 58). assembleRelease not run: no manifest/gradle/proguard/library change.

## Summary
Mix Mode is now a live session feature. Toggling it (debug broadcast now, the chip with P2-MM-6) re-plans the shared prefetch lane with the generalised Mix Mode plan (window = npMixBufferAhead, cellular policy, disk guard bound to StorageManager). When the playing row's `.song` step lands while it plays the presigned stream of the same rip, ExoPlayer's current item is replaced with the local file and seeked to the same song-relative position without ever touching playWhenReady (so no pause event, no start of audio). Refused (and owed, retried on first audio / user PLAY / Mix tab idle) when paused, focus lost, start window open, Mix tab live. A failing local file reverts once to the stream; second failure advances.

## Deviations / files touched outside owned set
- PlaybackController.kt (touchpoint): `handOffPlaying`, `enginePlayWhenReady`, `swapCurrentItem`, `awaitHandOffAudio`, `handOffFailed` hook in onPlayerError, first-audio completer. Positions are clip-relative on Media3 (ClippingConfiguration), so the "side->cut re-base on startMs" is a no-op in production (`positionIsClipRelative=true`); the re-base math exists and is tested for file-absolute engines.
- Hand-off while PAUSED is REFUSED (roadmap), unlike iOS which reloads paused; it is owed and retried on the next PLAY.
- PlaybackGraph.kt (touchpoint): `npMix` lazy + install before the held restore.
- NPLog.kt (touchpoint): `NPMIX = "npmix"` const; NOT added to `LANES` (DiagLogTest pins 11).
- MixGraph.kt (not in owned/touchpoints, minimal): `replanStemLock` now branches on `npMix.coordinator.buffering` (Mix Mode off path unchanged, same legacy call); lane fetches use `AssetOrigin.Buffer` for songs and stem parts (iOS: the lane is `.buffer`; this makes Stem-Lock-only prefetches temporary holds like iOS); `pendingDownload` bound to BurnStore ledger; DiskGuard bound to `temporaryFootprintBytes` / buffer cap / `sweepForDiskGuard` (one retry on a dropped sweep); `pinnedIds += npMix.pinnedStreamIds()`; `onStepFinished` also calls the coordinator.
- SwapOnLand.Runner keys the runway to first audio via `PlaybackController.awaitHandOffAudio` (sequencer's own onFirstAudio fires once per start, so it can't end this runway).
- DJ Mode / FX Lock "carry" hooks of iOS handOff are not present on Android yet (other packages): only the Stem Lock stems case engages the DSP.
- ports `isRipServerConfigured=false` in the production plan (see questions): no rips / cloud stemify from the Mix Mode lane yet.

## Questions for Levi
- Who may trigger rip-server work from the Mix Mode lane on Android (Apple-Music-only rips, cloud stem separation)? MM-4 gated it on "rip server configured + install may use it"; there is no ownership notion on Android yet, so the lane passes false (nothing server-side is requested) until decided (needed by P2-MM-9).
- Stem-Lock-only buffering is now `AssetOrigin.Buffer` (temporary hold, expires per npMixBufferTTLHours) as on iOS; before this package those prefetches were permanent burns. Confirm that's wanted for Android.

## Emulator steps (integrator)
Seed rip playlist, play, `adb shell am broadcast -a com.levi.pocketdj.DEBUG --es npmix on`, `adb logcat -d -s PocketDJ.npmix` for `lane step=`, `hand-off row=`, `hand-off refused reason=paused`.
