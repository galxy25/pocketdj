package com.levi.pocketdj.remote

import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.screens.remote.DiscoveredHost
import com.levi.pocketdj.screens.remote.JoinOutcome
import com.levi.pocketdj.screens.remote.RemoteInvite
import com.levi.pocketdj.screens.remote.RemoteJoinCode
import com.levi.pocketdj.screens.remote.RemoteSessionStarter
import com.levi.pocketdj.screens.remote.StartOutcome
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.IOException
import java.util.UUID

/**
 * The "Over the internet" [RemoteSessionStarter] (P2-REM-10): rooms live on the configured jukebox server's `/remote`
 * relay, so no Nearby permissions and no proximity. The Remote screen offers it only when a jukebox server URL is set
 * ([serverConfigured]). Start = create + join as the room's creator; Join = the 8-character room code.
 */
class BrokerRemoteStarter(
    private val controller: RemoteSessionController,
    private val scope: CoroutineScope,
    private val api: BrokerApi,
    private val serverConfigured: () -> Boolean,
    private val deviceName: () -> String,
    private val log: (String) -> Unit = { NPLog.lane(NPLog.REMOTE, it) },
    private val newParticipantId: () -> String = { UUID.randomUUID().toString() },
) : RemoteSessionStarter {
    override val available: Boolean get() = serverConfigured()

    private val _invite = MutableStateFlow<RemoteInvite?>(null)
    override val invite: StateFlow<RemoteInvite?> = _invite.asStateFlow()

    /** No proximity list on the internet: sessions are joined by code. */
    override val discovered: StateFlow<List<DiscoveredHost>> = MutableStateFlow<List<DiscoveredHost>>(emptyList()).asStateFlow()

    override suspend fun start(mode: RemoteSessionMode): StartOutcome {
        if (!available) return StartOutcome.Failed("Set a jukebox server in Settings to hold sessions over the internet.")
        return try {
            val room = api.create(mode)
            val id = newParticipantId()
            val me = api.join(room.roomId, id, deviceName(), null, room.hostSecret)
            val transport = BrokerRemoteTransport(api, room.roomId, me.participantId, me.secret, scope, initialSince = me.cursor, log = log)
            controller.attach(transport, mode, asHost = true)
            transport.start()
            val invite = RemoteInvite(code = room.joinCode, url = INVITE_PREFIX + room.joinCode)
            _invite.value = invite
            log("broker hosting ${mode.name} room=${room.roomId}")
            StartOutcome.Started(invite)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            StartOutcome.Failed(friendly(e))
        }
    }

    override suspend fun joinWithCode(code: String): JoinOutcome {
        if (!available) return JoinOutcome.Failed("Set a jukebox server in Settings to join sessions over the internet.")
        val parsed = RemoteJoinCode.parse(code) ?: return JoinOutcome.Failed("That doesn't look like a session code.")
        return try {
            val roomId = parsed.lowercase()
            val me = api.join(roomId, newParticipantId(), deviceName(), parsed, null)
            val transport = BrokerRemoteTransport(api, roomId, me.participantId, me.secret, scope, initialSince = me.cursor, log = log)
            controller.attach(transport, BrokerApi.modeOf(me.mode) ?: RemoteSessionMode.LISTEN_TOGETHER, asHost = false)
            transport.start()
            JoinOutcome.Joined
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            JoinOutcome.Failed(friendly(e))
        }
    }

    override suspend fun joinHost(hostId: String): JoinOutcome = JoinOutcome.Failed("Enter the session code to join over the internet.")
    override fun startDiscovery() = Unit
    override fun stopDiscovery() = Unit
    override fun clearInvite() { _invite.value = null }

    companion object {
        const val INVITE_PREFIX = "pocketdj://remote/join-net/"

        /** Plain-language failure text; pure, so the mapping is testable. */
        fun friendly(t: Throwable): String = when {
            t is BrokerHttpException && t.status == 401 -> "That code isn't right, or the server needs a token. Check the session code."
            t is BrokerHttpException && t.status == 404 -> "That session wasn't found. It may have ended."
            t is BrokerHttpException && t.status == 403 -> "That session is full."
            t is BrokerHttpException && t.status == 409 -> "This device is already in that session."
            t is BrokerHttpException && t.status == 429 -> "Too many tries. Wait a minute and try again."
            t is BrokerHttpException && t.status == 503 -> "The server has too many sessions right now. Try again soon."
            t is BrokerHttpException -> "The jukebox server answered ${t.status}."
            t is IOException -> "Couldn't reach the jukebox server. Check the connection and the server address in Settings."
            else -> "Couldn't start the session (${t.message ?: t.javaClass.simpleName})."
        }
    }
}
