# Parity 2 audit — Playback (Now Playing + playback engine)

Audited 2026-11-23 against `main` @ 4bcd08db (Android 1.0.0 live on Play, built from main 2026-11-05).
Scope: DJ Mode, NP Mix Mode, FX Lock, Stem Lock, stall-hop / ping-pong / stall-episode (FR1), stale-card /
release, dead-air metric, repeat/shuffle, durable sessions, vinyl album-side playback (the playback half),
plus older playback partials still open. Both code bases were read; every claim below cites files.

Paths: iOS = `apple/PocketDJ/…`, Android = `android/app/src/main/java/com/levi/pocketdj/…` (abbreviated `A/`).

## 0. Summary

| # | Feature | Android | Feasibility | Est. lines | Value |
|---|---|---|---|---|---|
| P1 | NP Mix Mode ph.1 — temporary-vs-pinned buffer assets, 48 h expiry sweep, cap, Storage UI | missing | direct | 900 | high |
| P2 | NP Mix Mode ph.2 — toggle + status chip + buffer strip, one prefetch lane (generalised Stem Lock lane), swap-on-land hand-off, settings | missing | direct | 950 | high |
| P3 | NP Mix Mode ph.3 — the NP DSP plays the growing buffer file (start + touch hand-off + fallbacks) | missing | direct | 750 | high |
| P4 | NP Mix Mode ph.4 — Apple Music rows: prefer local rip, rip-ahead (own rip server only), touch hand-off AM→local | missing | equivalent | 500 | medium |
| P5 | Stem Lock edition rule A (vocals muted ⇒ play base cut + stems) + edition-aware buffer dots | missing | direct | 200 | medium |
| P6 | FX Lock | missing | direct | 380 | high |
| P7 | DJ Mode session state, settings (Settings ▸ Mixing), chip/menus, snapshot | missing | direct | 500 | high |
| P8 | Shared `AutoTransition` (pure transition math shared with Mix Auto-DJ) | partial | direct | 300 | high (enabler) |
| P9 | DJ transitions in Now Playing: tail deck + conductor + advance-at-fade-start + hand-back | missing | equivalent | 1200 | high |
| P10 | DJ skip mix (⏭ tap = Skip fade, double-tap / system ⏭ = 5 s) | missing | direct | 260 | high |
| P11 | PocketDJ selector `DJSetPlanner` (waves, pockets, key, artist spacing, aging) + re-plan + next-up pick | missing | direct | 850 | high |
| P12 | Loudness leveling (BS.1770, −14 LUFS, −12…+6 dB, 2 s ramps) + cache | missing | direct | 650 | high |
| P13 | Progressive on-device analysis (20 s hints → finals: BPM / key / loudness) + scheduler | missing | direct | 600 | medium |
| P14 | DJ automation display (controls move) + leveling readout | missing | direct | 260 | medium |
| P15 | Stall EPISODE (no ping-pong back to an abandoned row) | missing | direct | 90 | high |
| P16 | FR1 on Android: cancelled Apple Music start can take over the hop target (BUG) | partial | direct | 70 | high |
| P17 | Vinyl album run plays the side end to end (end rule, glide, in-place skips, lead-in) | missing | direct | 650 | medium |
| P18 | Durable snapshot: new optional fields + preserve unknown iOS keys on re-encode | partial | direct | 160 | high |
| P19 | Pocket-run sequencer hooks (`replaceUpcoming`/PlanTag, repeat forced off, `Row.plan`, Re-tuned) | missing | direct | 300 | medium (owned with pockets area) |
| P20 | NP 👍/👎 feedback row | missing | direct | 60 | low |
| P21 | Stale MusicKit card / release on leaving AM | present (structurally) | — | 0 (+test) | — |
| P22 | Dead-air meter | present | — | +20 (DJ/npmix causes) | — |
| P23 | Repeat/shuffle (+ reshuffle on wrap) | present | — | covered by P11/P19 | — |
| P24 | Stem Lock (F4 panel + lock + prefetcher) | present | — | base for P2/P6 | — |

Total new playback work ≈ 9,600 lines (excluding tests; iOS ships ~1 test line per code line here — budget the same).

## 1. Ground truth: what Android already has (reuse, don't duplicate)

- **Sequencer**: `A/playback/sequencer/SetlistSequencer.kt` (1641 l) — cursor queue, the ONE start funnel
  `startPlayCurrent` → `playCurrent` (lazy job + `playGeneration` claimed after `isActive`, `owns(gen)` after each await),
  live edits, repeat/shuffle (`setRepeatMode`, `setShuffle`, `canonicalOrder`, `reshuffleEntireQueue` on wrap),
  stall hop (`hopToPlayableRow`, `armResolveStall`), start watchdog, cascade breaker, supervisor hooks.
- **Stall hop pure**: `A/playback/health/ResolveStallHop.kt` (`choose`/`apply`, STALL_MS 6000, LOOKAHEAD 50).
- **Dead air**: `A/playback/health/DeadAirMeter.kt` (string causes, `transitionBegan/firstAudio/transitionAbandoned`).
- **Engine glue**: `A/playback/PlaybackController.kt` (`Media3Port.load`, `loadAppleMusic`, `stopAppleMusic`), `A/playback/PlaybackService.kt`,
  `A/playback/session/{SessionSwitchboard,SequencerForwardingPlayer,AppleMusicPlayerAdapter}.kt` (one MediaSession, owner switch).
- **NP DSP (F4) + Stem Lock** (MIX-18, merged): `A/mix/nowplaying/NowPlayingDspEngine.kt` — a PRIVATE `MixGraph` using
  **deck A only, crossfader pinned 0** (`ParamsComposer(graph).setCrossfader(0f)`), file-based `engage(file,startMs,lengthMs,…)`,
  4 Hz `tick()` from the host heartbeat, generation discipline (`handoverGen++` before `stop()`), effects slots + strength,
  stems handover. `NowPlayingDspHost.kt` (swap-on-touch, `onTrackStarted`, `carryIfReady`, `applyLockOnTrackStart`),
  `NowPlayingDspSessionPlayer.kt` (DSP as TransportOwner), `StemLock.kt` (`StemLockState`, `StemLockSession`, iOS JSON),
  `StemLockPrefetcher.kt` (pure `plan` + one-at-a-time worker; Network UNMETERED/EXPENSIVE/CONSTRAINED/OFFLINE).
