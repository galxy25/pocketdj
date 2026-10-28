package com.levi.pocketdj.screens.games

import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.games.friends.MwFMember
import com.levi.pocketdj.data.games.friends.MwFState
import com.levi.pocketdj.data.games.friends.MwFSuggestion

/**
 * Pure Music with Friends screen rules (iOS `GamesView.expiresLabel` +
 * `MusicWithFriendsSessionView` computed properties), kept free of Compose so they are unit-testable.
 */
object MwFScreenLogic {
    const val THEME_MAX = 144
    val TURN_CHOICES: List<Pair<Int, String>> = listOf(30 to "30 s", 60 to "1 m", 120 to "2 m", 300 to "5 m")
    const val NOT_YOUR_TURN = "Not your turn yet — hang tight."
    const val POLL_INTERVAL_MS = 4_000L
    const val PREVIEW_DEBOUNCE_MS = 300L

    /** "ended" / "ends in 45m" / "ends in 2h 5m" (iOS: minutes floored, hours from 60 up). */
    fun expiresLabel(expiresAtMs: Double, nowMs: Double): String {
        val remaining = expiresAtMs - nowMs
        if (remaining <= 0) return "ended"
        val mins = (remaining / 60_000).toInt()
        return if (mins >= 60) "ends in ${mins / 60}h ${mins % 60}m" else "ends in ${mins}m"
    }

    fun clampTheme(s: String): String = s.take(THEME_MAX)

    /** Defaults seeded from the profile name: (displayName, sessionName). */
    fun defaultNames(profileName: String): Pair<String, String> {
        val n = profileName.trim()
        return if (n.isEmpty()) "Player" to "Music with Friends" else n to "$n's Music with Friends"
    }

    fun canCreate(theme: String, serverUrl: String, creating: Boolean): Boolean =
        !creating && theme.isNotBlank() && serverUrl.isNotBlank()

    /** Whose turn + whether I can suggest right now (the server enforces regardless). */
    fun canSuggestNow(state: MwFState?, youId: String?): Boolean {
        if (state == null) return true
        // Mirrors iOS `st.turn?.memberId == youId` (nil == nil is true).
        if (state.turn?.memberId == youId) return true
        return state.settings?.acceptOutsideTurn ?: false
    }

    /** Leaderboard: score descending (stable for ties). */
    fun sortedMembers(state: MwFState?): List<MwFMember> =
        (state?.members.orEmpty()).sortedByDescending { it.score ?: 0 }

    /** Feed: newest first (seq descending). */
    fun feed(state: MwFState?): List<MwFSuggestion> =
        (state?.suggestions.orEmpty()).sortedByDescending { it.seq ?: 0 }

    fun pendingInbox(state: MwFState?): List<MwFSuggestion> =
        state?.suggestions.orEmpty().filter { it.status == "pending" }

    fun remainingSeconds(deadlineMs: Double, nowMs: Double): Int =
        ((deadlineMs - nowMs) / 1000).toInt().coerceAtLeast(0)

    fun leftLabel(seconds: Int): String = "%d:%02d left".format(seconds / 60, seconds % 60)

    fun memberName(state: MwFState?, id: String?): String =
        state?.members?.firstOrNull { it.memberId == id }?.name ?: "Player"

    /** "Your turn!" vs "<name>'s turn". */
    fun turnHeadline(state: MwFState?, youId: String?): String {
        val turnId = state?.turn?.memberId
        if (turnId != null && turnId == youId) return "Your turn!"
        val name = state?.members?.firstOrNull { it.memberId == turnId }?.name ?: "…"
        return "$name's turn"
    }

    fun waitHint(state: MwFState?): String {
        val name = state?.members?.firstOrNull { it.memberId == state.turn?.memberId }?.name ?: "someone else"
        return "Wait for your turn — $name is up"
    }

    /** +1 is disabled for your own suggestion, one you already +1'd, or an ended session. */
    fun plusOneEnabled(sg: MwFSuggestion, youId: String?, ended: Boolean): Boolean {
        val mine = sg.memberId == youId
        val already = youId != null && (sg.plusOnes ?: emptyList()).contains(youId)
        return !mine && !already && !ended
    }

    /** 409 on suggest is the server's "not your turn". */
    fun suggestErrorMessage(code: Int?, message: String?): String =
        if (code == 409) NOT_YOUR_TURN else message ?: "Couldn't send that suggestion."

    fun collectionLine(count: Int): String = "Session collection · $count song${if (count == 1) "" else "s"}"

    /** "Last updated 2 min ago" body (the screen appends the leading words). */
    fun agoLabel(updatedAtMs: Double, nowMs: Double): String {
        val s = ((nowMs - updatedAtMs) / 1000).toLong().coerceAtLeast(0)
        return when {
            s < 60 -> "$s sec"
            s < 3600 -> "${s / 60} min"
            s < 86_400 -> "${s / 3600} hr"
            else -> "${s / 86_400} d"
        }
    }

    /** Polling stops once the session has ended. */
    fun shouldKeepPolling(state: MwFState?): Boolean = state?.ended != true
}

/** The pending / accepted / rejected capsule. */
@Composable
fun MwFStatusChip(status: String, modifier: Modifier = Modifier) {
    val color = when (status) {
        "accepted" -> Color(0xFF34C759)
        "rejected" -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.tertiary
    }
    Text(
        status,
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.SemiBold,
        color = color,
        modifier = modifier.clip(CircleShape).background(color.copy(alpha = 0.18f))
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}
