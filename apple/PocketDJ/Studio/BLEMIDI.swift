import SwiftUI
import CoreBluetooth

// MARK: - Cross-platform Bluetooth-LE MIDI input (I3)

/// Scans for Bluetooth-LE MIDI keyboards, connects them, and parses the BLE-MIDI packet stream into
/// note-on / note-off, feeding `InstrumentEngine` directly — the SAME entry points the on-screen
/// keys use, so a BT keyboard plays the current instrument and records into a take exactly like the
/// keys. Built on **CoreBluetooth**, which is universal, so this works identically on iPhone, iPad,
/// Mac, and Vision Pro (unlike the iOS-only `CABTMIDICentralViewController`). No CoreMIDI source is
/// created — we own the connection — so there's no double-triggering with the wired-MIDI path.
///
/// Delegate callbacks arrive on the main queue (`CBCentralManager(queue: .main)`), i.e. the main
/// actor's executor, so the `nonisolated` delegate methods `assumeIsolated` back onto it safely.
@Observable
@MainActor
final class BLEMIDIManager: NSObject {
    /// The standard BLE-MIDI GATT service + its data characteristic (Apple / MMA "MIDI over BLE").
    static let midiService = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    static let midiCharacteristic = CBUUID(string: "7772E5DB-3868-4112-A1A9-F2669D106BF3")

    struct Device: Identifiable, Equatable {
        let id: UUID
        var name: String
        var connected: Bool
    }

    private(set) var devices: [Device] = []
    private(set) var scanning = false
    private(set) var poweredOn = false

    /// Where parsed notes go — set by the view to the live `InstrumentEngine`.
    weak var engine: InstrumentEngine?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// Running MIDI status byte, carried across packets for running-status streams.
    private var runningStatus: UInt8 = 0

    /// Create the central (lazily, so the Bluetooth permission prompt only fires when the user
    /// opens the picker) and start scanning once it's powered on.
    func start() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        scanIfReady()
    }
    func stopScan() { central?.stopScan(); scanning = false }
    func connect(_ id: UUID) { if let p = peripherals[id] { central?.connect(p) } }
    func disconnect(_ id: UUID) { if let p = peripherals[id] { central?.cancelPeripheralConnection(p) } }

    private func scanIfReady() {
        guard let central, central.state == .poweredOn else { return }
        scanning = true
        central.scanForPeripherals(withServices: [Self.midiService])
    }

    private func upsert(_ p: CBPeripheral) {
        let name = p.name ?? "MIDI keyboard"
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) { devices[i].name = name }
        else { devices.append(Device(id: p.identifier, name: name, connected: p.state == .connected)) }
    }
    private func setConnected(_ id: UUID, _ on: Bool) {
        if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].connected = on }
    }

    /// Parse one BLE-MIDI packet → note-on / note-off. Header byte + a timestamp byte before each
    /// message; running status supported; non-note channel messages are consumed but ignored.
    private func parse(_ b: [UInt8]) {
        guard b.count >= 3 else { return }
        var i = 1                                   // skip the header byte
        while i < b.count {
            if b[i] & 0x80 != 0 { i += 1; if i >= b.count { break } }   // skip a timestamp-low byte
            var status = runningStatus
            if i < b.count && b[i] & 0x80 != 0 { status = b[i]; runningStatus = status; i += 1 }
            switch status & 0xF0 {
            case 0x90, 0x80:                        // note on / off — 2 data bytes
                guard i + 1 < b.count else { return }
                let note = Int(b[i] & 0x7F), vel = Int(b[i + 1] & 0x7F); i += 2
                if status & 0xF0 == 0x90 && vel > 0 { engine?.noteOn(note, velocity: vel) }
                else { engine?.noteOff(note) }
            case 0xA0, 0xB0, 0xE0: i += 2           // aftertouch / CC / pitch-bend — skip
            case 0xC0, 0xD0:       i += 1           // program / channel-pressure — skip
            default:               i += 1           // realtime / unknown — skip
            }
        }
    }
}

extension BLEMIDIManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated {
            poweredOn = c.state == .poweredOn
            if poweredOn { scanIfReady() } else { scanning = false }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { peripherals[p.identifier] = p; upsert(p) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            p.delegate = self
            p.discoverServices([Self.midiService])
            setConnected(p.identifier, true)
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { setConnected(p.identifier, false) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { setConnected(p.identifier, false) }
    }
}

extension BLEMIDIManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in p.services ?? [] where s.uuid == Self.midiService {
                p.discoverCharacteristics([Self.midiCharacteristic], for: s)
            }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for ch in s.characteristics ?? [] where ch.uuid == Self.midiCharacteristic {
                p.setNotifyValue(true, for: ch)     // subscribe to the note stream
            }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic,
                                error: Error?) {
        guard let data = ch.value else { return }
        MainActor.assumeIsolated { parse([UInt8](data)) }
    }
}

// MARK: - Picker sheet

/// The Connect-Bluetooth-MIDI sheet: a live scan list with Connect / Connected per keyboard. Wires
/// the manager to the live `InstrumentEngine` so paired notes sound + record. Cross-platform.
struct BluetoothMIDIView: View {
    @Bindable var manager: BLEMIDIManager
    var instruments: InstrumentEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if manager.devices.isEmpty {
                        Text(manager.poweredOn
                             ? "Scanning for Bluetooth MIDI keyboards… put yours in pairing mode."
                             : "Turn on Bluetooth to find MIDI keyboards.")
                            .font(.caption).foregroundStyle(Theme.fgDim)
                    }
                    ForEach(manager.devices) { d in
                        Button {
                            if d.connected { manager.disconnect(d.id) } else { manager.connect(d.id) }
                        } label: {
                            HStack {
                                Label(d.name, systemImage: "pianokeys")
                                Spacer()
                                Text(d.connected ? "Connected" : "Connect")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(d.connected ? Theme.accent2 : Theme.accent)
                            }
                        }
                        .accessibilityIdentifier("ble-midi-device")
                    }
                } header: {
                    Text("Bluetooth MIDI")
                } footer: {
                    Text("Pair a keyboard here, then play — its notes drive the current instrument, exactly like the on-screen keys, and record into a take when you're recording.")
                }
            }
            .navigationTitle("Bluetooth MIDI")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { manager.engine = instruments; manager.start() }
        .onDisappear { manager.stopScan() }
    }
}
