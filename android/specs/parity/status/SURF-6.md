state: implemented

# SURF-6 — Settings shell rows

- [x] ShellSettings.kt: prefs `defaultRecentlyAddedCount` (iOS default 3650, clamp 1…100000) + `ripFromCloud` (default off); pure clamp/parse
- [x] ProfileSection (order 50, edits `pdj.profile.name`), CollectionsSection (250), ripFromCloudSection in ImportServerSection.kt (305)
- [x] RipServerClient: `Config.ripFromCloud` (default false), `ripBody()` omits key when off, `ripFromCloud:true` when on
- [x] Tests: ShellSettingsRowsTest (6) + RipFromCloudBodyTest (3); suite 2889 green
- Jukebox require-token default: already placed (JukeboxSection.kt), not duplicated.

## Files touched outside the owned list
- di/AppGraph.kt (additive): ripConfigProvider passes `ripFromCloud`.

## Deviations
- Roadmap says count default 50 clamp 1…500; iOS is default 3650, clamp 1…100000. Followed iOS (source of truth).
- Existing importServerSection lives in DataSourcesSection.kt; the toggle is a separate section right after it (ImportServerSection.kt).
- No Android consumer of the recently-added count exists yet; value is persisted only.

## Questions for Levi
- Confirm iOS numbers (3650 / 100000) rather than roadmap's 50 / 500.