- **Mix pieces reusable by DJ**: `A/mix/model/MixMath.kt` (`octaveFolded`, `syncRate`, `signedCamelotSteps`, glide params,
  `SplitMix64`, `splitmix64`, `rollTexture`, `fxSeed`, headerless-mp3 rule), `A/mix/engine/PhaseAlignMath.kt`, `A/mix/engine/GlideMachine.kt`,
  `A/mix/graph/RenderParams.kt` (equal-power `crossfadeFactor`, per-deck `trimDb` untouched by crossfader moves),
  `A/mix/stream/MixStreamLoader.kt` (growing-file song + stem streams, `StreamAdopter` → `BurnStore.adoptStreamedFile/Stems`),
  `A/mix/engine/StreamDecks.kt` (growing-file playback on Mix decks), `A/mix/MixSettings.kt` (lead 15 / fade 3 / skipFade 15 / glide 10, iOS key names).
- **Analysis code**: `A/studio/demux/{BeatDetect,KeyDetector,Chromagram}.kt`; helpers `A/data/recs/RecIdentity.kt#creditArtistKeys`,
  `A/data/recs/SimilarityFamilies.kt#camelotRelatedness`, `A/screens/browse/Genre.kt#category`,
  `A/data/games/inthepocket/InThePocketScorer.kt#foldBpm`, `A/data/pockets/ListeningPocketsCollections.kt` (flattened membership).
- **Storage**: `A/data/storage/StorageManager.kt`, `A/data/burns/{BurnStore,EvictionPlanner,BurnFolder}.kt`, `A/screens/settings/sections/StorageSection.kt`.
- **Durable session**: `A/playback/durable/SessionSnapshot.kt` (iOS shape v1: rows, repeat/shuffle, `stemLock`), synced as
  `"playback-session"` (`A/di/PlaybackGraph.kt:120`).

Nothing for DJ Mode / Mix Mode / FX Lock / loudness / temporary holds / album runs / stall episodes exists
(grep for `fxlock|djmode|mixmode|loudness|setplanner|artistSpacing|stallEpisode|temporaryHold|AlbumFileTimeline` → none in playback/mix).

## 2. Gaps in detail

### P1 — NP Mix Mode phase 1: temporary buffer assets + expiry sweep

iOS: `State/BurnStore.swift` (`TemporaryHold`, `Document.temporaryHolds`, `AssetOrigin`, `pin(songIds:reason:)`),
`State/StorageManager.swift` (`sweepTemporary`, protected set, `admitBufferStep`), `Views/StorageView.swift` (Mix Mode buffer section),
`Mix/MixStreamLoader.swift` (`origin:` on `open`), `Settings/SettingsStore.swift` (`npMixBufferTTLHours`, `npMixBufferCapGB`,
`npMixKeepPickedFolderBuffers`), design `docs/design/np-mix-mode.md` §3. Commits b2c75f8a, 5b1d7492, eb629fb0, f1083dbe.

Android approach:
- `A/data/burns/BurnModels.kt`: add `TemporaryHold(songId, audio, stemParts, cutFile?, createdAtMs, expiresAtMs, userFolderPath?, userFolderFiles?)`
  and `temporaryHolds: List<TemporaryHold>? = null` on the ledger document (additive-optional; no schema bump). Ledger is per-device, never synced.
- `A/data/burns/BurnStore.kt`: `adoptStreamedFile/adoptStreamedStems/burnStemPart(…, origin: AssetOrigin)`; a `.buffer` landing writes a hold
  ONLY for what it created (no `.ready` item existed, part not already on disk); `pin(songIds, reason)` funnel called by EVERY explicit
  action (Download song/album/collection, Rip+Burn, recognizer add, Mix deck load / `loadStreaming`, Mix download lane, explicit stem burns,
  Storage "Keep all"). Pin must run BEFORE the freshness skip.
- `A/mix/stream/MixStreamLoader.kt`: `open(…, origin)` default explicit("mix"); explicit opener joining a buffer stream upgrades it (explicit wins).
- `A/data/storage/StorageManager.kt`: `sweepTemporary(now, reason, capOverrideBytes?)`; triggers: launch (after first frame), app foreground,
  hourly in foreground, the existing prune WorkManager job (NOT gated on the soft cap), Mix Mode off (cap only), disk guard. Eviction order for
  soft-cap prune: unprotected holds (soonest expiry) first, then LRP pinned burns.
- SAF picked folder (`BurnFolder`/`ContentResolverBurnTree`): record file identity (name → lastModified) at creation; delete only what we
  created and is unchanged; folder switch releases; `npMixKeepPickedFolderBuffers` (nil ⇒ false) pins at creation.
- UI: `StorageSection.kt` "Mix Mode buffer": footprint, count, next expiry, TTL picker 6/12/24/48/72/168 h/Keep, cap 0.5/1/2/5/10/20 GB,
  Keep all, Clear now; song-row/Song Detail "Buffered · expires in N h" badge.

Invariants: no hold = pinned (already-downloaded media never becomes temporary); a hold lists only what the lane created; expiry never evicts
what is protected (current row base+resolve id, NP window current+`npMixBufferAhead`, held restored session window, Mix decks, live
`MixStreamLoader` streams + claimed stem sets, Mix auto-upcoming head); an expired-but-protected hold is re-checked next sweep;
sweep: stamp `lastTemporarySweepAt` first, one scan, delete in chunks of 25 with `yield`, re-read protected set per chunk, single-flight;
never delete analog per-song cuts outside the hold; settings keys = iOS names (`npMixBufferTTLHours`, `npMixBufferCapGB`, keep sentinel 0).

