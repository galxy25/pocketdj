package com.levi.pocketdj.studio.midi

import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import com.levi.pocketdj.studio.engine.InstrumentEngine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Where parsed notes go: the instrument engine's own entry points (the SAME ones the on-screen keys use). */
interface MidiNoteSink {
    fun noteOn(note: Int, velocity: Int)
    fun noteOff(note: Int)
}

class EngineMidiSink(private val engine: InstrumentEngine) : MidiNoteSink {
    override fun noteOn(note: Int, velocity: Int) = engine.noteOn(note, velocity)
    override fun noteOff(note: Int) = engine.noteOff(note)
}

/** Apply parsed voice messages to a sink (the shared glue for the USB and BLE paths; pure + testable). */
fun MidiVoice.dispatch(sink: MidiNoteSink) = when (this) {
    is MidiVoice.NoteOn -> sink.noteOn(note, velocity)
    is MidiVoice.NoteOff -> sink.noteOff(note)
}

enum class MidiTransport { USB, BLUETOOTH, VIRTUAL, OTHER }

/** One row of the device list (the Instruments tab's MIDI section). */
data class MidiDeviceRow(val id: Int, val name: String, val transport: MidiTransport, val connected: Boolean)

data class MidiInputState(
    /** False on a device with no MIDI service (the list then explains instead of rendering empty). */
    val supported: Boolean = true,
    val devices: List<MidiDeviceRow> = emptyList(),
    val lastError: String? = null,
) {
    /** Display names of connected sources. */
    val connectedNames: List<String> get() = devices.filter { it.connected }.map { it.name }
}

/** Pure naming rule for a device's list label: product, else manufacturer, else a generic name; never blank. */
fun midiDisplayName(name: String?, product: String?, manufacturer: String?): String =
    listOf(name, product, manufacturer).firstOrNull { !it.isNullOrBlank() }?.trim() ?: "MIDI device"

/**
 * Wired (USB) and Bluetooth-LE MIDI input over `android.media.midi` (iOS: CoreMIDI sources + `BLEMIDIManager`).
 * Lists devices that expose at least one OUTPUT port (a device's output is our input), opens them, connects a
 * [MidiReceiver] whose bytes go through a per-device [MidiStreamParser] straight to the sink ON THE MIDI THREAD —
 * no main-thread hop (a hop adds jitter and can reorder the take's event log). BLE devices arrive through
 * [BleMidiScanner] → [attach].
 */
class MidiInput(private val manager: MidiManager?, private val sink: MidiNoteSink, private val handler: Handler = Handler(Looper.getMainLooper())) {
    private class Open(val device: MidiDevice, val port: MidiOutputPort, val receiver: MidiReceiver)
    private val open = HashMap<Int, Open>()
    private val lock = Any()
    private val _state = MutableStateFlow(MidiInputState(supported = manager != null))
    val state: StateFlow<MidiInputState> = _state.asStateFlow()
    private var registered = false

    private val callback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(device: MidiDeviceInfo) { refresh(); if (device.outputPortCount > 0 && device.type != MidiDeviceInfo.TYPE_VIRTUAL) connect(device.id) }
        override fun onDeviceRemoved(device: MidiDeviceInfo) { close(device.id); refresh() }
    }

    /** Start watching hot-plug events and publish the current list. Idempotent. */
    fun start() {
        val m = manager ?: return
        if (!registered) { m.registerDeviceCallback(callback, handler); registered = true }
        refresh()
    }

    fun stop() {
        manager?.let { if (registered) runCatching { it.unregisterDeviceCallback(callback) } }
        registered = false
        synchronized(lock) { open.keys.toList() }.forEach { close(it) }
        refresh()
    }

    @Suppress("DEPRECATION")
    fun refresh() {
        val m = manager ?: return
        val infos = runCatching { m.devices.toList() }.getOrDefault(emptyList())
        val connected = synchronized(lock) { open.keys.toSet() }
        val rows = infos.filter { it.outputPortCount > 0 }.map { i ->
            val p = i.properties
            MidiDeviceRow(
                id = i.id,
                name = midiDisplayName(p.getString(MidiDeviceInfo.PROPERTY_NAME), p.getString(MidiDeviceInfo.PROPERTY_PRODUCT), p.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER)),
                transport = when (i.type) { MidiDeviceInfo.TYPE_USB -> MidiTransport.USB; MidiDeviceInfo.TYPE_BLUETOOTH -> MidiTransport.BLUETOOTH; MidiDeviceInfo.TYPE_VIRTUAL -> MidiTransport.VIRTUAL; else -> MidiTransport.OTHER },
                connected = i.id in connected,
            )
        }
        _state.update { it.copy(devices = rows) }
    }

    /** Open [deviceId] and start receiving. */
    @Suppress("DEPRECATION")
    fun connect(deviceId: Int) {
        val m = manager ?: return
        if (synchronized(lock) { deviceId in open }) return
        val info = runCatching { m.devices.firstOrNull { it.id == deviceId } }.getOrNull() ?: return
        m.openDevice(info, { dev -> if (dev == null) fail("Couldn't open that MIDI device") else attach(dev) }, handler)
    }

    /** Wire an already-open device (the BLE path hands one over from `openBluetoothDevice`). */
    fun attach(device: MidiDevice) {
        val id = device.info.id
        if (synchronized(lock) { id in open }) { runCatching { device.close() }; return }
        val port = device.openOutputPort(0)
        if (port == null) { runCatching { device.close() }; fail("That MIDI device has no output port"); return }
        val parser = MidiStreamParser()
        val receiver = object : MidiReceiver() {
            override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
                parser.feed(msg, offset, count) { it.dispatch(sink) }
            }
        }
        port.connect(receiver)
        synchronized(lock) { open[id] = Open(device, port, receiver) }
        _state.update { it.copy(lastError = null) }
        refresh()
    }

    fun disconnect(deviceId: Int) { close(deviceId); refresh() }

    private fun close(deviceId: Int) {
        val o = synchronized(lock) { open.remove(deviceId) } ?: return
        runCatching { o.port.disconnect(o.receiver) }
        runCatching { o.port.close() }
        runCatching { o.device.close() }
    }

    private fun fail(msg: String) { _state.update { it.copy(lastError = msg) }; refresh() }
}
