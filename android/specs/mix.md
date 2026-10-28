# Mix integrations contract (MIX-16)

How the Mix touches the rest of the app on Android. iOS reference files are named per section; port behavior, not structure.

## 1. Mix plays -> History (`mix/engine/MixPlayOutcomeBridge.kt`)
iOS: `State/MixPlayOutcomeBridge.swift`, `Mix/MixEngine.swift` (`onSongPlayed`, `onDeckTrackEnded`).
- `engine.onSongPlayed(songId, deck)` fires once per deck load. The bridge emits `PlayStarted(source = "mix", contextName = AutoDj.sourceLabel)` on `PlayEventBus`; `PlayHistoryStore` records it like any play, so History tags Mix plays with the crate name.
- Android difference: the store records off the bus asynchronously, so the event id is resolved by a short poll (`pickEvent`: exact `playedAt` stamp, else on the last attempt the newest local row inside the 30 s re-count window). An end that races the resolution is held and applied when it lands.
- Mapping is keyed by DECK, never song id (repeat-one holds one song on both decks).
- `onDeckTrackEnded(songId, played, duration, reason, deck)`: `noteListened(fraction)` (max-merged by the store); `markSkipped` + cumulative `noteSkip` only for `SKIP`/`REPLACED` with fraction < 0.5 (strict). `NATURAL`/`STOPPED` never skip. Unknown (0) duration reports nothing. First end per event wins (bounded ended-set, 256). An already-skipped event is re-marked but not re-counted.
- Installed in `MixGraph.installOutcomeBridge` when the engine is built.

## 2. Jukebox <-> Mix (`data/jukebox/MixJukeboxSource.kt`, `JukeboxRepository.kt`)
iOS: `Jukebox/JukeboxStore.swift` (`stateSnapshot`, `acceptIntoMix`, `drainPendingMixInserts`); engine seams in `mix/engine/AutoQueueSeams.kt`.
- While an auto mix runs it owns the setlist: the state POST carries `onAirTrack` (+ position/duration) and `autoUpcoming`; hear-mode (`streamUrl`) is unchanged and still gated on a public rip.
- Accepted requests (playable match) go to `MixJukeboxSource.place` first: `AutoDj.autoQueueInsert(next|end|random)`, never before `committedBound` (in-mix actions win). Not auto-mixing -> returns false and the ExoPlayer sequencer path is unchanged.
- A song a deck cannot load yet (not burned, not streamable) kicks `BurnStore.burn` and parks a pending insert (15 min TTL), landed from the loop tick (`drainPending`); a mix that ended meanwhile lets it go.
- Engine access is Main-confined: the repository hops with `onMain` (no hop when no mix seam).
- `MixJukeboxSeam.source` is set by `MixGraph.init`; the port never builds the engine.

## 3. MixFacade (`mix/MixFacadeImpl.kt`)
iOS: `IntentServices.mix`, `MixResolver`, `CollectionMixDownloader`.
- Assigned to `ShellActions.mixFacade` in `ShellGraph`. Delegates to `MixAutoStarter` (same path as the Mix tab): download run kicked BEFORE the empty-loadables guard; settings pushed before a headless start; an empty crate with no run to supply a track throws `NoBurnedSongs`; pending start allowed only with `allowPendingStart && downloads.isActive`.
- Pause/resume use the lock-screen seam (`AutoDj.remotePause/remotePlay`), the only pause that freezes the transition clock; posted to Main.
- `MixAutoStarter` single-crate start gained the same empty guard as the two-crate branch (it previously armed a pending start unconditionally).
