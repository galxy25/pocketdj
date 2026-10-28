state: merged

# PB-6 Now Playing deck + mini bar upgrade

- [x] RecordMath (in RecordPlayer.kt), RecordPlayer canvas (gold record, accent chassis, tonearm)
- [x] NowPlayingTransport ladder (held -> cascade -> AM -> idle+pending ignored -> idle start -> toggle)
- [x] NowPlayingViewModel (plain class + pure NowPlayingModel.build), NowPlayingSeams, route `nowplaying`
- [x] Screen + deck cluster (np-title/np-artist/np-previous/np-playpause/np-next/np-playback-notice), landscape hides record
- [x] Mini bar: prev/play/next, expand chevron, hides on mixSessionActive seam, Preparing row kept
- [x] Tests: RecordPlayerMathTest (8), NowPlayingViewModelTest (17, includes transport ladder). Suite total 1645, 0 failures.

## Files touched outside owned set (minimal, additive)
- playback/PlaybackController.kt: `val isAppleMusicActive` getter.
- shell/ShellNavigation.kt: mini bar `onExpand` -> NOW_PLAYING_ROUTE, title "Now Playing".

## Deviations
- ViewModel is a plain class (no androidx lifecycle-viewmodel dep); state is derived from app-scoped flows.
- Long-press opens SongDetailSheet only for catalog songs (the sheet shows "Song not found" otherwise; synthesizing a song needs a browse-file change).
- PlaylistsComponents.kt not changed: ▶/🔀 funnels there still route via setlist routes; rewiring to NOW_PLAYING_ROUTE left to the integrator.
- mixSessionActive is a seam (NowPlayingSeams.mixSessionActive) defaulting false; Mix must install it.
- "pausedByCascade" derived as running && !held && nothing loaded && no start pending.
- ♥ defaults to the shared FavoriteToggle; rating/played-list/DSP slots are null until installed.

## Questions for Levi
- None.

## Review
Fixes applied (Opus adversarial review).
- MAJOR tonearm direction: fixed. Clockwise `rotate(arm, pivot)`, new geometry (OUTER 1 deg, INNER 33 deg, arm 0.5s). `RecordMath.tipPosition/tipDistanceFromCentre` + test asserts tip goes from the record rim to the label edge, monotonic, on-chassis.
- MAJOR pausedByCascade: fixed. `SequencerState.pausedByCascade` set when the gate halts an AUTO advance (cleared on start/stop); model also uses `currentNeverSounded`; engineIdle = no loaded item for the CURRENT row. Tests: sequencer halt test, stale-audible ladder test.
- MAJOR PlaylistsComponents funnels: fixed at the shell. The detail-screen funnels (all call `onOpenSetlist(NOW_PLAYING_SETLIST_ID, true)`) now start the run via `playSetlist` and navigate to NOW_PLAYING_ROUTE (ShellNavigation `openSetlist`); PlaylistsComponents.kt itself holds no ▶/🔀 callbacks, so it needed no change.
- MAJOR long-press synthesized song: fixed. `SongDetailSheet(fallback = MinimalSong)` shows title/artist/length + favorite/add/share for off-catalog rows.
- MINOR no-set record frozen: fixed (record spins when the audible Browse single is the deck identity).
- MINOR deck stale inputs: fixed (`vm.togglePlayPause(vm.currentInputs())`).
- MINOR heart appleMusicId: fixed (seam takes appleMusicId; SongFacts/UiState carry it).
- MINOR mini bar: fixed (`mixSessionActiveFlow` StateFlow collected; bar hidden on the Now Playing route).
- MINOR ledger doc: rejected for this package commit: docs/ARCHITECTURE-ANDROID.md is outside the owned set and integrator-owned; open items (mix seam install) listed here.
- NIT platter angle: fixed (rememberSaveable). NIT notice: fixed (caption under the transport).
