state: merged

# P2-SURF-9 Auto Mix tab live controls + jukebox QR artwork

- [x] AutoMixKind FX_GLIDE, AUDIO_GLIDE, FX_SLOT, TEMPO_DOWN/UP, PITCH_DOWN/UP, STEMS, STEM_MUTE, SHORTFALL, SESSION_QR
- [x] AutoMixExtras gains controls()/setupControls() + setters (defaulted, so old fakes unchanged); AppAutoMixExtras wires lead (live) deck engine APIs
- [x] Stem mute with stems off turns stems on first; tempo/pitch rows non-playable + ignored mid-transition; shortfall copy
- [x] AutoJukeboxQr (zxing PNG -> FileProvider content://, hostKey stripped), session children = QR row + URL row
- [x] AutoControlsTest: 18 new tests; full suite 7673 tests, 0 failures; assembleDebug green

## Summary
Live rows (after Stop): shortfall, FX Glide, Audio Glide (= Android mixGlide), one row per lead-deck FX slot, Tempo -/+ (0.01), Pitch -/+ (1 st), Stems + 4 mutes. Lead deck = AutoDj liveDeck (iOS nowPlayingDeck). Controls only act while facade.autoMixing.

## Deviations / files touched outside owned set
- di/MixGraph.kt: added `engineBuilt()` (additive) so setup glide rows never build the engine.
- auto/AutoLibraryCallback.kt: one-line artwork change to pass content:// QR artwork through (https rule unchanged for everything else).
- Pre-Start (setup) glide/shortfall rows only show once the engine exists (a car connect must not build it); live always shows them.
- Disabled rows are expressed as playable=false + "Available between transitions" (AutoNode has no enabled flag).
- Jukebox QR lives in the session node (QR row + URL row), as iOS pushes a QR template per session; Jukebox node itself is present pre-start and live. FileProvider paths already cover cache (file_paths.xml unchanged).
- URI read permission granted best-effort to gearhead/gms/GSA packages; unverified on DHU.

## Questions for Levi
- None blocking. DHU check needed: QR artwork size/readability and whether the host can read the content:// URI.

## Review
- Catalog shortfall hidden pre-engine (AppAutoServices.setupControls) → fixed: shortfall returned whenever downloadStateIfBuilt() has one; new AutoMixControls.glideKnown=false hides (and un-taps) only the glide rows until the engine exists. Test setupShortfall_showsWithoutGlideRows_whenEngineNotBuilt (7673 → 7674 tests).
- notifyMix before async mutation → rejected: the `main` scope is already Dispatchers.Main.immediate, so launch from the main thread runs the setter synchronously before notifyMix(); no lag on the main-thread path.
- Stale cached lead deck → fixed: leadDeck() now reads AutoDj.liveDeck (live internal var) instead of ui.value.liveDeck.
- NIT hostKey denylist → rejected: the broker hostKey is a Bearer header (JukeboxClient), never in a guest URL; listSessions URLs carry none. The strip stays as defense in depth.

fixes applied
