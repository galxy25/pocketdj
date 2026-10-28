state: reviewed

# SURF-9 - Android Auto Mix tab + Jukebox session rows
- [x] auto/AutoMixTab.kt: pure Mix tab (AutoMixKind ids, AutoMixExtras port, AutoMixTab over MixFacade). Setup: Deck A ("Choose a crate…"), Deck B ("Same as Deck A"), "▶ Start Mix" (subtitle "Pick Deck A first"), download row. Live: status row ("n / count · Deck X", Paused/Buffering prefix), New Mix, Pause/Resume (decided at tap time), quick/long skip, Stop. Crate pickers grouped Pockets / Playlists / Set lists. Jukebox node: GET /sessions via cached fetch (10 s throttle, notify on change), name + Live/Timeless, child row = join URL text; unreachable/empty iOS message rows.
- [x] AutoBrowseTree: AutoId.Mix codec, optional `mix` param; Mix tab appended to root only when wired (hidden otherwise).
- [x] AutoLibraryCallback: binds tab change notifications to notifyChildrenChanged; select routes Mix rows, toasts outcome.
- [x] AppAutoServices.kt (additive): AppAutoMixExtras over engine/collections/JukeboxGraph; PlaybackService wires `mix` from ShellActions.mixFacade (additive, 4 lines).
- [x] Tests: AutoMixTabTest 18 new; suite 4717, 0 failures; assembleDebug green.

## Files touched outside owned list
- auto/AppAutoServices.kt (new class appended), playback/PlaybackService.kt (tree construction passes `mix`).

## Notes / deviations
- Remote lock-screen/Auto transport next/previous already map to fast (5 s) / slow (skipFade) skips through MixSessionPlayer/MixTransportRouter (LOCK-1); not re-implemented.
- MixFacade has no stop/skip/status, so those come from the AutoMixExtras port (production reads AutoDj). Change notifications are a 1.5 s signature-filtered poll that never builds the Mix engine unless a mix is already running (parked mix stays parked on connect).
- Glide toggles / FX / tempo / pitch / stem rows from CarPlay are not included (spec lists only crates, start, status, pause/resume, jukebox).
- Device-only: DHU rendering, real head unit, real Mix audio.

## Questions for Levi
- None.

## Review
- AppAutoMixExtras.downloadState missing -> fixed (reads MixGraph.downloadStateIfBuilt(), never builds; in poll signature). Car-visible via the Downloading row; zero-start toast kept.
- crates() re-derivation -> fixed (uses MixCrateMenuState.entries; group() keeps that order, no lowercase re-sort).
- Picker is playable items / flatten / DHU -> partially fixed: group nodes re-notified on pick; flattening deferred. DHU behaviour is device-only, unverified.
- Poll runs forever -> fixed partly: backs off to 5 s when idle (no mix, no pull), KDoc corrected. Full subscribe-driven lifecycle not done.
- Stale GROUP/root/session lists -> fixed (old+new group notified; root re-notified via poll signature flip; last loaded sessions kept for the URL page).
- NIT files outside owned list -> noted for merge plan (PlaybackService.kt, AppAutoServices.kt, di/MixGraph.kt now also touched); ledger row for orchestrator.
- NIT copy -> fixed (strings aligned with iOS; status row playable no-op).

fixes applied. Tests: 4720 run, 0 failed (+3 new in AutoMixTabTest).
