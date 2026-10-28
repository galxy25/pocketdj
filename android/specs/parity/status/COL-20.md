state: implemented

# COL-20 Android location source (Fused + dwell) + Settings rows + wiring

- [x] DwellDetector (pure): 5 min / 150 m dwell, close on radius+accuracy, >3000 m ignored, coarse fixes hint-only
- [x] FusedVisitSource: low-power updates (5 min / 200 m) via PendingIntent receiver + LocationPollWorker (15 min periodic, self-gated)
- [x] LocationSettings: permission mapping (COARSE/FINE => WHEN_IN_USE, +BACKGROUND => ALWAYS), status copy, Settings deep link
- [x] ListeningLocationSection (order 665): toggle (ON needs pockets, OFF never blocked), status, Allow Always / Open Settings, places/trips, Erase
- [x] CollectionsGraph: real ListeningLocationStore replaces Noop provider; onDisabled => store.setEnabled(false) (erases); settleContexts after each ingest; poll worker registered
- [x] Manifest: location permissions + receiver
- [x] Tests: DwellDetectorTest (5), LocationSettingsTest (4, incl. denied => nothing ingested, upload event only plc_ id / no coordinates). Suite 5109 tests, 0 failures.

## Notes / deviations
- Foreground prompt requests COARSE + FINE together (user may choose approximate): a COARSE-only grant has ~km accuracy, so it yields movement hints but no visits (anchor accuracy gate 200 m).
- Detector state is in-memory; after process death the next fix re-anchors (arrival may be recorded later than true, never earlier).
- Files touched outside owned list: none beyond owned (CollectionsGraph, manifest are owned). New: LocationSettings.kt/LocationSettingsTest.kt are in the owned list.
- Device-only: real movement/dwell; emulator via `adb emu geo fix` (needs ~6 min hold, polled by the worker/updates).

## Questions for Levi
- Is approximate-only location acceptable (hints only, no places)? Default: ask for precise too.
