package com.levi.pocketdj.remote

import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * The speaker half of the session (P2-REM-6 binds the real one; the default does nothing): reconcile the local
 * player against the host's state, correct drift, diff local changes into commands. Every callback runs on the
 * session thread (Main), inside the controller's tick / message handling.
 */
interface RemoteSpeakerHooks {
    /** A session attached (a clean slate for the reconciler). */
    fun onAttach() {}

    /** The session ended or this device left. */
    fun onEnd() {}

    /** This device flipped speaker <-> controller. */
    fun onRoleChanged(role: RemoteDeviceRole) {}

    /** The state's row window changed (new revision / hand-over): drop resolutions for the old window. */
    fun onWindowChanged() {}

    /** A state with a NEWER revision than before was accepted (structure changed; a position jump is a session seek). */
    fun onStructuralState() {}

    /** Make the local player match the session (every tick on a speaker, and after every state / heartbeat). */
    fun reconcile() {}

    /** The listener tapped Rejoin after a system pause. */
    fun rejoin() {}
}

/** This device's display name in a session ("Levi’s Pixel 9"). */
object RemoteDevice {
    fun name(owner: String, model: String): String {
        val o = owner.trim()
        return if (o.isEmpty()) model else "$o’s $model"
    }
}

/**
 * The Remote engine (Listen Together + Backseat), app-scoped so a session survives screen changes and keeps a car
 * speaker in sync while the controller phone browses (iOS `RemoteSessionController`; this is the HOST/session half,
 * the speaker reconcile is [RemoteSpeakerHooks], P2-REM-6).
 *
 * ROLES. Session role: the HOST owns the authoritative [RemoteQueueModel] (every command is applied there, then
 * broadcast as a [RemotePlaybackState]); everyone else is a participant. The device that started the session hosts;
 * if it leaves, the remaining participant with the LOWEST id takes over from the last state it saw. Two hosts (a race)
 * resolve by [RemoteElection.shouldYield]. Device role: a SPEAKER plays the session's audio; a CONTROLLER plays
 * nothing (its player is held silent, re-asserted every tick) and forwards local transport to the session.
 *
 * WIRE. The full windowed state goes out on every revision change, to a joiner, and on request; a small heartbeat
 * (revision + position) every 2 s keeps anchors fresh and lets a receiver notice a MISSED revision (-> stateRequest,
 * retried 2 s doubling to 16 s). The encoded state is size-capped at min(60 KB, transport.maxStateBytes) by halving
 * the window.
 *
 * Threading: everything runs on the one thread of [scope] (Main in the app). [tick] is public so tests drive time.
 */
