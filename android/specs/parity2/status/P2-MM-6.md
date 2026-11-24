state: implemented

# P2-MM-6 Mix Mode ph2c: header toggle + chip + buffer strip, menus, Settings rows

- [x] NpMixModeChip.kt: pure NpMixChipState, chip (np-mix-mode-status) + switch (np-mix-mode), NpMixIndicatorReader, NpMixModeMenuItem (np-menu-mix-mode)
- [x] NpMixBufferStrip.kt: pure dot rule (dot full only when the row's will-play file is local), words, window; strip np-mix-buffer-strip
- [x] NowPlayingDspPanel: header always shown while a session runs; controls dimmed + touch-blocked while buffering; strip under controls; turning Mix Mode on expands once
- [x] MiniPlayerBar long-press + RecordPlayer long-press menus
- [x] Settings > Playback: Start new sessions in Mix Mode, buffer ahead 1/3/5/10, cellular (Off / Next song only / Same as Wi-Fi), iOS copy
- [x] NpMixModeChipStateTest (12 tests); full suite 6413 tests, 0 failures; assembleDebug green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Summary
Mix Mode is one tap from Now Playing; chip shows the iOS words (Ready, Mixing, Buffering 42%, ...) with TalkBack state descriptions; buffer dots; settings persist under the iOS keys.

## Deviations / files touched outside owned set
- NowPlayingDeckCluster.kt: one-line addition passing onDetails + showMixModeMenu to RecordPlayer. The record's long-press now opens a menu (Song details + Mix Mode) instead of opening details directly.
- Chip words are iOS verbatim ("Buffering 42%", "Ready"), not "Buffering 1 of 3" from the roadmap emulator step.
- Ripping states never show (ripping=false): rip-server gate is open (see MM-5 question).
- Menu toggle from the mini bar / record does not auto-expand the panel (iOS does via AppStorage); panel switch does.
- Not run: emulator steps.

## Questions for Levi
- None new (rip-server gate from MM-5 still open).

## Review
- Chip note hard-coded null -> fixed: dead local removed; the edition note is not plumbed (iOS rule-A note has no Android source yet). Recorded as a deviation; the chip/state keep an optional note param.
- Buffer strip hidden until panel expanded -> fixed: strip now shows in the header area whenever Mix Mode is on (so menu toggles show it); `expanded` persistence no longer matters.
- Record long-press: dead outer combinedClickable / Song details with no track -> fixed: outer clickable removed; "Song details" offered only when a track is loaded.
- Mini bar a11y (NIT) -> fixed: added a TalkBack custom action "Mix Mode" opening the menu (combinedClickable kept, needed for long-press).

Build: testDebugUnitTest + assembleDebug green, 6413 tests, 0 failures (no tests added; UI-only changes, no MAJOR).

fixes applied