### P2 — NP Mix Mode phase 2: toggle, chip, buffer lane, swap-on-land

iOS: `Playback/NPMixMode.swift` (`NPMixModeState{enabled}`, `NPMixCellularPolicy` off|nextSong|full, `Indicator`, `BufferDot`, `defaultBufferAhead`=3,
options 1/3/5/10), `Playback/NowPlayingPrefetch.swift` (`NowPlayingPrefetcher.plan(_ input:)`, Track.Source local|ripped|appleMusicOnly|catalogOnly|live|studioOrProfile,
`diskVerdict`), `SetlistPlayer.swift` `setMixMode`/`toggleMixMode`/`resetMixMode`/`mixModeBufferStrip`/`handOffCurrentToLocal`/`revertFailedHandOff`/
`retryOwedHandOff`/`replanPrefetch`/`prefetchTrack`, `Views/NowPlayingMixPanel.swift` (`np-mix-mode`, `np-mix-mode-status`, `np-mix-buffer-strip`),
`Views/NowPlayingPanel.swift` (`np-menu-mix-mode` in record + mini-bar menus). Commits 0d1d5d09, a9787b35.

Android approach:
- New `A/mix/nowplaying/NpMixMode.kt`: state, cellular policy, indicator (`OFF/READY/ENGAGED/BUFFERING(f)/HOLDING(f)/STEMS_LOADING/RIPPING/
  READY_FROM_AM/UNAVAILABLE(reason)/SUSPENDED/WAITING("Buffers on ▶")`), chip words copied from iOS.
