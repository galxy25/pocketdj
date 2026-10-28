state: reviewed

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

## Review
fixes applied
- MAJOR ripFromCloud only on POST /rip → fixed: ripCollection, requestStemify (via ripBody) and stemifyCollection bodies now add the conditional key; MockWebServer tests added for all three (off = key omitted). Per-song fallbacks go through requestRip/requestStemify, so covered.
- MINOR ledger row Planned → fixed: now PARTIAL with the iOS-vs-roadmap deviation noted.
- MINOR field shows raw text → fixed: field rewritten to the clamped value; blank on focus loss restores the stored value.
- MINOR emulator step not run → fixed in JVM: ShellSettingsStoreRoundTripTest writes via AppSettingsStore, reopens a second store on the same file. Emulator not used (integrator owns it); remains an integrator spot-check.
- MINOR AppGraph touchpoint → recorded here as a merge-plan touchpoint: ripConfigProvider must keep `ripFromCloud = settings.get(ShellSettings.RIP_FROM_CLOUD)`. Not making the Config param required (would touch every Config call site in other packages).
- NIT padding assertions → fixed (real 100_000 / 100_001 boundaries).
- NIT iOS vs roadmap numbers → left as iOS; needs Levi's confirmation (see Questions).
Suite: 2893 tests, 0 failures (2889 + 4 new); assembleDebug OK.
