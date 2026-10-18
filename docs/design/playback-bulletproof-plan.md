# PocketDJ CarPlay playback — bulletproof fix plan (ship to TestFlight, drive-test)

Scope: `apple/PocketDJ` — `Playback/{NowPlayingArbiter,PlayerEngine,SetlistPlayer,AppleMusicPlaybackProvider,NowPlayingCardPublisher,PlaybackRunway}.swift`, `Mix/MixEngine.swift`, `CarPlay/{CarPlayScene,CarPlayModel}.swift`, `Views/RootView.swift`, `Shared/NPLog.swift`. Every line number below was re-read in the current tree (branch `fix/playback-bulletproof`). Refuted/over-stated lens claims were dropped; corrected versions are used.

---

## 1. Root causes mapped to the owner's complaints

The whole drive-log shape comes from **one stale Mix snapshot** (deck A = "Hold On Me", persisted at 358.0/358.0 = end of file, Auto-DJ queue of 172, restored "parked" at every launch since 2026-10-15) interacting with **three ownership holes**. The setlist is always the thing Levi actually wants to hear.

| # | Complaint | Root cause (verified) | Evidence |
|---|-----------|------------------------|----------|
| **#1a** | CarPlay connect: music paused, won't play | The head unit's play-on-connect reaches `PlayerEngine`'s `playCommand` target (`PlayerEngine.swift:678-681`) which calls `play()`, and `play()` refuses with no `AVPlayerItem` (`:352` idle guard). A restored setlist is HELD with no item (`SetlistPlayer.restore(from:)` `:1869+`, `isHeldForResume = true`), and only UI surfaces route ▶ to `resumeFromHold()` (`NowPlayingPanel:245`, `WidgetSync.swift:99-104`, `CarPlayModel.swift:63-67`). The remote-command path never does. Often the command arrives BEFORE restore has even run (`01:28:54`, `18:58:15`, `19:04:50`: `engine.play REFUSED (idle)` same second as / before `setlist RESTORE held`). | Every held launch: `REFUSED (idle)` then nothing until a `[car] tap <song>` → `resume held session`. |
| **#1b** | Plays but the button shows ▶ / card wrong | `NowPlayingArbiter.isActive` = `owner == nil \|\| owner === who` (`:32`). With nobody owning, a single remote ▶ runs BOTH engines' targets (`PlayerEngine:678`, `MixEngine:5495-5507`, the latter registered inside `ensureEngine` at `:1155`). PlayerEngine refuses (idle); `MixEngine.remotePlay` (`:2190`) → `resumeMasterPaused` (`:2109`) → no pause memory → `nowPlayingDeck` cold fallback "prefer A" (`:5402-5412`) → `play(.a)`. Deck A is cued at EOF: `rescheduleFile` schedules nothing (`:2031 guard count > 0`), `setPlaying(A,true)` anyway (`:2050`), `claim(self)`. The tick never retires it because the EOF stop is `if pos >= dur, !autoMixing` (`:6017`) and `restoreAutoSuspended` sets `autoMixing = true` (`:5224`). Result: card = "Hold On Me rate=1.00 el=358.0" with `jump(expected 360)` heartbeats, `sigAge=-1.00` (never audible). | `02:01:22-23`, `19:04:59-19:05:00`: `mix resume (remote seam)` + `engine.play REFUSED (idle)` + `arbiter claim → MixEngine (was nil)`. |
| **#2** | Stops between songs, has to kick it | Three distinct mechanisms: **(a)** Materializing the parked mix on CarPlay connect (`CarPlayScene.swift:119` → `materializePendingRestoreIfNeeded` → `materializeNow:5105` → `ensureEngine:1068` → `activateAudioSession:6176` `setCategory(.playback)+setActive(true)` + `engine.start():1152`) activates a NON-mixable session + running engine under an out-of-process `ApplicationMusicPlayer` → MusicKit goes `.interrupted`, provider logs `external PAUSE` (`AppleMusicPlaybackProvider:552-557`) and NOTHING resumes it. Because RootView's launch task waits on `cloudSync.syncAtLaunch()` (`RootView:368`) the materialize often lands minutes after the car already resumed the set (preceded by `[screen] section=History`). 3/3 instances: `01:22:25`, `02:57:18`, `03:03:09`. **(b)** AM→local-lane boundary: `playCurrent` local branch (`SetlistPlayer:1751-1760`) stops MusicKit, `PlayerEngine.load` creates the `AVPlayerItem` cold, `player.play()`; the AVPlayer sits in `.waitingToPlayAtSpecifiedRate` 29-32 s (`22:04:18→22:04:47`, `19:12:16→19:12:48`) and in one case the process simply ends (`17:07:29` "Fever" stalled → log ends → next launch restores that row at `resumeMs=0`). The `PlaybackRunway` is only held across the cloud resolve (`:1796-1802`) — never across the local-file branch or until first audio — so a locked phone with no audio rendering is suspended. No start watchdog exists (`armResolveStall:1568` covers resolve only; stall observer `PlayerEngine:306-312` logs only). The card publishes the stall as `.paused` (`NowPlayingCardPublisher:80-81`, `advancing: isPlaying && !isStalled` at `PlayerEngine:798`) so the head unit shows ▶ and `toggle()` (`:386`) PAUSES a waiting player → the "kick" needs two presses. **(c)** The restored Mix keeps `autoMixing=true` so the tick watchdog (`:6023-6031`) and route-change observer (`:6238-6245`) call `recoverFromEngineStop` → `startEngineIfNeeded` → `setActive(true)` (`:1939`) on every CarPlay/BT route change until the first `.began` sets `remotePausedAt` — `22:00:23 recover: engine restarted — re-primed A=1` immediately before `AM play`. | `mix RESTORE materialized` → `AM monitor: external PAUSE` same second ×3; `02:01:42 engine restart FAILED` = watchdog restart during the `.began` AM caused. |
| **#3** | Pause → card jumps to the first song of the session ("Hold On Me") | Every AM start interrupts OUR session (`.began`). `MixEngine`'s observer (`:6213-6216`) latches `interruptionParked` if the silent EOF deck was "running" and calls `remotePause()` (the `mix pause (remote seam)` after nearly every `AM play`). The latch is only cleared when the MIX resumes (`refreshTransport:5560`) — never when `PlayerEngine` claims. The `.ended` branch (`:6217-6226`) calls `remotePlay()` with NO arbiter check → `resumeMasterPaused` replays `masterPausedDecks={A}` at 358/358 → `setPlaying` → `claim` → arbiter flips to `MixEngine`, card = "Hold On Me playing". `PlayerEngine`'s `.ended` (`:609-616`) resumes too (same second). From then on the car's ⏸ reaches the Mix (owner) and the setlist keeps sounding under a paused "Hold On Me" card (`engine card SKIP (arbiter owned elsewhere)` ×13). | `22:00:23` latch; `22:06:59` `mix resume (remote seam)` + `card PUB w=engine rate=1.00 el=24.9` + `arbiter claim → MixEngine (was PlayerEngine)`; `22:07:08 mix pause (remote seam)` → `Hold On Me st=paused`. |

