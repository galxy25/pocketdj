package com.levi.pocketdj.remote

import android.content.Context
import android.content.Intent
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.screens.remote.DiscoveredHost
import com.levi.pocketdj.screens.remote.JoinOutcome
import com.levi.pocketdj.screens.remote.RemoteInvite
import com.levi.pocketdj.screens.remote.RemoteJoinCode
import com.levi.pocketdj.screens.remote.RemoteSessionStarter
import com.levi.pocketdj.screens.remote.StartOutcome
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

/** `ConnectionsClient` behind [NearbyClient]: P2P_STAR, service id [NearbyClient.SERVICE_ID], bytes payloads only. */
class GmsNearbyClient(context: Context) : NearbyClient {
    private val c: ConnectionsClient = Nearby.getConnectionsClient(context.applicationContext)
    @Volatile override var listener: NearbyListener? = null

    private val lifecycle = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            listener?.onConnectionInitiated(endpointId, info.endpointName, info.authenticationDigits, info.isIncomingConnection)
        }
        override fun onConnectionResult(endpointId: String, result: ConnectionResolution) {
            listener?.onConnectionResult(endpointId, result.status.isSuccess)
        }
        override fun onDisconnected(endpointId: String) { listener?.onDisconnected(endpointId) }
    }
    private val discovery = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) { listener?.onEndpointFound(endpointId, info.endpointName) }
        override fun onEndpointLost(endpointId: String) { listener?.onEndpointLost(endpointId) }
    }
    private val payloads = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            payload.asBytes()?.let { listener?.onPayload(endpointId, it) }
        }
        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) = Unit
    }

    private fun guarded(onResult: (Throwable?) -> Unit, block: () -> com.google.android.gms.tasks.Task<Void>) {
        try {
            block().addOnSuccessListener { onResult(null) }.addOnFailureListener { onResult(it) }
        } catch (t: Throwable) { onResult(t) }
    }

    override fun startAdvertising(endpointName: String, onResult: (Throwable?) -> Unit) = guarded(onResult) {
        c.startAdvertising(endpointName, NearbyClient.SERVICE_ID, lifecycle, AdvertisingOptions.Builder().setStrategy(Strategy.P2P_STAR).build())
    }
    override fun stopAdvertising() { runCatching { c.stopAdvertising() } }
    override fun startDiscovery(onResult: (Throwable?) -> Unit) = guarded(onResult) {
        c.startDiscovery(NearbyClient.SERVICE_ID, discovery, DiscoveryOptions.Builder().setStrategy(Strategy.P2P_STAR).build())
    }
    override fun stopDiscovery() { runCatching { c.stopDiscovery() } }
    override fun requestConnection(localName: String, endpointId: String) {
        runCatching { c.requestConnection(localName, endpointId, lifecycle).addOnFailureListener { listener?.onConnectionResult(endpointId, false) } }
            .onFailure { listener?.onConnectionResult(endpointId, false) }
    }
    override fun acceptConnection(endpointId: String) { runCatching { c.acceptConnection(endpointId, payloads) } }
    override fun rejectConnection(endpointId: String) { runCatching { c.rejectConnection(endpointId) } }
    override fun send(endpointId: String, bytes: ByteArray) { runCatching { c.sendPayload(endpointId, Payload.fromBytes(bytes)) } }
    override fun disconnect(endpointId: String) { runCatching { c.disconnectFromEndpoint(endpointId) } }
    override fun stopAll() { runCatching { c.stopAllEndpoints() } }
}

/**
 * The real [RemoteSessionStarter] (P2-REM-9): Start = advertise as the relay host and show the invite; Join = discover
 * the host that advertises the invite's token hash (or connect straight to one picked from the Nearby list).
 * Installed into `RemoteStarters.current` by the Remote graph. Permissions are the screen's job (rationale sheet first).
 */
