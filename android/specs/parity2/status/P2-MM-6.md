state: in-progress

# P2-MM-6 Mix Mode ph2c: header toggle + chip + buffer strip, menus, Settings rows

- [x] NpMixModeChip.kt: pure NpMixChipState, chip + switch composables, NpMixIndicatorReader (iOS mixModeIndicator inputs), NpMixModeMenuItem
- [x] NpMixBufferStrip.kt: pure dot rule / words / window, reader, strip composable
- [x] NowPlayingDspPanel: header always shown while a session runs; controls disabled+dimmed while buffering
- [x] MiniPlayerBar + RecordPlayer long-press menus (np-menu-mix-mode)
- [x] Settings > Playback: start-in-Mix-Mode, buffer ahead 1/3/5/10, cellular policy
- [x] NpMixModeChipStateTest
- [ ] full build green
