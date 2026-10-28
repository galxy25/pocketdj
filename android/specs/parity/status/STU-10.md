state: implemented

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
- docs/ARCHITECTURE-ANDROID.md NOT edited (integrator).

## Device-only / unverified
- USB/BLE MIDI hardware, BluetoothLeScanner permission flow, MidiManager.openBluetoothDevice. Emulator steps NOT run (integrator owns the emulator); expected there: MIDI section shows the empty state.

## Questions for Levi
- None blocking.