class NearbyRemoteStarter(
    private val context: Context,
    private val controller: RemoteSessionController,
    private val scope: CoroutineScope,
    private val deviceName: () -> String,
    private val clientFactory: () -> NearbyClient = { GmsNearbyClient(context) },
    private val isEmulator: () -> Boolean = ::isProbablyEmulator,
    private val log: (String) -> Unit = { NPLog.lane(NPLog.REMOTE, it) },
    private val advertiseTimeoutMs: Long = 5_000L,
    private val joinTimeoutMs: Long = 20_000L,
) : RemoteSessionStarter {
    override val available: Boolean = true

    private val _invite = MutableStateFlow<RemoteInvite?>(null)
    override val invite: StateFlow<RemoteInvite?> = _invite.asStateFlow()
    private val _discovered = MutableStateFlow<List<DiscoveredHost>>(emptyList())
    override val discovered: StateFlow<List<DiscoveredHost>> = _discovered.asStateFlow()

    /** "Pixel 9 — 4821": the auth digits both phones show while a connection is being made (compare them). */
    private val _authDigits = MutableStateFlow<String?>(null)
    val authDigits: StateFlow<String?> = _authDigits.asStateFlow()

    private var discoveryClient: NearbyClient? = null

    init {
        controller.registerSessionObserver { active ->
            if (active) RemoteKeepAliveService.start(context) else { RemoteKeepAliveService.stop(context); _authDigits.value = null }
        }
    }

    private fun newTransport(mode: RemoteSessionMode?, hash: String) = NearbyRemoteTransport(
        client = clientFactory(), localParticipantId = UUID.randomUUID().toString(), deviceName = deviceName(),
        sessionMode = mode, tokenHash = hash, scope = scope, log = log,
        onAuthDigits = { name, digits -> _authDigits.value = "$name · $digits" },
    )

    override suspend fun start(mode: RemoteSessionMode): StartOutcome {
        val token = NearbyInvite.newToken()
        val transport = newTransport(mode, NearbyInvite.hash(token))
        var attached = false
        try {
            val advertised = CompletableDeferred<Throwable?>()
            transport.startHosting { advertised.complete(it) }
            val err = withTimeoutOrNull(advertiseTimeoutMs) { advertised.await() }
            if (err != null) {
                if (isEmulator()) log("nearby unavailable on emulator (${err.message}); showing the invite anyway")
                else return StartOutcome.Failed(friendly(err))
            }
            controller.attach(transport, mode, asHost = true)
            attached = true
            val invite = NearbyInvite.invite(token)
            _invite.value = invite
            log("hosting ${mode.name} token-hash=${NearbyInvite.hash(token)}")
            return StartOutcome.Started(invite)
        } finally {
            // Cancelled (or failed) before the session attached: withdraw the pending host start.
            if (!attached) { transport.leave(); _invite.value = null }
        }
    }

    override suspend fun joinWithCode(code: String): JoinOutcome {
        val token = RemoteJoinCode.parse(code) ?: return JoinOutcome.Failed("That doesn't look like a session code.")
        stopDiscovery() // one discovery at a time: the transport runs its own.
        val transport = newTransport(null, NearbyInvite.hash(token))
        return connect(transport) { fail ->
            transport.joinByHash { if (it != null) { fail(it); transport.linked.completeExceptionally(it) } }
        }
    }

    override suspend fun joinHost(hostId: String): JoinOutcome {
        val transport = newTransport(null, NearbyInvite.OPEN_HASH)
        val mode = _discovered.value.firstOrNull { it.id == hostId }?.mode
        return connect(transport, mode) { transport.joinEndpoint(hostId) }
    }

    private suspend fun connect(
        transport: NearbyRemoteTransport, knownMode: RemoteSessionMode? = null, begin: (fail: (Throwable) -> Unit) -> Unit,
    ): JoinOutcome {
        var attached = false
        try {
            val failure = java.util.concurrent.atomic.AtomicReference<Throwable?>()
            begin { failure.set(it) }
            val linked = withTimeoutOrNull(joinTimeoutMs) {
                try { transport.linked.await(); true } catch (e: CancellationException) { throw e } catch (e: Exception) { false }
            }
            if (linked != true) {
                val why = failure.get()
                return JoinOutcome.Failed(
                    when {
                        why != null -> friendly(why)
                        linked == null -> "Couldn't find that session nearby. Check the code and that the host is close by."
                        else -> "The host didn't accept the connection."
                    },
                )
            }
            controller.attach(transport, transport.hostMode ?: knownMode ?: RemoteSessionMode.LISTEN_TOGETHER, asHost = false)
            attached = true
            return JoinOutcome.Joined
        } finally {
            if (!attached) transport.leave()
        }
    }

    override fun startDiscovery() {
        if (discoveryClient != null) return
        val client = clientFactory()
        client.listener = object : NearbyListener {
            override fun onEndpointFound(endpointId: String, endpointName: String) {
                val ep = NearbyInvite.parseEndpointName(endpointName)
                if (ep.hash == null) return // not one of ours
                _discovered.value = _discovered.value.filterNot { it.id == endpointId } + DiscoveredHost(endpointId, ep.deviceName, ep.mode)
            }
            override fun onEndpointLost(endpointId: String) { _discovered.value = _discovered.value.filterNot { it.id == endpointId } }
            override fun onConnectionInitiated(endpointId: String, endpointName: String, authDigits: String, incoming: Boolean) = Unit
            override fun onConnectionResult(endpointId: String, success: Boolean) = Unit
            override fun onDisconnected(endpointId: String) = Unit
            override fun onPayload(endpointId: String, bytes: ByteArray) = Unit
        }
        discoveryClient = client
        client.startDiscovery { err ->
            if (err != null) {
                log(if (isEmulator()) "nearby unavailable on emulator (${err.message})" else "discovery failed: ${err.message}")
                discoveryClient = null
            }
        }
    }

    override fun stopDiscovery() {
        discoveryClient?.let { it.stopDiscovery(); it.listener = null }
        discoveryClient = null
        _discovered.value = emptyList()
    }

    override fun clearInvite() { _invite.value = null }

    private fun friendly(t: Throwable): String = when {
        t.message?.contains("8002") == true || t.message?.contains("ALREADY") == true -> "Another Nearby session is already running. Try again in a moment."
        t is SecurityException -> "Nearby access isn't allowed. Turn on Nearby devices in Settings."
        else -> "Nearby connections aren't available right now (${t.message ?: t.javaClass.simpleName})."
    }

    companion object {
        fun isProbablyEmulator(): Boolean =
            android.os.Build.FINGERPRINT.contains("generic", true) || android.os.Build.FINGERPRINT.contains("emulator", true) ||
                android.os.Build.HARDWARE.contains("ranchu", true) || android.os.Build.HARDWARE.contains("goldfish", true)
    }
}