class RemoteSessionController(
    private val target: RemotePlaybackTarget?,
    val resolver: RemoteSongResolver,
    /** Re-read on every hello so a profile rename shows up without a restart. */
    val deviceName: () -> String,
    val platform: String = "android",
    val clock: SharedClock = SharedClock(),
    private val scope: CoroutineScope,
    private val log: (String) -> Unit = { NPLog.lane(NPLog.REMOTE, it) },
) {
    data class Peer(
        val id: String,
        val name: String,
        val role: RemoteDeviceRole,
        val isHost: Boolean,
        val isLocal: Boolean,
        /** Rows in the current window this device can't play. */
        val unavailableCount: Int,
    )

    // ---- Observable state ----
    private val _isActive = MutableStateFlow(false)
    val isActive: StateFlow<Boolean> = _isActive.asStateFlow()
    private val _mode = MutableStateFlow(RemoteSessionMode.LISTEN_TOGETHER)
    val mode: StateFlow<RemoteSessionMode> = _mode.asStateFlow()
    private val _localId = MutableStateFlow<String?>(null)
    val localId: StateFlow<String?> = _localId.asStateFlow()
    private val _hostId = MutableStateFlow<String?>(null)
    val hostId: StateFlow<String?> = _hostId.asStateFlow()
    private val _localRole = MutableStateFlow(RemoteDeviceRole.SPEAKER)
    val localRole: StateFlow<RemoteDeviceRole> = _localRole.asStateFlow()

    /** The latest state (the host's own broadcast on the host). */
    private val _state = MutableStateFlow<RemotePlaybackState?>(null)
    val state: StateFlow<RemotePlaybackState?> = _state.asStateFlow()
    private val _roster = MutableStateFlow<Set<String>>(emptySet())
    val roster: StateFlow<Set<String>> = _roster.asStateFlow()
    private val _peerInfo = MutableStateFlow<Map<String, RemoteHello>>(emptyMap())
    val peerInfo: StateFlow<Map<String, RemoteHello>> = _peerInfo.asStateFlow()
    private val _unavailableByPeer = MutableStateFlow<Map<String, Set<String>>>(emptyMap())
    val unavailableByPeer: StateFlow<Map<String, Set<String>>> = _unavailableByPeer.asStateFlow()

    /** Rows in the current window THIS device can't play (set by the reconciler). */
    private val _localUnavailable = MutableStateFlow<Set<String>>(emptySet())
    val localUnavailable: StateFlow<Set<String>> = _localUnavailable.asStateFlow()
    private val _statusMessage = MutableStateFlow<String?>(null)
    val statusMessage: StateFlow<String?> = _statusMessage.asStateFlow()

    /**
     * This SPEAKER's audio was paused by its own system (a call, headphones unplugged) while the session plays on:
     * it stays silent until the listener presses ▶ or Rejoin. Set by the reconciler (P2-REM-6).
     */
    private val _pausedHere = MutableStateFlow(false)
    val pausedHere: StateFlow<Boolean> = _pausedHere.asStateFlow()

    /** A start in flight (the invite sheet): the next session that arrives is ours to host, in this mode. */
    @Volatile var pendingStartMode: RemoteSessionMode? = null

    /** Capabilities this device advertises in its hello (extensions add theirs at init). */
    var localCaps: List<String> = emptyList()

    /** The speaker half; the default does nothing. */
    var speaker: RemoteSpeakerHooks = object : RemoteSpeakerHooks {}

    val isHost: Boolean get() = _localId.value != null && _localId.value == _hostId.value

    /** The roster as UI rows, ordered by id. */
    val peers: List<Peer>
        get() {
            val local = _localId.value
            return _roster.value.sorted().map { id ->
                val isLocal = id == local
                val hello = _peerInfo.value[id]
                Peer(
                    id = id,
                    name = if (isLocal) deviceName() else (hello?.name ?: "Joining…"),
                    role = if (isLocal) _localRole.value else (hello?.role ?: RemoteDeviceRole.SPEAKER),
                    isHost = id == _hostId.value,
                    isLocal = isLocal,
                    unavailableCount = if (isLocal) _localUnavailable.value.size else (_unavailableByPeer.value[id]?.size ?: 0),
                )
            }
        }

    /** Names of the speaker devices that can't play [rid] (the controller list's warning). */
    fun unavailableDevices(rid: String): List<String> = peers.filter { p ->
        p.role == RemoteDeviceRole.SPEAKER &&
            (if (p.isLocal) rid in _localUnavailable.value else _unavailableByPeer.value[p.id]?.contains(rid) == true)
    }.map { it.name }

    /** The session position of the current row right now (UI scrubber). */
    fun positionNow(): Long {
        val s = _state.value ?: return 0
        return s.positionMs(clock.sharedNow ?: s.anchorSharedTime)
    }

    // ---- Internals ----
    private var transport: RemoteTransport? = null
    private var jobs = ArrayList<Job>()
    private var sessionToken = UUID.randomUUID().toString()

    /** The host's authoritative model. */
    var model = RemoteQueueModel()
        private set
    private var sessionId = "rses_" + UUID.randomUUID()
    private var lastBroadcastAt = 0.0
    private val activityProbes = ArrayList<() -> Boolean>()

    /** Revision of the latest state we hold (-1 none); also what a stateRequest reports. */
    var lastRevision = -1
        private set

    /** The host whose state [state] is (vs [hostId], which an election may set provisionally). */
    var stateHostId: String? = null
        private set
    private var lastPingAt = 0.0
    private var attachedAt = 0.0
    private var lastHelloAt = 0.0
    private val stateRequests = StateRequestTracker()

    /** Local queue row uid -> session rid (the reconciler's mirror, and the host's own seeded rows). */
    val ridByUid = HashMap<String, String>()

    private val extensionHandlers = HashMap<String, (RemoteEnvelope, String) -> Unit>()
    private val sessionObservers = ArrayList<(Boolean) -> Unit>()
    private val controllerSilencers = ArrayList<() -> Unit>()

    private val now: Double get() = clock.localNow()

    /** "My part of the session is live", counted as activity in the host election even with an empty queue. */
    val hostIsActive: Boolean get() = model.rows.isNotEmpty() || activityProbes.any { it() }

    // ---- Lifecycle ----

    /**
     * Enter a session over [transport]. [asHost] = this device started it. [seed] replaces the host's starting model;
     * otherwise a host seeds from whatever its local player is running, so "start Backseat while a set plays" hands
     * that set to the car.
     */
    fun attach(
        transport: RemoteTransport, mode: RemoteSessionMode, asHost: Boolean,
        seed: RemoteQueueModel? = null, autoTick: Boolean = true,
    ) {
        if (_isActive.value) end(leave = true)
        val token = UUID.randomUUID().toString()
        sessionToken = token
        this.transport = transport
        _mode.value = mode
        _isActive.value = true
        _localId.value = transport.localParticipantId
        _roster.value = setOf(transport.localParticipantId)
        _localRole.value = if (mode == RemoteSessionMode.BACKSEAT && asHost) RemoteDeviceRole.CONTROLLER else RemoteDeviceRole.SPEAKER
        attachedAt = now
        lastRevision = -1
        stateHostId = null
        stateRequests.clear()
        _statusMessage.value = null
        resolver.prepare()
        speaker.onAttach()
        if (asHost) becomeHost(seed)
        if (_localRole.value == RemoteDeviceRole.CONTROLLER) silenceLocalAudio()
        jobs += scope.launch { transport.inbound.collect { guarded("handle") { handle(it) } } }
        jobs += scope.launch {
            var seen = false
            transport.participants.collect { ids ->
                guarded("roster") {
                    if (ids.isNotEmpty()) { seen = true; rosterChanged(ids) }
                    else if (seen) { sessionEnded(token) }
                }
            }
        }
        if (autoTick) {
            jobs += scope.launch {
                while (true) {
                    guarded("tick") { tick() }
                    delay(RemoteTuning.TICK_INTERVAL_MS)
                }
            }
        }
        sendHello()
        log("attach mode=${mode.name} host=$asHost")
        for (o in sessionObservers.toList()) o(true)
    }

    /** Run one loop iteration; a throw (a speaker hook, a bad row) is logged, never fatal to the session. */
    internal inline fun guarded(what: String, block: () -> Unit) {
        try { block() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Throwable) {
            log("$what failed: ${e::class.simpleName}: ${e.message}")
        }
    }

    /** Leave the session. Speakers keep playing locally (the music never dies with the session). */
    fun leave() = end(leave = true)

    private fun sessionEnded(token: String) {
        if (token != sessionToken) return
        end(leave = false)
    }

    private fun end(leave: Boolean) {
        if (!_isActive.value) return
        if (leave) transport?.leave()
        jobs.forEach { it.cancel() }
        jobs = ArrayList()
        transport = null
        _isActive.value = false
        _localId.value = null; _hostId.value = null; stateHostId = null
        _state.value = null
        _roster.value = emptySet(); _peerInfo.value = emptyMap(); _unavailableByPeer.value = emptyMap()
        _localUnavailable.value = emptySet()
        model = RemoteQueueModel()
        ridByUid.clear()
        stateRequests.clear()
        _localRole.value = RemoteDeviceRole.SPEAKER
        _pausedHere.value = false
        clock.reset(hostId = null, isHost = false)
        speaker.onEnd()
        log("end leave=$leave")
        for (o in sessionObservers.toList()) o(false)
    }

    /** Flip THIS device between speaker and controller. */
    fun setLocalRole(role: RemoteDeviceRole) {
        if (!_isActive.value || role == _localRole.value) return
        _localRole.value = role
        if (role == RemoteDeviceRole.CONTROLLER) {
            _pausedHere.value = false
            silenceLocalAudio()
        } else {
            ridByUid.clear() // re-mirror from scratch
        }
        speaker.onRoleChanged(role)
        if (role == RemoteDeviceRole.SPEAKER) speaker.reconcile()
        sendHello()
    }

    // ---- Commands (the Remote screen's controls) ----

    /** Issue a command: the host applies it; a participant sends it to the host. */
    fun send(command: RemoteCommand) {
        if (!_isActive.value) return
        val host = _hostId.value
        if (isHost) applyAsHost(command)
        else if (host != null) post(RemoteMessageKind.COMMAND, RemoteCommandMessage.serializer(), RemoteCommandMessage(command = command), RemoteRecipient.Participant(host))
        else _statusMessage.value = "Waiting for the session host…"
    }

    /** Rows for outbound commands from local queue items (stamped with the Apple Music id). */
    fun rows(items: List<QueueItem>): List<RemoteRow> = items.map { RemoteRow(UUID.randomUUID().toString(), resolver.outboundRow(it)) }

    /**
     * A local transport on THIS device while it is a CONTROLLER: refused locally (true) and forwarded to the session
     * instead. False = not a controller: the player handles it as usual. (Bound to [RemoteControllerGate.forwarder].)
     */
    fun interceptLocalTransport(request: RemoteRedirect): Boolean {
        if (!_isActive.value || _localRole.value != RemoteDeviceRole.CONTROLLER) return false
        when (request) {
            RemoteRedirect.PlayPause -> send(RemoteCommand.PlayPause)
            RemoteRedirect.Play -> send(RemoteCommand.SetPlaying(true))
            RemoteRedirect.Pause -> send(RemoteCommand.SetPlaying(false))
            RemoteRedirect.Next -> send(RemoteCommand.SkipNext)
            RemoteRedirect.Previous -> send(RemoteCommand.SkipPrevious)
            is RemoteRedirect.Seek -> send(RemoteCommand.Seek(request.toMs))
            is RemoteRedirect.PlayItems -> {
                // A brand-new set started here becomes the session's set, windowed like a broadcast (a 26k-row set
                // never rides one message).
                val items = request.items
                if (items.isEmpty()) return true
                val i = request.startIndex.coerceIn(0, items.size - 1)
                val lo = maxOf(0, i - RemoteQueueModel.WINDOW_BEHIND)
                val hi = minOf(items.size, i + 1 + RemoteQueueModel.WINDOW_AHEAD)
                if (lo >= hi) return true
                send(RemoteCommand.Play(rows(items.subList(lo, hi)), i - lo))
            }
            is RemoteRedirect.PlayNow -> {
                val r = rows(listOf(request.item))
                send(if (_state.value?.currentRow == null) RemoteCommand.Play(r, 0) else RemoteCommand.PlayNow(r))
            }
            is RemoteRedirect.Jump -> ridByUid[request.uid]?.let { send(RemoteCommand.JumpTo(it)) }
        }
        return true
    }

    // ---- Extension points ----

    /** Handler for a message kind this controller doesn't own (Mix Together rides the same transport). */
    fun registerHandler(kind: String, handler: (RemoteEnvelope, String) -> Unit) { extensionHandlers[kind] = handler }

    /** An extension's "my part of the session is live" probe (see [hostIsActive]). */
    fun registerActivityProbe(probe: () -> Boolean) { activityProbes += probe }

    /** Told true when a session attaches and false when it ends. */
    fun registerSessionObserver(observer: (Boolean) -> Unit) { sessionObservers += observer }

    /** Another local audio engine a CONTROLLER must keep silent (the Mix decks). */
    fun registerControllerSilencer(silence: () -> Unit) { controllerSilencers += silence }

    /** This device is a controller: every local audio engine goes (and stays) quiet. */
    fun silenceLocalAudio() {
        target?.silenceForController()
        for (s in controllerSilencers) runCatching { s() }
    }

    /** The listener tapped Rejoin after a system pause: resume HERE at the session position (a local action). */
    fun rejoinHere() {
        if (!_isActive.value || _localRole.value != RemoteDeviceRole.SPEAKER || !_pausedHere.value) return
        log("rejoin after a system pause")
        speaker.rejoin()
    }

    /** The invite sheet closed. Unless it sent an invite, the pending start is withdrawn (a peer's session isn't ours). */
    fun shareInviteEnded(succeeded: Boolean) {
        if (!succeeded && !_isActive.value) pendingStartMode = null
    }

    fun sendRaw(envelope: RemoteEnvelope, to: RemoteRecipient = RemoteRecipient.All, reliable: Boolean = true) {
        transport?.send(envelope, to, reliable)
    }

    // ---- Speaker-facing setters (P2-REM-6) ----
    fun setPausedHere(v: Boolean) { _pausedHere.value = v }
    fun setLocalUnavailable(rids: Set<String>) { _localUnavailable.value = rids }
    fun setStatus(message: String?) { _statusMessage.value = message }

    // ---- Inbound ----

    fun handle(msg: RemoteInbound) {
        if (!_isActive.value) return
        val env = msg.envelope
        val kind = env.knownKind
        if (kind == null) {
            extensionHandlers[env.kind]?.invoke(env, msg.from) // unknown + unhandled => ignored
            return
        }
        when (kind) {
            RemoteMessageKind.HELLO -> {
                val h = env.decode(RemoteHello.serializer()) ?: return
                val isNew = _peerInfo.value[msg.from] == null
                _peerInfo.value = _peerInfo.value + (msg.from to h)
                _roster.value = _roster.value + msg.from
                if (isNew) sendHello(RemoteRecipient.Participant(msg.from))
                if (isHost) broadcastState(RemoteRecipient.Participant(msg.from))
            }
            RemoteMessageKind.STATE -> {
                val s = env.decode(RemotePlaybackState.serializer()) ?: return
                if (s.hostId != msg.from) return
                receiveState(s)
            }
            RemoteMessageKind.HEARTBEAT -> {
                val hb = env.decode(RemoteHeartbeat.serializer()) ?: return
                if (hb.hostId != msg.from) return
                receiveHeartbeat(hb)
            }
            RemoteMessageKind.STATE_REQUEST -> {
                if (!isHost || env.decode(RemoteStateRequest.serializer()) == null) return
                broadcastState(RemoteRecipient.Participant(msg.from))
            }
            RemoteMessageKind.COMMAND -> {
                if (!isHost) return
                val c = env.decode(RemoteCommandMessage.serializer()) ?: return
                applyAsHost(c.command)
            }
            RemoteMessageKind.PING -> {
                if (!isHost) return
                val p = env.decode(RemotePing.serializer()) ?: return
                post(RemoteMessageKind.PONG, RemotePong.serializer(), clock.pong(p), RemoteRecipient.Participant(msg.from), reliable = false)
            }
            RemoteMessageKind.PONG -> {
                val p = env.decode(RemotePong.serializer()) ?: return
                clock.ingest(p, msg.from)
            }
            RemoteMessageKind.AVAILABILITY -> {
                val a = env.decode(RemoteAvailability.serializer()) ?: return
                _unavailableByPeer.value = _unavailableByPeer.value + (msg.from to a.unavailableRids.toSet())
            }
        }
    }

    private fun receiveState(s: RemotePlaybackState) {
        stateRequests.answered(s.hostId)
        val me = _localId.value
        if (isHost) {
            if (me == null || s.hostId == me) return
            val yield = RemoteElection.shouldYield(
                HostClaim(s.isActiveSession, s.revision, s.hostId),
                HostClaim(hostIsActive, model.revision, me),
            )
            if (!yield) return
            log("yield host to ${s.hostId}")
        } else {
            val cur = stateHostId
            val mine = _state.value
            if (cur != null && s.hostId != cur && mine != null && mine.isActiveSession && !s.isActiveSession) {
                // An EMPTY host while the session we follow is live: never adopt its nothing.
                if (cur in _roster.value) return // the real host is alive: the empty one yields to it
                log("empty host ${s.hostId} after $cur left - taking over with the set")
                takeOverAsHost()
                return
            }
        }
        if (s.hostId != _hostId.value) {
            _hostId.value = s.hostId
            clock.reset(hostId = s.hostId, isHost = false)
            lastRevision = -1
            lastPingAt = 0.0
        }
        if (s.hostId != stateHostId) lastRevision = -1
        if (s.revision < lastRevision) return
        val structural = s.revision > lastRevision
        lastRevision = s.revision
        stateHostId = s.hostId
        _state.value = s
        _mode.value = s.mode
        if (structural) {
            speaker.onWindowChanged()
            speaker.onStructuralState()
        }
        reconcileIfSpeaker()
    }

    private fun receiveHeartbeat(hb: RemoteHeartbeat) {
        if (isHost) {
            // Another device thinks it hosts: get its full state so the yield rule can decide.
            if (hb.hostId != _localId.value) requestState(hb.hostId, hb.revision)
            return
        }
        val s = _state.value
        if (hb.hostId != stateHostId || s == null || hb.revision > lastRevision) {
            requestState(hb.hostId, hb.revision) // a missed revision / a new host
            return
        }
        if (hb.revision != lastRevision) return
        _state.value = s.copy(
            snapshot = s.snapshot.copy(positionMs = hb.positionMs, isPlaying = hb.isPlaying),
            anchorSharedTime = hb.anchorSharedTime,
        )
        reconcileIfSpeaker()
    }

    private fun requestState(host: String, revision: Int) {
        if (!stateRequests.shouldSend(host, revision, now)) return
        post(RemoteMessageKind.STATE_REQUEST, RemoteStateRequest.serializer(), RemoteStateRequest(lastRevision), RemoteRecipient.Participant(host))
    }

    private fun rosterChanged(ids: Set<String>) {
        if (!_isActive.value) return
        val grew = (ids - _roster.value).isNotEmpty()
        _roster.value = ids
        val gone = _peerInfo.value.keys - ids
        if (gone.isNotEmpty()) {
            _peerInfo.value = _peerInfo.value - gone
            _unavailableByPeer.value = _unavailableByPeer.value - gone
        }
        val host = _hostId.value
        if (host != null && host !in ids) electHost()
        if (grew) {
            sendHello()
            if (isHost) broadcastState()
        }
    }

    /**
     * The host is gone: the lowest remaining id takes over. Only ever after a host LEFT: a joiner that simply hasn't
     * heard from its host yet re-hellos instead (see [tick]).
     */
    private fun electHost() {
        val me = _localId.value ?: return
        val winner = RemoteElection.winner(_roster.value) ?: return
        if (winner == me) {
            takeOverAsHost()
        } else {
            _hostId.value = winner // provisional until its first state arrives
            clock.reset(hostId = winner, isHost = false)
            lastRevision = -1
        }
    }

    private fun takeOverAsHost() {
        log("host handover -> ${_localId.value ?: "?"}")
        var seed: RemoteQueueModel? = null
        val s = _state.value
        if (s != null) {
            // The old host's position estimated on ITS clock (our offset still points at it), then re-anchored on
            // ours: the shared timeline changes hands here.
            val pos = s.positionMs(clock.sharedNow ?: s.anchorSharedTime)
            seed = RemoteQueueModel.adopting(s, pos, now).also { it.revision += 1 }
        }
        becomeHost(seed ?: RemoteQueueModel())
    }

    private fun becomeHost(seed: RemoteQueueModel?) {
        val me = _localId.value ?: return
        _hostId.value = me
        stateHostId = me
        clock.reset(hostId = me, isHost = true)
        if (seed != null) {
            model = seed
        } else {
            model = RemoteQueueModel()
            seedModelFromLocalPlayer()
        }
        model.revision = maxOf(model.revision, lastRevision + 1)
        lastRevision = model.revision
        broadcastState()
        reconcileIfSpeaker()
    }

    /**
     * The host's starting model = whatever its own player is running (a window around the current row; rids = the
     * local row uids, so the host's own speaker mirrors with no reload). Rows past the window stay in the local player
     * and refill the model as the set advances ([refillFromLocalSource]).
     */
    private fun seedModelFromLocalPlayer() {
        val t = target ?: return
        if (t.currentItem == null) return
        val lo = maxOf(0, t.currentIndex - RemoteQueueModel.WINDOW_BEHIND)
        val hi = minOf(t.queueCount, t.currentIndex + 1 + RemoteQueueModel.WINDOW_AHEAD)
        model.rows = (lo until hi).map { localRow(t.item(it)) }
        model.index = t.currentIndex - lo
        model.isPlaying = t.isPlaying || t.isTransitioning // a start in flight means ▶
        model.positionMs = t.positionMs
        model.anchor = now
        model.repeatMode = t.repeatMode
        model.shuffleEnabled = false
        model.revision = 1
    }

    private fun localRow(item: QueueItem): RemoteRow {
        ridByUid[item.uid] = item.uid
        return RemoteRow(item.uid, resolver.outboundRow(item))
    }

    // ---- Host ----

    private fun applyAsHost(command: RemoteCommand) {
        if (!isHost) return
        if (model.apply(command, now)) {
            lastRevision = model.revision
            broadcastState()
            reconcileIfSpeaker()
        }
    }

    /**
     * The full state to [recipient] (All also sets this host's own [state]). The WIRE copy is size-capped: the window
     * halves until the encoded envelope fits min(60 KB, transport.maxStateBytes).
     */
    private fun broadcastState(recipient: RemoteRecipient = RemoteRecipient.All) {
        val me = _localId.value
        val tr = transport
        if (!isHost || me == null) return
        val t = now
        val active = hostIsActive
        val full = model.state(me, _mode.value, sessionId, t, sessionActive = active)
        if (recipient == RemoteRecipient.All) {
            val structural = _state.value?.revision != full.revision
            _state.value = full
            lastBroadcastAt = t
            if (structural) speaker.onWindowChanged()
        }
        if (tr == null) return
        val budget = minOf(RemoteTuning.MAX_STATE_BYTES, tr.maxStateBytes)
        val fitted = RemoteElection.fitState(budget) { behind, ahead ->
            model.state(me, _mode.value, sessionId, t, behind = behind, ahead = ahead, sessionActive = active)
        }
        if (fitted.ahead < RemoteQueueModel.WINDOW_AHEAD) log("state window trimmed to ${fitted.ahead} ahead (${fitted.bytes} bytes)")
        tr.send(fitted.envelope, recipient, reliable = true)
    }

    /** The small 2 s beat (see [RemoteHeartbeat]). */
    private fun sendHeartbeat() {
        val me = _localId.value
        if (!isHost || me == null) return
        val t = now
        lastBroadcastAt = t
        post(
            RemoteMessageKind.HEARTBEAT, RemoteHeartbeat.serializer(),
            RemoteHeartbeat(
                revision = model.revision, hostId = me, currentRid = model.currentRow?.rid,
                positionMs = model.position(t), isPlaying = model.isPlaying, anchorSharedTime = t,
                sessionActive = hostIsActive,
            ),
            RemoteRecipient.All, reliable = false,
        )
    }

    /**
     * The model's upcoming tail ran low: pull the next rows from the host's OWN local set (the rows past the seeded
     * window), so a long set keeps going for everyone.
     */
    fun refillFromLocalSource() {
        val t = target ?: return
        if (!isHost || !t.isRunning || model.upcoming.size >= RemoteTuning.HOST_REFILL_BELOW) return
        val lastRid = model.rows.lastOrNull()?.rid ?: return
        val lo = maxOf(0, t.currentIndex)
        val hi = minOf(t.queueCount, lo + RemoteTuning.TAIL_LIMIT * 4)
        if (lo >= hi) return
        val k = (hi - 1 downTo lo).firstOrNull { ridByUid[t.item(it).uid] == lastRid } ?: return
        val more = ArrayList<QueueItem>()
        var i = k + 1
        while (i < t.queueCount && more.size < RemoteTuning.HOST_REFILL_CHUNK) {
            val it = t.item(i)
            if (ridByUid[it.uid] == null) more += it
            i++
        }
        if (more.isEmpty()) return
        log("host refill +${more.size} row(s) from the local set")
        applyAsHost(RemoteCommand.Append(more.map(::localRow)))
    }

    // ---- Tick ----

    /** One beat of the session (0.5 s in production; tests call it directly). */
    fun tick() {
        if (!_isActive.value) return
        val t = now
        if (isHost) {
            val cur = model.currentRow
            val len = cur?.row?.lengthMs
            if (cur != null && model.isPlaying && len != null && model.position(t) > len + RemoteTuning.HOST_ADVANCE_SLACK_MS) {
                applyAsHost(RemoteCommand.Advanced(cur.rid))
            }
            refillFromLocalSource()
            if (t - lastBroadcastAt >= RemoteTuning.HEARTBEAT_MS) sendHeartbeat()
        } else {
            val host = _hostId.value
            if (host != null) {
                val interval = if (clock.samples.size < SharedClock.SAMPLE_CAP) 1_000.0 else 5_000.0
                if (t - lastPingAt >= interval) {
                    lastPingAt = t
                    post(RemoteMessageKind.PING, RemotePing.serializer(), clock.makePing(), RemoteRecipient.Participant(host), reliable = false)
                }
            }
            val me = _localId.value
            if (me != null) {
                when (RemoteElection.joinerAction(_state.value != null, t, attachedAt, lastHelloAt, _roster.value, me)) {
                    RemoteElection.JoinerAction.SELF_HOST -> takeOverAsHost() // alone: there is no host to wait for
                    RemoteElection.JoinerAction.REHELLO -> sendHello() // a live host answers with its state
                    RemoteElection.JoinerAction.NONE -> {}
                }
            }
        }
        when (_localRole.value) {
            RemoteDeviceRole.SPEAKER -> if (target != null) speaker.reconcile()
            RemoteDeviceRole.CONTROLLER -> if (target != null) {
                // Re-assert silence: whatever started since goes quiet again.
                val tg = target
                if (tg != null && (tg.isPlaying || tg.isTransitioning)) tg.silenceForController()
                for (s in controllerSilencers) runCatching { s() } // idempotent
            }
        }
    }

    private fun reconcileIfSpeaker() {
        if (target != null && _localRole.value == RemoteDeviceRole.SPEAKER) speaker.reconcile()
    }

    // ---- Outbound ----

    fun sendHello(to: RemoteRecipient = RemoteRecipient.All) {
        if (to == RemoteRecipient.All) lastHelloAt = now
        post(
            RemoteMessageKind.HELLO, RemoteHello.serializer(),
            RemoteHello(deviceName(), _localRole.value, platform, localCaps.ifEmpty { null }), to,
        )
    }

    fun <T> post(
        kind: RemoteMessageKind, serializer: kotlinx.serialization.KSerializer<T>, body: T,
        to: RemoteRecipient, reliable: Boolean = true,
    ) {
        val tr = transport ?: return
        tr.send(RemoteEnvelope.make(kind, serializer, body), to, reliable)
    }
}
