# UI polish pass (feat/android-ui-polish)

Source review: 2026-10-28 capture (71 shots, `android-shots/INDEX.md`). Re-capture: `android-shots-v2/`
(same file names, so the two sets pair up).

## Theme decision
iOS pins `.preferredColorScheme(.dark)` at the app root (`PocketDJApp.swift`), so Android is
**dark-only** too: the system bars always draw light icons (`SystemBarStyle.dark`), whatever the
system light/dark setting is.

## Done
1. **Status/nav bar**: `enableEdgeToEdge(SystemBarStyle.dark(transparent))`; light icons in system light mode.
2. **Onboarding**: the root `LocalContentColor` is `onBackground` (wordmark and step-4 footer were black);
   the outline token is brighter (0x283250 to 0x3A4872), so "Use on this device" and other outlined buttons show.
3. **Piano**: white keys light, black keys dark (iOS: Theme.fg / Theme.bgOverlay).
4. **Browse**: the mode picker has its own full-width row (constant width, single-line labels, no check
   icon); the tool icons moved next to the search field; the placeholder is single-line. The source-chip
   row is a `LazyRow` and scrolls; the right-edge clip is the scroll affordance.
5. **Album art**: root cause: the "Apple Music (Local)" index ships no art (12,726 albums, 0 with
   `coverArt`/`coverArtSources`). iOS falls back to MusicKit artwork (`AlbumArtworkStore`). Android now
   has `data/catalog/AlbumArtworkStore`: a tokenless iTunes lookup by the album's `appleMusicId` (plus the
   first track ids), batched (≤150 ids per call), memoized to `cache/album-art-fallback.json`, with miss
   TTL and backoff. It is used by `AlbumArt` (grid, album detail, mini-player, Up Next, Mix, history rows),
   by notification/lock-screen art and by the widget. 9,854 of 12,726 AM-Local albums carry an id; the rest
   have no id to look up (iOS cannot resolve them either).
6. **Now Playing**: the record chassis matches iOS (bgRaised fill plus a 2 dp accent outline, accent
   tonearm, album cover as the rotating centre label); elapsed / -remaining labels; a BPM + key line; ⟲ and
   ♥ flank the transport for ANY track (the heart seam had never rendered); the shuffle/repeat row shows for
   a Browse single (the first tap folds the single into a one-row run, the same adoption Up Next adds use);
   a single shows an empty "Up next (0)" section with a hint; Up Next rows have art; the redundant ✕ is gone
   (swipe or the ⋮ menu removes a row); the title is one line.
7. **"Queue stopped after ~3 songs"**: this was not a dropped queue. SeedRip is 13 clip rows totalling
   5:46; shot 13 was 19:28:51 and shot 33 was 20:22:30, so the run reached its natural end (iOS
   `advanceToNext` also stops there with repeat off). I re-drove it three times on the emulator (burned
   rows; cloud rows with a concurrent Mix collection download; with Mix, Producer and Games tab visits).
   Every playable row played and the unplayable "Leech" was skipped. The real defect was the deck
   afterwards: the tonearm stayed on the record over "Nothing playing". It now parks off the record. JVM
   test: `QueueRunToEndTest`.
8. **Nav chrome**: **Q7 (Levi 2026-10-29)**: the bottom bar is Browse · History · Collections · More, with
   labels on all four. More is a hub listing Jukebox, Games, Mix and Producer. Deep links and last-section
   restores into a folded section still work and light More (`ShellTabs.owningBarItem`). Pushed screens
   keep their parent tab lit. Re-tapping a lit tab pops to its root. Selection is an accent tint, not the
   64 dp pill that clipped at the edges. Producer shows the selected sub-tab's name under the icon-only
   segments. Game sub-screens get a back arrow and the game title. The duplicate "Mix" title is gone.
9. **Off-palette greys**: every M3 `surfaceContainer*` and container token now maps onto the navy ramp
   (cards, dialogs, sheets, menus).
10. **Row alignment**: Browse and collection song rows use fixed-width key, time and ▶ columns. Unplayable
    rows reserve the ▶ slot.
11. **Mix**: the crossfader and "Play both decks" are pinned under the scrolling decks (always reachable).
    Tempo uses a log2 track, so 1.00× is centred like Pitch 0 (`TempoSliderMapping`, snaps to 1.00×). The
    waveform has a playhead and dims played bars. The load sheet clears the status bar. A deck loaded
    without a crate reads "Load next from…" instead of "Pick a source".
12. **Settings**: iOS-style titled groups (Account, Library & sources, Apple Music & sync, Playback, Mix &
    Jukebox, History & recommendations, Storage, About, Advanced). Advanced (debug + reset) is folded behind
    a "Show advanced" switch, which also reveals the raw source index URLs. "Sync across devices" is
    disabled and off while no sync account exists, with plain copy. Debug button rows wrap (`FlowRow`).
13. **Long-press menu**: a song header (art, title, artist), then Play next, Add to queue and
    Favorite/Unfavorite, then the "Add to playlist" targets and More…, then Select and Copy. Each row has
    its own icon (`ContextAction`). Play next and Add to queue go through the shared `QueueAdd`.
14. **Small items**: Identify shows a status line (Listening…, Identifying…, No match, or the failure).
    Discover's raw "No import server configured" became plain copy. The snackbars say "Set up an import
    server in Settings to do this". Counts pluralize ("1 track"). The pattern editor gives the name its own
    row. The For You tile subtitle fits 2 lines.
- **Q14 (Levi 2026-10-29)**: POST_NOTIFICATIONS is requested contextually on Android 13+ at the first Burn
  or Mix crate pick, once per install, never at launch. Burn **Stop** also calls
  `BurnStore.cancelTransfers` for the burn's songs. Mic, Bluetooth and location were already requested in
  context, and no background-location prompt was added.

## Checked, not a bug
- **History "2 plays"**: the play log on the emulator has no double-recorded plays (only 3 same-song
  pairs within 2 min, all legitimate 40–60 s replays from earlier sessions). The songs were played twice
  across capture sessions.
- **Cues "Interlude / Kid Capri" twice**: SeedRip contains two different "Interlude" rows by Kid Capri.
  The Cues list mirrors the data.
- **Mix Vol 100 % at mid-track**: the range is 0–200 % (iOS `MixEngine` parity: 0–1 attenuation, 1–2 boost
  to +6 dB). Unity is meant to be mid-track.

## Skipped (with reason)
- Separate album Play/Shuffle buttons in album detail, Jukebox "go to Settings" button, Collections
  toolbar labels, and the Rip/Stemify chip icons: these were outside the 14 groups this pass was asked to do.
- Android Auto surface: there is no DHU on the emulator (as in the original review).
