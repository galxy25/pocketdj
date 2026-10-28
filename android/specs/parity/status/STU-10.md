state: reviewed

# STU-10 — MIDI input (USB + BLE via MidiManager) + arpeggiator + overdub staffs

## Checklist
- [x] MidiParser (MidiStreamParser: running status/realtime/sysex/split calls; BleMidiParser: timestamps + running status across packets), MidiInput (MidiManager device list, hot-plug, receiver thread -> engine directly), BleMidiScanner (BluetoothLeScanner on MIDI service UUID + openBluetoothDevice -> MidiInput.attach), MidiSettings
- [x] ArpeggiatorEngine: ArpPattern (6 orders, octaves, swing, injected RNG, gate-off, fromPersisted) + transport/program mode (writes nothing)
- [x] OverdubController: OverdubLog (region-confined, loop wrap/layer, held notes close at boundary), OverdubMath (hasOverdubRoom, scoreEndMs, wrapIntoLoop, deadlineDeferred), live extra staffs (cap 4 with primary), deadline tick, re-anchor
- [x] InstrumentEngine hooks: program-mode intercept, overdub-INSTEAD-of-live capture for hand/MIDI/arp, arp strike path, looping replay (backing) with wrapped cursor
- [x] UI: ArpPanel, OverdubControls (loop + monitor-click switches, End overdub, extra staffs), BluetoothMidiSheet + MidiDevicesSection (empty state), Play tab wiring; click/count-in switches now persisted
- [x] Tests: MidiParserTest (19), ArpeggiatorEngineTest (ArpPatternTest 11 + ArpTransportTest 10 + ArpEngineIntegrationTest 4), OverdubInvariantTest (Math 5 + Log 10 + Controller 8) = +67
- Full suite: 4237 JVM tests, 0 failures; assembleDebug green.

## Deviations / notes
- Backing for an overdub pass is the score's events replayed through the synth(s) (polyphonic via one voice per extra staff), looped via the new `replay(loopRegion=)`; NOT a cached-mixdown render at the anchor (no mixdown cache exists on the live score). Equivalent audibly; a mixdown path can replace it behind `OverdubControls.start`.
- Overdub on the free-play LIVE score only anchors at 0 (live staff has no cursor). Saved-take overdub via the ScoreScreen cursor (iOS) is not wired; `OverdubController` takes any `fromMs`/`scoreEndMs` so it is a UI-only follow-up.
- "Save as take" (LiveStaff, STU-9) does not yet include the live overdub extra staffs (they stay in memory; TakeFiler/LiveStaffSave unchanged).
- Touched outside owned files (minimal/additive): `studio/engine/InstrumentEngine.kt` (arp/overdub members, noteOn/noteOff hooks, pump tick, looping replay, release), `screens/producer/instruments/InstrumentsScreen.kt` (panels + persisted click/count-in), `AndroidManifest.xml` (optional `uses-feature` midi + bluetooth_le).
- Hazard hit: `git stash` is repo-wide across worktrees; I popped another package's stash by mistake and fully reverted the resulting conflicts (stash@{0} still intact, SVC-4's). No other worktree was touched.
- docs/ARCHITECTURE-ANDROID.md ledger row updated in review (PARTIAL).

## Device-only / unverified
- USB/BLE MIDI hardware, BluetoothLeScanner permission flow, MidiManager.openBluetoothDevice. Emulator steps NOT run (integrator owns the emulator); expected there: MIDI section shows the empty state.

## Questions for Levi
- None blocking.

## Review
fixes applied. Package status is PARTIAL. JVM tests 4237 -> 4247 (+10), 0 failures; assembleDebug green.
- MAJOR Save as take drops overdub staffs -> fixed. `InstrumentEngine.finishOverdub` runs first, `LiveStaffSave.result(events, instrument, extras)` files staffs 2-4 as `TakeResult.extraStaffs` (TakeFiler adds them via `addOverdubStaff`), the overdub staffs are cleared at tap time, and Save shows whenever any staff has events. Overdub from silence promotes the first extra to primary. Tests: LiveStaffSaveExtrasTest (3), TakeFilerTest.overdubStaffsRideWithTheFiledTake.
- MAJOR leaving Play leaves the pass armed and backing looping -> fixed. PlaySection onDispose calls `engine.finishOverdub`, which stops the capture, the backing replay and the monitor click, and files the staff. Test: OverdubLifecycleTest.leavingPlay...
- MAJOR cursor anchor + take-score overdub missing -> deferred, not fixed. Status is PARTIAL; follow-up package needed (ScoreScreen cursor, `seekLive` re-anchor, overdub on a saved take with cached-mixdown backing). `OverdubController` already accepts any `fromMs`/`scoreEndMs`.
- MINOR staff 1 shares the user's voice -> fixed. Staff 1 gets its own voice via `createVoice` + the current bank (falls back to primary if the bank is missing). The loop wrap only calls `primary.allOff()` when the primary carries backing events. Test: loopWrapNeverSilencesTheUsersVoice...
- MINOR MIDI lifetime / USB pre-plugged -> fixed. `MidiInput` and `BleMidiScanner` now live in StudioGraph (`midiInput`, `bleMidiScanner`); leaving the screen only stops the scan. `MidiInput.start()` connects every non-virtual device that has output ports. Device-only to verify.
- MINOR BLE disconnect by name -> fixed. The scanner records address -> `md.info.id` at attach and disconnects by that id. Device-only to verify.
- MINOR arp stop race -> fixed with the atomic alternative (the Dispatchers.Main alternative was not used so the timing tests keep a single test scheduler). Check + register is atomic under the lock, and an onset that lands after a stop is closed immediately. Tests: ArpStopRaceTest (2).
- MINOR Clear ignores overdub -> fixed. `InstrumentEngine.clearLiveScore` ends an armed pass unfiled, stops the backing and click, and clears the staffs. Test: clearLiveScoreEndsAnArmedPass...
- MINOR docs ledger + test count -> fixed (ledger row PARTIAL, count above).
- NIT shared-file edits -> flagged for the integrator: InstrumentEngine.kt, InstrumentsScreen.kt, StudioGraph.kt (midiInput, bleMidiScanner), TakeRenderer.kt (TakeFiler extras), AndroidManifest.xml.
