state: implemented

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