- Generalise `StemLockPrefetcher` → `NowPlayingPrefetcher` (keep a typealias): `plan(input)` with `mixMode`, `window`, `isRipServerConfigured`
  (Android's "owner" — see P4), Track.Source; Mix Mode OFF must return the Stem Lock plan byte-for-byte (pin with a regression test).
  Order: rips(step 0, P4) → current `.song` if ripped-not-local → current stems → next song → next stems → rows 2…window → muted parts last.
  Network from `ConnectivityManager` (NOT_METERED = unmetered; metered = expensive; `restrictBackgroundStatus == ENABLED` (Data Saver) = constrained).
- Disk guard before EVERY lane step (Stem Lock too): ≥1 GB free after the step (`StorageStatsManager`/`File.usableSpace`, off-main) and temp
  footprint < cap, else `sweepTemporary(capOverride)`, else skip (`UNAVAILABLE("Storage full")`).
- Sequencer state: `npMixMode` on `SetlistSequencer` (session scope: `play()` sets from `npMixModeDefaultOn`, `stop()` clears; restore HELD — no
  buffering until first ▶). Suspended while the Mix tab runs (`DspHostPorts.mixSessionActive`).
- Swap-on-land: when the current row's `.song` lands while it plays from its presigned Exo stream of the SAME rip, reload Exo onto the local file
  at the same song position (song-relative ms; side→side / side→cut re-base on `startMs`) with play deferred until the seek lands; under Stem Lock
  with stems engage DSP directly.
- UI: `A/screens/nowplaying/NowPlayingDspPanel.kt` header always shown while a session runs (today hidden unless local), Mix Mode switch +
  chip + buffer strip dots; mini-bar (`A/screens/browse/MiniPlayerBar.kt`) + record long-press menu toggles; Settings ▸ Storage ▸ Mix Mode buffer
  (start-in-Mix-Mode, buffer ahead, cellular policy).
- `MixStreamLoader.pinnedIds` += NP current + next audio ids.

Invariants (from §9.1 review fixes): a hand-off NEVER starts audio (refuse while audio focus is lost/transient or the listener paused or the engine
no longer intends to play); a failed local file reverts ONCE to the presigned stream at the same position, a second failure advances; hold a
`PlaybackRunway` (wakelock) across the reload until first audio (cap 10 s); own-stamp match = URL + song (two songs of one analog side share a
file); the lane never cancels a pending explicit background Download (playing row waits ≤ 90 s, upcoming rows left to it but their stems still
fetched); Mix tab idle again ⇒ retry an owed hand-off; one DSP surface at a time.

### P3 — NP Mix Mode phase 3: the NP DSP plays the growing file

iOS: `Playback/GrowingFileSchedule.swift` (pure: `bytesPerSecond`, `playableFrames`, `frontier`, `canStart` 2 s start / 4 s resume runway,
`shouldAppend`, `underrun`, `coveredFileSeconds`), `NowPlayingDSP.swift` `engageStreaming/pumpMain/holdMain/appendMain/finishMainStream/
handleMainStreamFailure/seek(toSongSeconds:)`, `SetlistPlayer.swift` `growingStartEligible/startOnGrowingFile/engageGrowingFromStream/
growingFallBack/growingTouchCovers`, `MixStreamLoader.addProgressListener`. Commits 08547f69, 0c607f96, 76dc87ed, b4d679e9, eb629fb0.

Android approach: port `GrowingFileSchedule` as pure Kotlin (or lift the existing StreamDecks math in `A/mix/engine/StreamDecks.kt` into a shared
object — the iOS change made MixEngine call the shared schedule, do the same). `NowPlayingDspEngine.engageStreaming(file, expectedBytes, …)`
reusing the Mix deck's growing-Voice path; `NowPlayingDspHost`/sequencer: a cloud branch in `playCurrent` (after burned/stem-cut) that starts the
row on the growing buffer when eligible (Mix Mode buffering, Mix tab idle, not device mode, ripped, not AM-first, not an analog song without a cut,
not refused this play, restore-resume ≤ 15 s deep). DSP is the TransportOwner (`NowPlayingDspSessionPlayer`) and reports BUFFERING while holding
(cursor frozen). `MixStreamLoader` must fan progress to multiple listeners and mark cancelled/evicted streams `failed` (else a reader waits forever).

Invariants: never schedule past the frontier; start/underrun/seek without runway HOLD (playhead frozen, intent kept); mid-song hold > 5 s ⇒ leave
DSP and put the row on its plain stream at the same position (no audio lost, no truncation); a HEADERLESS mp3 (no Xing/Info/VBRI) is never attached
on a partial length estimate — hold unattached until complete; route loss (`ACTION_AUDIO_BECOMING_NOISY`) pauses the DSP; a network where the
cellular policy fetches nothing starts the row plain; the supervisor never acts while the DSP owns audio (the 5 s fallback is the DSP's own);
the stems→song cut needs runway past the crossfade lead at the current tempo.

### P4 — NP Mix Mode phase 4: Apple Music rows

iOS: `PlaybackCoordinator.providers(for:preferLocalAudio:)`, `streamsAppleMusicFirst(…preferLocalAudio:)`, `RipServerPlaybackProvider.startsWithoutRoundTrip`,
`NowPlayingPrefetch.swift` `Plan.rips`/`Plan.stemify` (owner only, first 2 AM-only rows), `SetlistPlayer.handOffFromAppleMusic/appleMusicHandOffReady/
appleMusicLocalCopy/amHandOffTargetId/appleMusicHandOffTarget` (tail guard 3 s, `amHandoffLeadMsDefault` 0), `strayReclaimAction(…dspEngaged:)`.
Commits a96a45b2, f1083dbe, ca14de1d.

Android approach: in the Android resolver ladder (`A/playback/sequencer/RowResolverRegistry.kt`, `AppleMusicRowResolver.kt`, `CloudRowResolver.kt`)
add `preferLocalAudio` = Mix Mode buffering: an AM-sourced ripped row whose local copy is complete OR whose presign is already cached plays from
the rip, AM behind it as fallback (never trade an instant AM start for a slow presign — dead-air rule). Touch hand-off: `AppleMusicBackend.
currentPositionMs()` (+ lead, default 0) → `NowPlayingDspEngine.engage(file, …, atSeconds, play=false)` → `stopAppleMusic()` → DSP play → DSP claims
the session (`SessionSwitchboard`), `DeadAirMeter` cause `npmix-am-handoff`. Rip-ahead (`.rip` plan list, fire-and-forget) only when a rip server
is configured (`settings.hasRipServer`) and through the existing playback rip window (`A/playback/health/PlaybackRipWindow.kt`).
Feasibility "equivalent": AM audio is DRM'd inside the MusicKit SDK on Android too, so it can never be DSP'd — same as iOS; the hand-off is the
equivalent. Decision for Levi (default proposed): iOS gates rip-ahead on catalog OWNER; Android has no owner identity (parity D7), and Levi's
2026-11-02 rule is "each user runs their own rip server" ⇒ gate on "a rip server is configured". Non-configured users see "Apple Music only".

### P5 — Stem Lock edition rule A + edition-aware dots

iOS commit 428a16ef: with the lock carrying stems and VOCALS MUTED, a preference row (never a clean-only restriction) whose wanted edition has no
rip/burn plays the BASE cut + stems (lane fetches base; sticky substitution; resolve is base rip rip-first, never AM). Buffer dot full only when the
file the row WILL play is local. Log `[npmix] edition-substitute row=… played=… requested=… reason=vocals-muted`.
Android: `A/data/edition/EditionPolicy` + `SetlistSequencer` per-row resolve + `NowPlayingPrefetcher.Track.audioId`. Keep Q94 clean-only skip
semantics untouched (rule A never applies to `editionLocked` rows).

### P6 — FX Lock

iOS: `Playback/FXLock.swift` (`FXLockState{enabled, effects: [rawEffect: {on, strength}]}`, `wantsFX`, Indicator off|idle|applied|waiting|dormant),
`SetlistPlayer.swift` `setFXLock/resetFXLock/stampFXLockIfIdle/fxLockDidEngage/applyFXLockOnTrackStart/persistFXLockSoon/applyLocksOnTrackStart`,
`NowPlayingDSP.fxRampSeconds` = 0.25, `onUserEffectChange`, panel `np-mix-fx-lock` (Effects header upper-RIGHT, same spot as Stem Lock; no new row;
NO status line — Levi 2026-11-03). Commits 7c0828e2, 9797d1b2, d1ab06e0.

Android approach: `A/mix/nowplaying/FxLock.kt` (state + `FxLockSession` like `StemLockSession`); `NowPlayingDspEngine`: `onUserEffectChange`
callback (USER effect actions only), `applyCarriedEffects(map, rampSeconds=0.25)` ramping ON effects from transparent; host `onTrackStarted`:
with `wantsFX`, engage the DSP at start on every mixable start path (burned/local, studio/profile, stem cut, growing file, swap-on-land,
AM touch hand-off ramps the carry in); non-mixable rows play dry with indicator WAITING; Mix tab live ⇒ DORMANT; lane fetches the next songs
(no stems) while the lock carries effects. Persist in snapshot `fxLock` (keys = `Effect.raw`: compressor/reverb/flanger/filter — Android
`A/mix/model/MixModels.kt` raw values already match). Unknown effect keys kept on disk, ignored on apply.

Invariants: tempo/pitch/gain do NOT carry (reset per track); user touch beats the ramp; session scope (new `play` / `stop` clears; skips, edits,
restore keep); `engage` must refuse an unopenable file and leave the track on ExoPlayer (iOS MUST: "playing over dead air"); a lock engage of a
complete playing file closes the start window + records exactly one dead-air transition (no double first audio).

### P7 — DJ Mode: session state, settings, UI shell

iOS: `Playback/DJMode.swift` (`DJModeState{enabled, planner?}`, `DJModeSettings` 7 toggles all default ON, `Timings` lead/fade/glide/skipFade,
`fastSkipFadeSeconds` 5, `SongFacts`, `Indicator` + `chipText`), `SetlistPlayer.swift` `setDJMode/toggleDJMode/resetDJMode/observeRemoteSessionForDJ/
djEndReason/djDecline`, `Settings/SettingsStore.swift` `djTransitions/djEffectSweeps/djTempoMatch/djKeyMatch/djVolumeLeveling/djTempoWaves/djPockets`
(missing key ⇒ true) + `mixVolumeGlide`, `Views/NowPlayingMixPanel.swift` (`np-dj-mode` chip LEFT of Mix Mode, `np-dj-crossfade`),
`Views/NowPlayingPanel.swift` (`np-menu-dj-mode`), `MixingSettingsView` (Settings ▸ Mixing). Design `docs/design/np-dj-mode.md` §1, §6, §7, §9.

Android approach: `A/playback/dj/DjMode.kt` (state/settings/indicator words verbatim); sequencer fields + `setDjMode`: ON ⇒ Mix Mode ON, seed planner
(`fxSeed` over the queue), re-plan, take the current local row into the DSP; OFF ⇒ disarm + level to 0 dB (track carries on); `setMixMode(false)` ⇒ DJ off;
cleared by `play`/`stop`; `djActive` = on && Mix tab idle && no Remote/jukebox-mirror session attached. Settings: extend `A/mix/MixSettings.kt` +
`A/screens/settings/sections/MixSection.kt` into a "Mixing" pane: Crossfades (existing 4 steppers, shared), "Now Playing DJ Mode" 7 switches, Mix tab options.
Panel: DJ chip left of Mix Mode, DJ words ride the Mix Mode chip ("Mixing · DJ — next mixes in"), chip floor fills 0→1 over the crossfade.

Invariants: the toggles MASK parts off; they never change shared Mix-tab timings; DJ implies Mix Mode buffering; suspended while the Mix tab runs and
while a Remote session is attached (its fade-start advance would read as an early natural end to other participants; two DJ devices would re-order a
mirrored queue) — chip "DJ — paused · SharePlay session" → on Android word it for the Android Remote equivalent; no TV.

### P8 — Shared `AutoTransition`

iOS: `Playback/AutoTransition.swift` (`advancePlan(secondsLeft, fade, glide, fxGlide, mixGlide)`, `immediatePlan`, `equalPowerGains`, `glideParams`,
`outgoingRamp/incomingRamp`, `rollTexture`, `fxSeed(firstSongId:count:)`, `BeatRef`, `phaseAlignOffset(Ms)`, constants headroom 1.12,
minRunwayFade 0.5, minImmediateFade 0.2, preRollMargin 0.3, rate 0.5…2, pitch ±12). MixEngine refactored onto it (75a9d0e0).
Android: `MixMath.kt`/`GlideMachine.kt`/`PhaseAlignMath.kt` already hold most math but inside the Mix engine. Create `A/playback/dj/AutoTransition.kt`
(pure) and make `GlideMachine`/`AutoDj` call it behavior-preserving (their existing JVM tests guard it). Port iOS `AutoTransitionTests` vectors as goldens.

### P9 — DJ transitions in Now Playing (tail deck + conductor)

iOS: `NowPlayingDSP.swift` "DJ Mode: the TAIL deck" (`armDJ(lead:)`, `DJTransition`, 10 Hz lead-window watch, handover at a shared future host time,
pre-roll ramps, fade, post-roll, hand-back), `SetlistPlayer.swift` `applyDJOnTrackStart/armDJ/wireDJHooks/djBuildTransition/djMakeTransition/
djAdvanceAtFadeStart/djIncomingEngaged/djIncomingFailed/djLocalSource/djBeat/djFacts/nextDJTexture`; design §2, §3, §9 rows "Track start",
"The decision", "Tail deck + conductor", "Advance at fade start". Commits abbc4679, fb693252, 2d0cc256, d4ce5efb, 0c696c9a.

Android approach (recommended design, simpler than iOS because of what exists):
- The Android NP DSP already runs a private two-deck `MixGraph` with deck A only. Use **deck B as the other deck and the graph's equal-power
  crossfader as the fade** ("ping-pong decks"): the incoming loads onto the idle deck at its phase-aligned start, the crossfader sweeps, the idle deck
  becomes the live deck. This avoids iOS's sample-accurate outgoing→tail move entirely (iOS needed it because its main chain is the one the
  listener's controls address — on Android, re-point the controls at the live deck after the fade). Leveling rides per-deck `trimDb`.
- Engine API: `armDj(lead)`, `beginTransition(plan, incoming file/window, glide params, texture, levelDb)`, `cutTransition(reason)`, callbacks
  `onFadeStart(songId)` (host advances the sequencer), `onTransitionEnded`, `onHandBack`. Drive ramps from the render clock, not the 4 Hz host tick
  (GlideMachine's tick-driven ramps are acceptable at ≥ 50 Hz; add a 20 ms engine-side ticker while a transition runs).
- Sequencer: new non-loading advance `djAdvanceAtFadeStart(songId)`: index++, `noteTransition(naturalEnd)`, repeat counter, generation /
  start-window / stall bookkeeping, `DeadAirMeter` cause `dj` with first audio at once, control reset + FX Lock stamp, play history (ONE play),
  publish card metadata from the DSP owner, Stem Lock on the incoming, re-arm, re-plan. A new `PlayerPort.adoptDsp(request)` so ExoPlayer is
  idle/cleared and `NowPlayingDspSessionPlayer` owns the MediaSession through the whole transition.
- Track start: last step of the locks-on-track-start chain (so every start path, swap-on-land, growing start, album glide get it).

Decline list (one list shared by decision, fade-start re-check and chip — `djEndReason`): transitions off, repeat-one / repeat count, cascade halt,
last row (repeat-all ⇒ "set repeats"), album run playing through, next row STARTS an album run, next not a complete local file; DSP-side: not
playing/holding, growing outgoing, stem handover in flight, outgoing has muted stems (`[dj] declined stems-muted`), unreadable incoming, < 0.3 s left.
Plan: `advancePlan(secondsLeft × min(1, 1.12/outRate), fade, glide, fxGlide: effectSweeps, mixGlide: tempo||key)`; glide only with Tempo/Key on;
texture only with Effect sweeps; incoming leveling gain only with Volume on.

Invariants: never blocks or delays playback — any failure = today's normal advance; transport: pause pauses both decks, seek cuts the other deck,
stop cuts everything, a listener touch in ANY phase ends the glide (listener wins); a stem toggle before the advance hands the outgoing back to the main
chain first; a cut before the advance with the song still playing hands back at the playhead (no hole, glide eased out 0.5 s), a deck that ran out reports
the end; `handleDSPEnded` advances tag `naturalEnd` (never autoSkip); fade-start refusal (queue moved) puts the outgoing back; a DSP that can't open the
incoming after the advance plays it the plain way; generation discipline: any stop that fires completions bumps the generation at the COMMIT point
(memory `stems-toggle-generation-discipline`). One audio owner, one card writer.

### P10 — DJ skip mix

iOS: `SetlistPlayer.skipNext(fast:)` → `djSkipMix(fast:)`, `djSkipPending`, `Views/NPSkipNextButton` (tap = Skip fade, double-tap = fast;
release-blocker 0c696c9a: a press-highlight gesture swallowed taps), design §3 "Skip = the Mix tab's Skip". Commits e88622c9, 75e265c8, 9d10a6a7.
Android: `SetlistSequencer.skipNext(fast: Boolean = false)`; `SequencerForwardingPlayer.seekToNext/seekToNextMediaItem`, `WidgetBridge` NEXT, Android
Auto, Bluetooth/headset ⏭ ⇒ `fast = true` (iOS: lock-screen/CarPlay/widget ⏭ are the 5 s sweep); NP deck + mini bar ⏭ use
`combinedClickable(onClick, onDoubleClick)` — verify on device that the double-tap detector doesn't delay single taps by the double-tap timeout
in a way Levi dislikes (alternative: act on tap immediately with Skip fade and upgrade to fast if a second tap lands during the pre-roll).
Rules: no transition ⇒ `immediatePlan` (fade cut to the runway ≥ 1 s, 0.5 s spare); in pre-roll ⇒ drop pre-roll, fade now over skip length;
paused in pre-roll ⇒ immediate advance; during fade ⇒ ignored; during post-roll ⇒ end glide, mix out of the new song; advance is a USER skip
(`noteUserTransport`, meter cause `skip`, skip tracker at the PRESS), overrides repeat-one/count and lifts a cascade halt; pending skip keyed on the
RUN's incoming, cleared on every start/advance/⏮/run end; a second ⏭ inside a skip mix's handover is the same skip. ⏮ stays previous.

### P11 — PocketDJ selector + next-up pick

iOS: `Playback/DJSetPlanner.swift` (Candidate/Features/Options/State, constants band 10, minPerBand 3, weights .35/.2/.2/.25, orderBonus .02,
agingBonus .03, neutral .5, nearAdjacent .3….8, artistSpacing 4, seeded `waveLength` 2–3 / `pocketLength` 3–4 via `hash`), `SetlistPlayer.swift`
`djReplan/applyDJOrder/djCandidate/djRowFixed/djAlbumLinkedRows/scheduleDJReplan (debounce 1 s)/loadDJMembership/setUserNext/djUserNextPlaced`,
`Item.djUserNext`, `djMaxDeferrals` 12, plan window 40. Commits 17eff3c3, b59423f5, d8d2d40d, cdbf9e87.

Android: `A/playback/dj/DjSetPlanner.kt` (pure; port iOS `DJSetPlannerTests` incl. artist-spacing scarcity + aging as goldens; reuse `foldBpm`,
`camelotRelatedness`, `Genre.category`, `creditArtistKeys`); `QueueItem.djUserNext` + every live edit that lands a row NEXT sets the pick
(insertNext, move-to-next, drag to Up Next top, drop before next, jukebox/remote request landing next, stall-hop deferred row); others are planner
material; random jukebox inserts draw from AFTER a held pick only while DJ holds it. Membership off-main from `ListeningPocketsCollections` once per DJ-on.
Fixed rows: next-up pick, album-run blocks, rows with a playback rip / lane fetch / buffer stream in flight, rows deferred ≥ 12 times, and the next row
when local, buffering, mid-transition, or under the 30 s runway (or length unknown). One uid-verified re-order write; duplicate uids bail; our own
re-order never re-triggers; no re-plan while a Remote session is attached. Shuffle order superseded while DJ is on. Analysis results re-plan only when
a row's usable BPM/Camelot changed (no deferral counting).

JSON: `djMode.planner` (iOS `DJSetPlanner.State`) — `seed` is a UInt64 (decode/encode as unsigned; values ≥ 2^63 occur), `lastAccountedUid` UUID
string (uids are fresh on restore — harmless), `pocketAnchor` Features with `collections` array, `direction` Int (1/-1). Bit-identical `hash`/splitmix so
a cross-device restore keeps the same wave.

### P12 — Loudness leveling

iOS: `Playback/LoudnessAnalyzer.swift` (`LoudnessLeveling` target −14, clamp −12…+6, ramp 2 s; K-weighting pre/RLB biquads, 400 ms blocks, gates
−70 / −10 LU, mono-sum; `LoudnessCache` `Application Support/loudness.json` keyed songId + byte size + SEGMENT(startMs,lengthMs)), `SetlistPlayer`
`djLevelDb/applyDJLeveling/djLevelingStatus/djAnalyze/djAnalyzeUpcoming/djAnalysisLanded`, `NowPlayingDSP.setLevel(db:ramp:seconds:)` on `levelTrim`,
`levelRampStepSeconds` 0.02. Android: `A/audio/dsp/Loudness.kt` (pure meter, test with synthesized sine/noise at known RMS like iOS) + `A/playback/dj/LoudnessCache.kt`
(`filesDir/loudness.json`); decode via `A/audio/core/AudioDecoder`/`Mp3Decoder` mono-sum; gain on the deck's trim. Invariants: one analysis per key
(second caller awaits), failure remembered for the launch, only a STORED result re-applies gain, DJ off/session end cancels running analyses (flag into
the decode), growing file not measured until complete, unknown ⇒ 0 dB, landing mid-play ramps 2 s in 20 ms steps, incoming gain lands over 150 ms at
fade start, a shared album side is measured per song slice, limiter catches positive-gain peaks; leveling only while DJ on && Volume on; listener volume on top.

### P13 — Progressive analysis

iOS: `Playback/AudioAnalysis.swift` (`quickWindow` 20 s from ~30 % in / head 15–30 s for growing files, `Result{kind quick|full, headOnly}`, confidence
gates BPM ≥ 0.3 key ≥ 0.7, hint gain clamp ±4 dB, precedence server grid/catalog > full > confident quick > nothing, `AudioAnalysisCache`
`analysis.json` LRU 5000 finals, debounce 1 s off-main, hints launch-only, `AudioAnalysisScheduler` one at a time, priority current → next-up pick → planned
next → 40-row window, head re-check every 5 s ≤ 24). Commit ac7dae40. Android: `A/playback/dj/AudioAnalysis.kt` reusing `A/studio/demux/BeatDetect.kt`
(add a confidence output) and `KeyDetector.kt` (strength). Scheduler on `Dispatchers.Default` at low priority; pause when
`PowerManager.isPowerSaveMode` or `getCurrentThermalStatus() ≥ THERMAL_STATUS_SEVERE` (iOS: Low Power / serious thermal). Decoder tolerant
(`ignoreUnknownKeys`) so a schema change never wipes the cache.

### P14 — DJ automation display + leveling readout

iOS: `NowPlayingDSP.djDisplay` (`DJAutomationDisplay` ~16 Hz while automation runs; `displayRate/displayPitch/displayEffect`, `leveling`),
`DJLevelingReadoutRow` ("Leveling +3.2 dB", −12…+6 meter, "measuring…"/"off"/"unavailable", "−4.5 dB → +3.2 dB" during a crossfade). Commits
bdc7d841, a524839c. Android: a `StateFlow<DjDisplay>` on the engine sampled ~16 Hz only while automation runs; `NowPlayingDspPanel` binds sliders/FX
buttons to display values; READ-ONLY — listener values (and FX Lock carry, snapshot, settings) never see automated values; a touch acts on what is shown
(slider sets listener value from shown, glide ends without a jump; tapping a swept effect turns it off; dragging its strength keeps it on).

### P15 — Stall episode (ping-pong fix)

iOS: `SetlistPlayer.swift:4568-4710` `stallEpisodeAbandoned: Set<UUID>`, `endStallEpisode(reason:)` on first audio (incl. AM), user transport, stop;
`hopToOnDeviceRow` filters abandoned uids, inserts the stalled uid, logs `abandoned=N`; no eligible target ⇒ keep buffering the current row (no
cancel/restart). Commit 532ac59f.
Android today: `ResolveStallHop.choose` has no abandoned filter; `SetlistSequencer.hopToPlayableRow` (l.1422). Android "instant" = manifest entry exists
(`PlaybackController.kt:377`) — a manifest rip still streams, so two stalled manifest rows can hop back and forth every 6 s exactly like iOS's AM rows.
Fix: `choose(…, abandoned: Set<String /*uid*/>)`; sequencer keeps the set, clears it in `handleFirstAudio`/AM first audio, every user transport, `stop`;
log `stall episode end reason=… abandoned=N`; DJ: when DJ is on, the deferred row becomes the next-up pick (P11).

### P16 — FR1 on Android: cancelled Apple Music start can take over the hop target (BUG, PLAUSIBLE)

iOS fixed this class in 5f5b5c74 (coordinator stands down on cancel; `supersedePendingPlay`; AM stops a stream accepted after cancel).
Android: `PlaybackController.loadAppleMusic` wraps `backend.play(...)` in `runCatching { … }.getOrDefault(false)`, which SWALLOWS the
`CancellationException` thrown when the sequencer cancels the start (stall hop at 6 s, skip, supersede). It then sets `activeBackend = prior`.
`AppleMusicBackend.play` had already issued `controller.prepare(provider, playWhenReady = true)` and its `!ok` cleanup (`controller.stop()`)
never runs on cancellation. The hop target's `Media3Port.load` calls `stopAppleMusic()`, but that only stops when `activeBackend == APPLE_MUSIC` —
now `EXO` — so the MusicKit SDK keeps preparing; when it reaches PLAYING, `AppleMusicPlayerAdapter.onEngineChanged` claims the session
(claims were released in `finally`) and pauses ExoPlayer: the stalled song takes over the hop target (burned → stalled AM → hop to burned is the
common case). Fix: in `loadAppleMusic` rethrow `CancellationException` (don't `runCatching` it) and in a `NonCancellable` block stop the SDK
(`backend.stopNow()`), clear `current`/`playConfirm`; `AppleMusicBackend.play` should stop the controller in a `finally` when cancelled.
Regression test: cancel the start while `confirm` is pending → SDK `stop()` called, no adapter claim afterwards.

### P17 — Vinyl album side plays end to end

iOS: `Playback/AlbumFileTimeline.swift` (segments of `rips/<albumId>.mp3` filtered to the album's trackList; END RULE: user-edited end exact, else
detected end + `fadeGraceMs` 15 s, never past next start; `SegmentOverrides.shared` — ALL start readers go through it), `SetlistPlayer.swift`
`glideInSameFile/jumpInSameFile/retargetInPlace/seekAlbumFile(toFileMs:)/cueNextStart`, `glideOnNextAdvance`; album RUN: next queued row = next song
on the same file ⇒ the song ends EXACTLY at that start, last song of a run plays to file end, album from its top starts at 0:00 (lead-in one-shot,
not a negative cue); ⏭/⏮ within the file seek in place. Commits 5932062e, db98dd1f. Memory `vinyl-album-side-playback.md`.
Android today: `A/data/rips/PlayResolver.kt` clips `[startMs, startMs+durationMs)` from the manifest (catalog length) per row and every row reloads
ExoPlayer; `CatalogEdits.kt` has `AudioTrackEdit` but no override layer feeds playback.
Approach: `A/playback/album/AlbumFileTimeline.kt` + `SegmentOverrides` (derived from catalog edits/manifest, rebuilt on catalog assign) used by
`PlayResolver`, `BurnedRowResolver`, `MixStreamLoader`. In-place glide: keep ONE ExoPlayer item for the side (clip start only = run start; no clip end
inside a run) and advance the sequencer at segment boundaries without reloading — `Player.replaceMediaItem` with metadata-only changes (Media3
1.6.1 updates in place when the URI + clipping are unchanged), boundary detection via a service-side `PlayerMessage` at the boundary position
(`ExoPlayer.createMessage(...).setPosition(...)`, in `PlaybackService` since the controller is a `MediaController`). Gaps > 3 s skipped with an in-place
seek BEFORE re-arming the boundary. Declines with DSP/locks/held deck/AM/live. The album waveform editor UI (`Views/AlbumWaveformEditor.swift`) belongs to
the browse/albums audit.

### P18 — Durable session snapshot

iOS `State/PlaybackSessionStore.swift` Snapshot adds optional `npMixMode`, `fxLock`, `djMode` (+`planner`), and Row adds `plan` (PlanTag),
`appleMusicId` (Remote rows only), `djUserNext` (legacy `djPlaced` read-only: maps to the pick only on the row right after current). Android
`A/playback/durable/SessionSnapshot.kt` has none of them, and decodes with `PdjJson.lenient` (ignores unknown keys) then re-encodes — so an
Android write DROPS iOS-only fields from the synced `playback-session` document. Add every field (typed), and add a `JsonObject` passthrough for
unknown top-level/row keys so future iOS fields survive an Android write. No schema bump (stays 1). Restore: Mix Mode/DJ restored HELD (nothing
armed/planned/analysed before ▶), `fxLock`/`stemLock` restored, next-up pick restored on its row.

### P19 — Pocket-run hooks in the sequencer (coordinate with the pockets/wheel audit)

iOS: `SetlistPlayer.replaceUpcoming` (uid-verified, pin-respecting; `isReplaceablePosition` 30 s rule), `Item.plan: PlanTag`, `isRepeatForcedOff`/
`effectiveRepeatMode` (every surface shows it; repeat controls inert during a run — 7fa721f4), `np-retuned` badge (4 s), snapshot `Row.plan`. Android has
none. The planner/wheel/store are the pockets area's; the sequencer API + snapshot field + repeat gating + badge are playback files (`SetlistSequencer`,
`SessionSnapshot`, `NowPlayingDeckCluster`, `UpNextList`, widget/Auto repeat glyph). DJ's selector must keep pocket-run spacing (artistSpacing 4 both).

### P20 — NP 👍/👎 feedback row

iOS `Views/NowPlayingPanel.swift` `feedbackRow` (`NowPlayingFeedbackButtons`, `np-feedback`) under the transport, never touches transport.
Android has `A/screens/foryou/RecFeedbackButtons.kt` but not on Now Playing. Add to `NowPlayingDeckCluster.kt` via `NowPlayingSeams`.

### Present (recorded so nobody redoes them)

- **P21 Stale MusicKit card / release (fa8085da)**: iOS-specific mechanism (MusicKit is a system player with its own card). On Android the SDK is
  in-process and has no MediaSession of its own; the one session is ours (`SessionSwitchboard`), `Media3Port.load` calls `stopAppleMusic()` before
  any Exo row, and the adapter resigns on `release`. Only residual risk is P16.
- **P22 DeadAirMeter**: `A/playback/health/DeadAirMeter.kt` (+ Debug readout, ANS-PB-3). Add causes `dj`, `npmix-am-handoff`, growing starts.
- **P23 Repeat/shuffle**: `SetlistSequencer.setRepeatMode/setShuffle/reshuffleEntireQueue`, persisted repeat. New interplay only via P11 (DJ supersedes
  shuffle) and P19 (forced off in pocket runs).
- **P24 Stem Lock**: `A/mix/nowplaying/{StemLock,StemLockPrefetcher,NowPlayingDspHost}.kt` (MIX-18 emulator-verified). The architecture ledger row
  still says "Planned" — fix `docs/ARCHITECTURE-ANDROID.md` when this program lands.

## 3. Out of this area (dependencies only)

- Voice: iOS 1.0.4 "Mix Mode + stems by voice" (8e6ebc1d) — the intents/Assistant audit must call `setMixMode`, `setDjMode`, stem mute by name on the
  sequencer/host APIs above.
- Remote/SharePlay → Android Remote equivalent: DJ must suspend while attached (P7); Remote rows carry `appleMusicId` (P18).
- Mix tab Volume Glide (16e2a6b0) shares `LoudnessCache` (P12) — Mix audit.
- Play attribution `motion`/`pocketRun` PlayEvent fields (7df7017f) — history/pockets audit.
- Album waveform editor UI — browse/albums audit.

## 4. Suggested package order

1. P16 + P15 (small, high-value playback fixes; ship first).
2. P18 snapshot fields + passthrough (unblocks everything session-scoped).
3. P1 → P2 → P3 → P4 → P5 (Mix Mode, in iOS phase order); P6 FX Lock right after P2 (same files).
4. P8 → P12/P13 → P11 → P7 → P9 → P10 → P14 (DJ Mode).
5. P17 album runs (needs the DJ decline hooks to exist or be stubbed); P19 with the pockets program; P20 any time.

Hot files (one owner per wave): `SetlistSequencer.kt`, `PlaybackController.kt`, `NowPlayingDspEngine.kt`, `NowPlayingDspHost.kt`,
`NowPlayingDspPanel.kt`, `SessionSnapshot.kt`, `BurnStore.kt`, `StorageManager.kt`, `PlaybackGraph.kt`, `MixGraph.kt`.
