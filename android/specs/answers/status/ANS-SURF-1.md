state: reviewed

# ANS-SURF-1 Jukebox sessions picker
- [x] JukeboxSessionsPicker.kt: ModalBottomSheet, listSessions rows (name, url, time-left), Refresh, error, empty, "Hosting here"
- [x] Decision matrix (none/same/different/busy); different active -> endAndAwait() then adopt()
- [x] Entry points: CreateView "Host an existing session..." and LiveView "Switch session..."
- [x] 6 JVM tests (JukeboxSessionsPickerLogicTest); full suite 5217 tests green, assembleDebug green

Notes: broker rows carry no start time, so "age" is shown as time until expiry. Emulator step not run (emulator is integrator-owned).

## Questions for Levi
None.

## Review
fixes applied
- MAJOR sheet-scope cancellation mid-switch -> fixed: JukeboxRepository.switchTo() runs end+adopt on the repo scope; sheet ignores dismiss while adoptingId set; endAndAwait rethrows CancellationException. Tests: switchTo ordering, switchTo survives caller-scope cancel.
- MINOR adoptingId never reset -> fixed: moot (switch no longer in sheet scope); failures surface as repository notice.
- MINOR decide() ignored state.starting -> fixed: busy = adoptingId != null || starting; rows disabled.
- MINOR no confirmation on switch -> fixed: AlertDialog 'End "<cur>" and host "<target>"?'.
- NIT timeless label -> fixed (+ test).
- NIT sequencing test -> fixed (repository-level tests with MockWebServer).
Tests: 5217 -> 5219, 0 failures; assembleDebug green.
