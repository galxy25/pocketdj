package com.levi.pocketdj.studio.midi

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.media.midi.MidiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.UUID

/** One advertised BLE-MIDI peripheral. */
data class BleMidiDevice(val address: String, val name: String, val connected: Boolean = false, val connecting: Boolean = false)

data class BleScanState(
    val scanning: Boolean = false,
    val poweredOn: Boolean = false,
    val needsPermission: Boolean = false,
    val devices: List<BleMidiDevice> = emptyList(),
    val error: String? = null,
)

/** Pure list-merge rules for the scan list (a re-advertisement updates in place; the list stays name-sorted + stable). */
object BleMidiList {
    fun upsert(list: List<BleMidiDevice>, address: String, name: String?): List<BleMidiDevice> {
        val label = if (name.isNullOrBlank()) "MIDI keyboard" else name
        val i = list.indexOfFirst { it.address == address }
        return if (i >= 0) list.toMutableList().also { it[i] = it[i].copy(name = if (name.isNullOrBlank()) it[i].name else label) }
        else list + BleMidiDevice(address, label)
    }
    fun setConnected(list: List<BleMidiDevice>, address: String, connected: Boolean) =
        list.map { if (it.address == address) it.copy(connected = connected, connecting = false) else it }
    fun setConnecting(list: List<BleMidiDevice>, address: String, connecting: Boolean) =
        list.map { if (it.address == address) it.copy(connecting = connecting) else it }
}

/**
 * Bluetooth-LE MIDI keyboards (iOS `BLEMIDIManager`): scans for the standard MIDI-over-BLE GATT service
 * UUID with `BluetoothLeScanner`, and connects through `MidiManager.openBluetoothDevice` — the platform owns the
 * GATT session and parsing; the opened device is handed to [MidiInput.attach] so USB and BLE share one path.
 */
class BleMidiScanner(private val context: Context, private val midiManager: MidiManager?, private val input: MidiInput) {
    private val _state = MutableStateFlow(BleScanState())
    val state: StateFlow<BleScanState> = _state.asStateFlow()
    private val handler = Handler(Looper.getMainLooper())
    private val devicesByAddress = HashMap<String, BluetoothDevice>()
    private var scanCallback: ScanCallback? = null

    private val adapter: BluetoothAdapter? get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    fun hasPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    }

    /** Runtime permissions the sheet must request before [start]. */
    fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    @SuppressLint("MissingPermission")
    fun start() {
        val a = adapter
        if (a == null) { _state.update { it.copy(error = "This device has no Bluetooth.", poweredOn = false) }; return }
        if (!hasPermission()) { _state.update { it.copy(needsPermission = true) }; return }
        _state.update { it.copy(needsPermission = false, poweredOn = a.isEnabled, error = null) }
        if (!a.isEnabled) return
        val scanner = a.bluetoothLeScanner ?: run { _state.update { it.copy(error = "Bluetooth scanning is unavailable.") }; return }
        stopScan()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                devicesByAddress[result.device.address] = result.device
                val name = runCatching { result.scanRecord?.deviceName ?: result.device.name }.getOrNull()
                _state.update { it.copy(devices = BleMidiList.upsert(it.devices, result.device.address, name)) }
            }
            override fun onScanFailed(errorCode: Int) { _state.update { it.copy(scanning = false, error = "Bluetooth scan failed ($errorCode).") } }
        }
        scanCallback = cb
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(MIDI_SERVICE)).build()
        scanner.startScan(listOf(filter), ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), cb)
        _state.update { it.copy(scanning = true) }
    }

    @SuppressLint("MissingPermission")
    fun stopScan() {
        val cb = scanCallback ?: return
        scanCallback = null
        runCatching { adapter?.bluetoothLeScanner?.stopScan(cb) }
        _state.update { it.copy(scanning = false) }
    }

    @SuppressLint("MissingPermission")
    fun connect(address: String) {
        val m = midiManager ?: return
        val dev = devicesByAddress[address] ?: return
        _state.update { it.copy(devices = BleMidiList.setConnecting(it.devices, address, true)) }
        m.openBluetoothDevice(dev, { md ->
            if (md == null) _state.update { it.copy(devices = BleMidiList.setConnecting(it.devices, address, false), error = "Couldn't connect to that keyboard.") }
            else { input.attach(md); _state.update { it.copy(devices = BleMidiList.setConnected(it.devices, address, true), error = null) } }
        }, handler)
    }

    /** Disconnect = close the MidiInput source that wraps this peripheral. */
    fun disconnect(address: String, midiDeviceId: Int?) {
        midiDeviceId?.let { input.disconnect(it) }
        _state.update { it.copy(devices = BleMidiList.setConnected(it.devices, address, false)) }
    }

    companion object {
        /** The standard BLE-MIDI GATT service (Apple / MMA "MIDI over BLE"). */
        val MIDI_SERVICE: UUID = UUID.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
        val MIDI_CHARACTERISTIC: UUID = UUID.fromString("7772E5DB-3868-4112-A1A9-F2669D106BF3")
    }
}