Two cross-cutting facts:
- **The 358/358 state is accumulated, not original.** `01:19:07` the deck resumed at `el=259.2` with `sigAge=-1.00` (never audible), advanced to 339.8 by `01:20:32`, reached 358 later; each silent run persisted its playhead (tick position writes + `materializeNow`'s `defer { persistMixDeckSession() }` at `:5115`, which passes the `:5245` guard because `isRestoringMixSession` is reset first). Why it rendered silence at 259 s is NOT determined (see §5).
- **Log-ordering trap:** `NPLog.trace` mirrors via `Task { @MainActor }` (`Shared/NPLog.swift:31`), `DiagLog.telemetry/log` are synchronous → `[np]` lines land after same-turn `[action]/[mix]` lines. "mix resume before materialized" is an artifact (`resume-health cold=0` proves the graph was already built).

---

## 2. Ordered fix list

Principles: surgical, one invariant per change; a genuine user pause is never un-paused; the Mix keeps full remote/interruption behaviour **when it is the owner or the user started it this process**; restores never claim, never sound, never write.

### P0-1 — Route remote ▶ to the held/idle setlist (complaint #1a)
**Files:** `Playback/PlayerEngine.swift` (`configureRemoteCommands` `:675-690`, `play()` `:341`, `toggle()` `:384`), `Playback/SetlistPlayer.swift` (`restore(from:)` `:1869+`, `restorePersistedSessionIfIdle` `:1851`, `resumeFromHold` `:1948`).
**Change:**
1. `PlayerEngine`: add `var onIdlePlay: (() -> Bool)?`. In the `playCommand` and `togglePlayPauseCommand` targets, before `play()/toggle()`: `if !hasLoadedItem, let onIdlePlay, onIdlePlay() { return .success }`. Also in `play()` itself at the idle guard (so interruption `.ended`/widget paths benefit) — call the hook, and only trace `REFUSED (idle)` if it returns false.
2. `SetlistPlayer.init` (not `armEngineHooks` — it must be live while held) wires `player.onIdlePlay = { [weak self] in guard let self, self.isRunning else { return false }; if self.isHeldForResume { self.resumeFromHold(); return true }; if self.pausedByCascade || !self.player.hasLoadedItem { return self.startCurrent() }; return false }`. This is the exact ladder `NowPlayingPanel.swift:245-255` already uses.
3. **Pending-play latch** for the before-restore case: `PlayerEngine` sets `pendingRemotePlayAt = Date()` when a remote play is refused with no session (`onIdlePlay` returned false). `SetlistPlayer.restore(from:)` ends with `if let t = player.consumePendingRemotePlay(maxAge: 15) { DiagLog.telemetry("action", "remote play (pre-restore, \(Int(-t.timeIntervalSinceNow))s ago) → resume held session"); resumeFromHold() }`.
**Why safe:** gated on `isRunning` — a deliberately stopped set is never resurrected; a held session has no audio yet so no user pause can be overridden; macOS/tvOS share the handler and `resumeFromHold` is equally correct there. The 15 s window keeps a stale pending play from firing on a later restore.
**Test:** `SetlistPlayerTests`: restore a fixture snapshot (held) → invoke the play-command target body (expose `handleRemotePlayForTesting()` like `handleLikeCommand`) → assert `isHeldForResume == false`, `coordinator.play` was called with the saved song at `pendingResumeMs`, and the `action` telemetry line is `remote play → resume held session`. Second test: refuse with no session, then `restore(from:)` → resumes once; a third restore does not.

### P0-2 — Arbiter: a nil owner is NOT "everyone"; a never-played restore is never a remote target (complaints #1b, #3)
**Files:** `Playback/NowPlayingArbiter.swift`, `Playback/SetlistPlayer.swift` (`restore(from:)`), `Mix/MixEngine.swift` (`configureMixRemoteCommands` `:5489-5507`, `play(_:)` `:2035`, `playBoth`, `startAutoMix`, `resumeAuto` `:3166`).
**Change:**
1. `NowPlayingArbiter`: add `private weak var preferred: AnyObject?` + `func prefer(_ who: AnyObject?)` + `var onOwnerChanged: ((_ new: AnyObject, _ old: AnyObject?) -> Void)?`. `isActive(who)` becomes `owner === who || (owner == nil && (preferred == nil || preferred === who))`. `claim` fires `onOwnerChanged` when the owner actually changes. Add a `reason:` string parameter to `claim` (default `""`) that rides the existing trace.
2. `SetlistPlayer.restore(from:)` calls `NowPlayingArbiter.shared.prefer(player)` (and `stop()` clears it via `prefer(nil)` when it resigns). The card stays untouched — `updateNowPlayingInfo` is still idle-guarded (`PlayerEngine:778`).
3. `MixEngine`: add `private(set) var hasSoundedThisProcess = false`, set true in `play(_:)`, `playBoth()`, `startAutoMix`, `resumeAuto()` **only when not `isRestoringMixSession`**. The three MPRemoteCommandCenter targets (`:5495-5507`) add `guard self.hasSoundedThisProcess || self.isRunning || self.remotePausedAt != nil`; otherwise log `[transport] rc <cmd> → MixEngine refused (restored, never played)` and return `.commandFailed`. **Do not gate `remotePlay()` itself** — tvOS (`TVRootView` Resume), `CarPlayModel.resumeMix`, and `IntentServices.resumeAutoMix` call it directly as explicit user gestures and must keep working.
**Why safe:** in-app Mix buttons never pass through the command center; a Mix the user actually started claims normally and the preferred owner is only consulted while `owner == nil`. Single-song (non-setlist) plays are unaffected because `prefer` is only set by a setlist restore.
**Test:** `NowPlayingArbiterTests`: owner nil + preferred=A → `isActive(B) == false`, `isActive(A) == true`; claim(B) → `onOwnerChanged(B, nil)`. `MixEngineTests`: restore snapshot + materialize → invoke the play target body → assert `isRunning == false`, no claim, no card publication; then `play(.a)` in-app → target now works.

### P0-3 — Materialize is inert: no session activation, no engine start, not on CarPlay connect, not a write (complaint #2a, snapshot immortality)
**Files:** `Mix/MixEngine.swift` (`ensureEngine` `:1068-1155`, `materializeNow` `:5105-5126`, `restorePersistedMixIfIdle` `:5077-5087`, `restoreDeck` `:5164`), `CarPlay/CarPlayScene.swift:119`, `CarPlay/CarPlayModel.swift:407-417`.
**Change:**
1. `ensureEngine(startNow: Bool = true)`: when `startNow == false` skip `activateAudioSession()` (`:1077`) and `engine.start()` (`:1152`) but still attach/connect/`prepare()`, set `built = true`, register observers + remote targets. `startEngineIfNeeded()` (`:1935`) already does `setActive(true)` + `engine.start()` on the first real `play(_:)` (`:2041-2045`), so the first real transport activates exactly as today. `materializeNow` calls `ensureEngine(startNow: false)`. (`restoreDeck` cues on a not-yet-started engine — the `fileScheduled=false` re-arm at `:5177-5178` exists precisely for that.)
2. Delete `model.materializeMixRestoreIfNeeded()` from `CarPlayScene.buildRoot` (`:119`). Instead `CarPlayModel.pauseMix/resumeMix/skipMixFast/skipMixSlow` call `services.mix.materializePendingRestoreIfNeeded()` first (lazy, on the Mix-tab gesture). The Mix tab rows only need snapshot titles to render — add `MixEngine.parkedRestoreSummary` (titles from `pendingMixRestore`) for `refreshMixTab`.
3. `restorePersistedMixIfIdle`: `if materializeWanted, !setlistIsLive() { materializeNow() }` where `setlistIsLive` is an injected closure (`services.setlistPlayer.isRunning || coordinator.activeBackend != nil`); if skipped, `materializeWanted` stays set and the Mix tab's next gesture materializes.
4. Remove `persistMixDeckSession()` from `materializeNow`'s `defer` (`:5115`) — "a restore is not a write" (the exact rule `SetlistPlayer.restore` documents at `:1924-1941`). Dropped decks re-sync on the next real persist.
5. `restoreDeck`: `if let len = ds.track.lengthMs, ds.positionMs >= len - 500 { cue at 0; mark deckExhaustedFromRestore[deck] = true; DiagLog "mix restore: deck \(d) at end (pos=\(ds.positionMs) len=\(len)) — recued to 0" }` — and `resumeMasterPaused`'s fallback skips an exhausted deck (P0-5).
**Why safe:** tvOS launch materialize (`TVRootView`) still builds the graph; its Resume goes through `play/playBoth → startEngineIfNeeded` which activates. macOS has no `AVAudioSession` (fences unchanged). Studio mic `.playAndRecord` guard in `activateAudioSession` is untouched. `rebuildAfterMediaReset` keeps calling `ensureEngine()` with the default `startNow: true`.
**Test:** `MixEngineTests` with the existing dead-engine seams: materialize a seeded snapshot → assert `engine.isRunning == false`, an injected `audioSessionActivations == 0`, `MixDeckSessionStore.load()?.updatedAt` unchanged; `play(.a)` → activations == 1. CarPlay: `CarPlayModelTests` — `resumeMix()` materializes first.

### P0-4 — Interruption handling is owner-scoped and respects intent (complaint #3, the AM ping-pong)
**Files:** `Mix/MixEngine.swift` (`registerInterruptionHandling` `:6201-6232`, `refreshTransport` `:5555`), `Playback/PlayerEngine.swift` (`configureInterruptionObserver` `:598-620`), `Playback/AppleMusicPlaybackProvider.swift` (expose `pauseWasIntentional` read-only).
**Change (MixEngine):**
1. `.began`: latch `interruptionParked` only if `isRunning && anyDeckAudible` where audible = `position(d) < duration(d) - 0.25` for a playing deck. Trace `[session] interruption began engine=mix running=\(isRunning) owner=\(ownerName) latched=\(…)`.
2. `.ended`: `guard shouldResume, interruptionParked, !isRunning, NowPlayingArbiter.shared.owner === self` (evaluated NOW — at `22:00:23` the mix WAS the owner at `.began`, so a "recorded at began" check would still have resumed it). Trace the verdict.
3. Subscribe to `NowPlayingArbiter.onOwnerChanged`: when the new owner is not self → `interruptionParked = false; masterPausedDecks = []; resumeAutoOnRemotePlay = false` and, if no deck is playing, `engine.pause()` so a silent graph never holds a non-mixable session under MusicKit. Trace `arbiter displaced MixEngine → cleared latches`.
**Change (PlayerEngine):**
4. Observe `.began` too: record `wasPlayingAtInterruption = externalActive ? (externalIsPlaying?() ?? false) : player.rate > 0`; trace it.
5. `.ended`: if `externalActive` → **do not** call `configureAudioSession()` (MusicKit owns the session); resume via `externalPlay()` only if `shouldResume && wasPlayingAtInterruption && !(appleMusicPauseWasIntentional?() ?? false)`. Else (local lane) → `configureAudioSession()` + `play()` only if `shouldResume && wasPlayingAtInterruption && !pausedByListener`. Trace both branches.
**Why safe:** a Mix that genuinely owns the card still auto-resumes after a call (`owner === self`); a user pause before a call stays paused in both lanes (today it un-pauses — `pause()` sets `pausedByListener` only in the local branch `:367`, hence the provider flag for AM). Studio engines have their own observers and are untouched.
**Test:** `MixEngineTests`: run mix → post `.began` → `PlayerEngine` claims → post `.ended(shouldResume)` → `isRunning == false`, owner unchanged. `PlayerEngineTests`: external mode + `pauseWasIntentional=true` → `.ended` → `externalPlay` not invoked, no `setActive`.

### P0-5 — A restored/suspended Auto-DJ is parked, and an end-of-file deck never "plays" (complaint #1b, pattern (e), Mix dead air)
**Files:** `Mix/MixEngine.swift` — `restoreAutoSuspended` `:5188-5226`, `tickFire` `:6017` & `:6023-6031`, `recoverFromEngineStop` `:6086-6136`, `registerRouteChangeHandling` `:6238`, `resumeMasterPaused` `:2109-2124`, `remotePlay` `:2190`, `startEngineIfNeeded` `:1935`.
**Change:**
1. Tick EOF retire: `if pos >= dur, !autoMixing || autoPaused { setPlaying(d,false); stopActiveNodes(d); DiagLog "mix deck \(d) reached end under paused auto — retired" }`.
2. Liveness predicate `var mixWantsAudio: Bool { deckA.isPlaying || deckB.isPlaying || (autoMixing && !autoPaused) }` used by the tick watchdog (`:6023`), `recoverFromEngineStop` (`:6116`), and the route-change observer (`guard mixWantsAudio`). A suspended restore no longer restarts the engine or re-grabs the session on route changes.
3. `resumeMasterPaused`: filter `remembered` and the fallback deck by `position(d) < duration(d) - 0.5 && deckExhaustedFromRestore[d] != true`; if nothing qualifies and `autoMixing && autoPaused` → `resumeAuto()` (loads/transitions to the next queue item) instead of starting silence; log `[mix] remotePlay path=<remembered|fallback|resumeAuto|refused> deck=… pos=… dur=…`. `remotePlay` additionally: `if autoResumeFromRestore, autoMixing, autoPaused { resumeAuto() }` — so a restored session resumed from the lock screen actually advances (today it only restarts the deck and the machine never transitions).
4. `startEngineIfNeeded`: replace `try?` with `do/catch` that logs `[mix] session activate FAILED err=<domain#code> otherAudio=<AVAudioSession.isOtherAudioPlaying>`; the FAILED line in `recoverFromEngineStop` carries the same.
**Why safe:** a running Auto-DJ (`!autoPaused`) keeps full watchdog/recovery; a hand-started deck under a paused machine is still `isPlaying` and keeps recovery; the EOF retire under a paused machine does not fire `endAutoLoop`. `CarPlayModel.resumeMix` already calls `resumeAuto()` after `remotePlay`, so the car path converges.
**Test:** snapshot with deck A at `pos == dur`, auto suspended → `remotePlay()` → no deck `isPlaying` at EOF, `resumeAuto` invoked (next queue item loads); 20 tick fires with the engine stopped → `startEngineIfNeeded` call count 0; post `routeChangeNotification` → 0.

### P0-6 — Keep the setlist as owner across local→next advances; Mix card writer needs real ownership (flash of "Hold On Me", command mis-routing in the gap)
**Files:** `Playback/PlayerEngine.swift` (`clearNowPlayingInfo` `:900-908`, `stop()` `:563+`), `Playback/SetlistPlayer.swift` (`armEngineHooks` `:552`, `stop()` `:595-606`, `:1781`), `Mix/MixEngine.swift` (`updateSystemNowPlaying` `:5419-5432`).
**Change:** `PlayerEngine.holdsOwnershipAcrossTracks = true` set in `armEngineHooks()`/`resumeFromHold`, cleared in `SetlistPlayer.stop()`. `clearNowPlayingInfo` skips `resign(self)` while the flag is set (still clears the card dict and the ♥). `MixEngine.updateSystemNowPlaying` requires `NowPlayingArbiter.shared.owner === self` (it claims in `setPlaying` before writing, so cold-start in-app plays still work).
**Why safe:** the resign only happens on local-lane→next advances (`SetlistPlayer:1781 if coordinator.activeBackend != .appleMusic { player.stop() }`); AM→AM already keeps ownership. `stop()` still resigns, so a finished set frees the card for the Mix.
**Test:** two local rows → simulate end → assert owner stays `PlayerEngine` and no `w=mix` publication.

### P1-7 — Zero dead air at the AM→local boundary (complaint #2b)
**Files:** `Playback/SetlistPlayer.swift` (`playCurrent` local branch `:1751-1760`, cloud branch `:1796-1802`), `Playback/PlayerEngine.swift` (`load` `:252-321`, `itemBecameReady` `:324-339`, `toggle` `:384`, `updateNowPlayingInfo` `:798`), `Playback/NowPlayingCardPublisher.swift`.
**Change:**
1. **Runway until first audio:** `PlayerEngine` gets `onFirstAudio: (() -> Void)?` fired from the rate KVO on the first `rate > 0` after a `load`. `SetlistPlayer` holds a `PlaybackRunway("pocketdj-start-<id>")` for BOTH branches (local file too), ended on first audio or a 25 s cap (inside the 30 s background budget). Log `[runway] begin/end name=… held=<s>`.
2. **Start watchdog:** in `SetlistPlayer`, after any local-lane load arm `armStartStall(gen:)`: at 8 s with `player.timeControlStatus != .playing && !player.pausedByListener` → log `[playback] start-stall song=… waited=8 reason=\(player.reasonForWaitingToPlay) status=\(item.status) err=…` then `configureAudioSession()` + `player.play()` again; at 20 s → reuse the `armResolveStall` ladder (hop to an on-device row, else `advanceToNext(.auto)` through the cascade breaker). Cancel on first audio / skip / pause.
3. `itemBecameReady`: on `.failed` → `signalTrackFailed()` (one-shot latch already exists) so a dead item advances instead of sitting silent.
4. **Honest card:** publish `advancing:false` but `playbackState: .playing` when `isPlaying && isStalled && !pausedByListener` (add an `intentPlaying:` parameter to `NowPlayingCardPublisher.publish` that picks `.playing` for state while keeping rate 0). `toggle()`: `if player.timeControlStatus == .waitingToPlayAtSpecifiedRate && !pausedByListener { play(); return }` — a ▶/⏯ press re-kicks instead of pausing.
5. `load()`: set `item.preferredForwardBufferDuration = 4` (measure first; leave `automaticallyWaitsToMinimizeStalling` default this ship).
6. `configureAudioSession()` (`:583-593`): log the caught error with `domain#code` (DiagLog `playback`).
**Why safe:** the watchdog never fires while `pausedByListener`; a hop counts through the existing `AutoAdvanceCascadeBreaker` so a cellular dead zone still halts after 3 quick advances rather than skipping the whole set; the runway is capped. The discrete `pauseCommand` still pauses a buffering track.
**Test:** `PlayerEngineTests` with a stub URL that accepts a connection and never sends bytes → watchdog re-plays at 8 s, `onStartStalled` at 20 s; 404 stub → `onTrackFailed` within 2 s; stalled+playing → publication `playbackState == .playing`, rate 0. `SetlistPlayerTests`: `PlaybackRunway.activeCount == 1` after a local-lane load until the first-audio hook fires.

### P1-8 — Apple Music interrupted by us: bounded auto-resume (complaint #2a, second half)
**Files:** `Playback/AppleMusicPlaybackProvider.swift` (`.paused` transition `:552-557`, monitor), `Playback/SetlistPlayer.swift`.
**Change:** when the monitor observes `player.state.playbackStatus == .interrupted` (distinct from `.paused`) with `pauseWasIntentional == false`, log `[playback] am interrupted-by-session t=…` and arm a one-shot resume (2 s, then 6 s) that calls `player.play()` only if status is still `.interrupted` and no user pause arrived. Never resume on `.paused` (that is a user/system pause). With P0-3/P0-4/P0-5 in place this should rarely fire; it is the safety net for Siri/nav prompts that end without MusicKit self-resuming.
**Test:** provider test with the injected player seam: `.interrupted` → resume called once; `.paused` → never; `pausePlayback()` then `.interrupted` → never.

### P1-9 — Snapshot hygiene (stale-session immortality)
**Files:** `State/MixDeckSessionStore.swift`, `Mix/MixEngine.swift` (`persistMixDeckSession` `:5245`, position ticks).
**Change:** never persist a position advanced while `tapPulse.lastAudibleAt` is older than 3 s (silent run); `MixDeckSessionStore.load()` drops a snapshot whose live deck is at EOF AND whose auto cursor cannot advance. No wall-clock expiry (a parked mix may legitimately be days old).
**Test:** store test: snapshot with `deckA.positionMs >= lengthMs-500` and empty auto queue → `load()` returns nil.

### Platform fences
- `AVAudioSession` work stays under `#if canImport(UIKit) && !os(macOS)`; interruption/route observers stay `#if os(iOS)` as today. macOS: arbiter/`onIdlePlay`/ownership changes apply (they fix the macOS lock-screen too); no session code.
- tvOS: `ensureEngine(startNow:false)` keeps the graph built at launch; first Resume activates via `startEngineIfNeeded`. `remotePlay()` is NOT gated (TV calls it directly).
- visionOS: same as iOS fences; no CarPlay.

---

## 3. "Keep playing" supervisor — minimal viable version for this ship

`Playback/PlaybackSupervisor.swift`, `@MainActor`, injected next to `WidgetSync` in `PocketDJApp`, 1 Hz tick. **Setlist lane only this ship; Mix gets a detector, not a ladder.**

```
listenerIntent: .playing | .paused    // set ONLY by gestures that reach us:
   PlayerEngine.play/pause/toggle (remote targets, car rows, widget, panel, intents),
   SetlistPlayer.resumeFromHold/startCurrent/stop/haltCascade (→ .paused),
   AppleMusicPlaybackProvider .paused transition with pauseWasIntentional (→ .paused),
   interruption .began (→ .paused, remembering previous), .ended+shouldResume (→ previous).
   Restores and parked snapshots NEVER set .playing.

audibleProof(owner):
   PlayerEngine local: timeControlStatus == .playing && currentTime advanced since last tick
   AM:                 provider.isPlaying && playbackTime advanced
   Mix:                engine.isRunning && tapPulse.lastAudibleAt < 1.5 s ago
```

Invariant: while `intent == .playing` exactly one owner has proof. Ladder, timers reset on proof, inert while `.paused` or during an open interruption:
- **L0** (proof lost): log `[supervisor] silent owner=… lane=… since=…`.
- **L1** at 3 s mid-track / 8 s after a track start: re-kick in place — local: `configureAudioSession()` + `player.play()`; AM: `play()` if status `.interrupted` (never if `.paused`); held setlist: `resumeFromHold()`.
- **L2** at +12 s: `SetlistPlayer.startCurrent()` (re-resolve same row, fresh presign / other provider); for a local-lane row, hop to an on-device row via the existing `armResolveStall` search.
- **L3** at +8 s: `advanceToNext(.auto)` through the cascade breaker. Breaker trip → `[supervisor] halted` + the CarPlay Now Playing card keeps the honest paused state.
- Two owners with proof → pause the non-arbiter-owner, log `[supervisor] double-audio paused=…`.
- **Mix SILENT-PLAYING detector**: any deck `isPlaying` with `engine.isRunning` and `sigAge > 3 s` for 3 consecutive ticks → `setPlaying(d,false)`, publish paused, log `[mix] SILENT-PLAYING deck=… pos=… dur=… xfader=… vol=… stem=…` with the restore suspects. No ladder for Mix this ship.
- End-of-queue continuation (`continuationProvider`) is **deferred** — needs a setting and product decision.

Unit tests: table-driven — put the engines in each state (stub closures for proof/intent), run N ticks with a fake clock, assert the step taken; negative test: `intent == .paused` → zero actions for 60 ticks.

---

## 4. Telemetry to add this ship (so the next drives prove each fix)

All via `DiagLog` (ships to S3); mix heartbeat moves off `dlog`. Also make `NPLog.trace`'s mirror synchronous when already on the main actor (`MainActor.assumeIsolated` path with the `Task` hop only as fallback) so sub-second ordering is trustworthy.

| Category | Line | Where |
|---|---|---|
| `[transport]` | `rc cmd=<play\|pause\|toggle\|next\|prev> engine=<PlayerEngine\|MixEngine> owner=<…> preferred=<…> verdict=<handled\|refused-idle\|not-owner\|restored-never-played\|onIdlePlay→resumeHeld\|onIdlePlay→startCurrent>` | both engines' MPRemoteCommandCenter targets (one line per target invocation — a fan-out shows as two lines) |
| `[action]` | `remote play (pre-restore, Ns ago) → resume held session` | `SetlistPlayer.restore` pending-play consume |
| `[car]` | `mix resume/pause/skip-fast/skip-slow tapped (autoPaused=…)`; `connect sceneState=<fg\|bg> held=<0\|1> mixParked=<0\|1>`; `disconnect` | `CarPlayScene` Mix-tab rows, `didConnect/didDisconnect` |
| `[session]` | `interruption began engine=<player\|mix> wasPlaying=<0\|1> external=<0\|1> owner=<…> latched=<0\|1>`; `interruption ended shouldResume=<0\|1\|missing> engine=… pausedByListener/pauseWasIntentional=<0\|1> action=<resume\|hold\|not-owner>` | both observers |
| `[session]` | `route change reason=<raw> to=<portType> engineRunning=<0\|1> mixWantsAudio=<0\|1> action=<recover\|ignored>` | `MixEngine` route observer |
| `[session]` | `activate by=<player.load\|player.ended\|mix.start\|mix.recover> amActive=<0\|1> result=<ok\|err domain#code>` | every `setActive(true)` site |
| `[playback]` | `track start song=… index=… backend=<appleMusic\|burned\|presigned\|hls\|studio> resumeAtMs=…` | each `playCurrent` branch |
| `[playback]` | `start-stall song=… waited=<s> status=<timeControlStatus> reason=<reasonForWaitingToPlay> itemStatus=… err=… appState=<fg\|bg> runway=<0\|1>` and `start-ok song=… after=<ms>` | `PlayerEngine` watchdog / first-audio hook |
| `[playback]` | `engine.pause local byListener=1` ; `rate→0 cause=<pause\|interruption\|stall\|end\|unknown>` | `PlayerEngine.pause()` + rate KVO when no `pause()` preceded |
| `[playback]` | `am status <playing\|paused\|interrupted\|stopped> t=… intentional=<0\|1>` on every transition | AM monitor (not only the 25-poll heartbeat) |
| `[np]` | `arbiter claim → X (was Y) reason=<load\|play\|beginExternal\|setPlaying\|interruption\|restore>`; `arbiter displaced Y → cleared=[…]`; `arbiter prefer → X` | `NowPlayingArbiter` |
| `[mix]` | `materialize trigger=<mixTab\|carRow\|tv\|launchTask> setlistLive=<0\|1> amActive=<0\|1> session=untouched engineRunning=<0\|1>`; `restore: deck A pos=… len=… xfader=… vol=… stem=… recued=<0\|1>` | `materializeNow`, `restoreDeck` |
| `[mix]` | `remotePlay path=<remembered\|fallback\|resumeAuto\|refused> deck=… pos=… dur=… autoPaused=… fromRestore=…`; `remotePause guard=<pass\|dup>` | `remotePlay/resumeMasterPaused/remotePause` |
| `[mix]` | `hb render=… run=… A=(intent,node,pos,sched) B=(…) tapAge sigAge rp auto/paused` every 15 s while any deck has intent + on transitions; `SILENT-PLAYING deck=… for=<s>`; `engine.start FAILED err=… otherAudio=… category=… route=…` | tick / `startEngineIfNeeded` |
| `[runway]` | `begin/end/EXPIRED name=… held=<s>` | `PlaybackRunway` |
| `[supervisor]` | `silent owner=… lane=… since=…`; `step=L1..L3 action=…`; `ok after=<s>`; 60 s `dead-air total=<s>` | `PlaybackSupervisor` |
| `[np]` | `card PUB … state=<playing\|paused> owner=<…>` (extend the existing line) | `NowPlayingCardPublisher` |

---

## 5. What remains uncertain, and the field data that settles it

1. **Why the restored deck rendered silence at 259 s (`01:19:07`, `sigAge=-1.00`), long before EOF.** Candidates: snapshot crossfader toward B while the cold fallback prefers A; restored stem-mode deck with deferred sources (`applyStemIntent(…deferSourceUntilPlay:true)` at `:5157`); deck volume 0; session interrupted at the moment of play. **Settles it:** the `[mix] restore: deck … xfader= vol= stem=` line + `SILENT-PLAYING` detector + `hb` with `sigAge`.
2. **The 4 of 6 `mix resume (remote seam)` events with no `REFUSED` line (`01:19:06`, `01:29:24`, `18:22:39`, `22:00:05`).** A nil-owner remote ▶ would always also log PlayerEngine's refusal; these were most likely the CarPlay Mix-tab "▶ Resume Mix" row (unlogged today) — i.e. Levi "kicking it" on a tab the head unit restored — or a Siri intent. **Settles it:** `[car] mix resume tapped` + `[transport]` lines.
3. **Whether the AM pause/resume ping-pong (`02:57:39-02:58:09`) is PlayerEngine's `.ended → configureAudioSession()` re-activating under MusicKit, or the driver pressing play repeatedly.** P0-4 removes the activation either way. **Settles it:** `[session] interruption ended … action=` + `[session] activate by=player.ended` + `[playback] am status interrupted`.
4. **AM→local stalls: buffer fill vs first-byte latency vs app suspension.** `17:07:29` (log ends mid-stall, next launch `resumeMs=0`) points at suspension after the runway ended; `19:12:46 [screen] section=home → 19:12:48 rate=1` points at a deferred interruption `.ended` delivered on foreground. **Settles it:** `start-stall reason=… appState= runway=` + `[runway]` lines + `AVPlayerItem.accessLog` bytes/startup on `start-ok`.
5. **Whether `22:05:13` (local rate→0, no action line) and `22:07:08` were Levi's ⏸ or system interruptions.** Irrelevant to the fix but needed to confirm P0-4's `wasPlayingAtInterruption` logic. **Settles it:** `engine.pause local byListener=1` vs `[session] interruption began`.
6. **Head-unit auto-play on connect: discrete `playCommand` (observed — `toggle REFUSED` never appears) vs toggle on other cars.** P0-1 handles both. **Settles it:** `[transport] rc cmd=` with the CarPlay `connect` line's Δt.
7. **Cellular `neverStarted` at 12 s (`01:22:10`)** — could be a dead source or our own session fight. Not shortened this ship. **Settles it:** `[session] activate` lines within the 12 s window + `am status` transitions.

Verification plan for the drive: cold launch with both snapshots present → steering-wheel ▶ must produce `[transport] rc cmd=play … verdict=onIdlePlay→resumeHeld` and audio ≤ 3 s; an AM track playing when the phone is unlocked must show `[mix] materialize … session=untouched` (or no materialize at all) and NO `external PAUSE` within 30 s; a phone call during an AM track must end with `[session] interruption ended … action=resume` on the setlist and `not-owner` on the mix; every AM→local boundary must show `track start … backend=presigned` → `start-ok after=<ms>` with `[runway]` held across it; `grep SILENT-PLAYING` and `grep "dead-air total"` give the drive's remaining dead air as single numbers.