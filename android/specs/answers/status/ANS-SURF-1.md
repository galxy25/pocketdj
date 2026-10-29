state: implemented

# ANS-SURF-1 Jukebox sessions picker
- [x] JukeboxSessionsPicker.kt: ModalBottomSheet, listSessions rows (name, url, time-left), Refresh, error, empty, "Hosting here"
- [x] Decision matrix (none/same/different/busy); different active -> endAndAwait() then adopt()
- [x] Entry points: CreateView "Host an existing session..." and LiveView "Switch session..."
- [x] 6 JVM tests (JukeboxSessionsPickerLogicTest); full suite 5217 tests green, assembleDebug green

Notes: broker rows carry no start time, so "age" is shown as time until expiry. Emulator step not run (emulator is integrator-owned).

## Questions for Levi
None.
