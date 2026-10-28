state: in-progress

# STU-10 — MIDI input (USB + BLE) + arpeggiator + overdub staffs

## Checklist
- [x] MidiParser (stream + BLE packet parsers, running status), MidiInput, BleMidiScanner, MidiSettings
- [x] ArpeggiatorEngine (ArpPattern math + ArpeggiatorEngine transport/program mode)
- [x] OverdubController (OverdubLog, OverdubMath, live extra staffs), engine hooks + looping replay
- [x] UI: ArpPanel, OverdubControls, BluetoothMidiSheet/MidiDevicesSection, wired into Play tab
- [ ] Tests: MidiParserTest, ArpeggiatorEngineTest, OverdubInvariantTest