/**
 * Keeps the process alive (as a `connectedDevice` foreground service) while a Nearby session is attached, so a Backseat
 * controller with no local playback isn't killed in the background. Started/stopped by [NearbyRemoteStarter] from the
 * controller's session observer; best-effort (background-start restrictions are logged, never thrown).
 * DEVICE-VERIFY: that a controller with the screen off stays connected for 10+ minutes.
 */
class RemoteKeepAliveService : android.app.Service() {
    override fun onBind(intent: Intent?): android.os.IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(android.app.NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(android.app.NotificationChannel(CHANNEL, "Remote session", android.app.NotificationManager.IMPORTANCE_LOW))
        }
        val n = android.app.Notification.Builder(this, CHANNEL)
            .setContentTitle("Pocket DJ session active")
            .setContentText("Connected to nearby devices")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        runCatching {
            androidx.core.app.ServiceCompat.startForeground(
                this, NOTIFICATION_ID, n, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        }.onFailure {
            NPLog.lane(NPLog.REMOTE, "keep-alive refused: ${it.javaClass.simpleName} ${it.message}")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL = "remote_session"
        private const val NOTIFICATION_ID = 7421
        fun start(context: Context) {
            runCatching { androidx.core.content.ContextCompat.startForegroundService(context, Intent(context, RemoteKeepAliveService::class.java)) }
                .onFailure { NPLog.lane(NPLog.REMOTE, "keep-alive start failed: ${it.message}") }
        }
        fun stop(context: Context) { runCatching { context.stopService(Intent(context, RemoteKeepAliveService::class.java)) } }
    }
}
