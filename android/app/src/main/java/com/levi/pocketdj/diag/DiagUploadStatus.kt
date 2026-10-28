package com.levi.pocketdj.diag

/** What the Settings ▸ Debug readout shows (wording identical to iOS `DiagLog.UploadStatus`). */
data class UploadStatus(
    val channelEnabled: Boolean,
    val keyPresent: Boolean,
    val lastSuccessAt: Long? = null,
    val lastError: String? = null,
    val lastErrorAt: Long? = null,
    val offReason: String = "release build (uploads disabled by design)",
) {
    /** The most recent outcome was a failure (an error newer than the last success). */
    val failing: Boolean
        get() {
            val errAt = lastErrorAt ?: return false
            if (lastError == null) return false
            return lastSuccessAt?.let { errAt > it } ?: true
        }

    val healthy: Boolean get() = channelEnabled && keyPresent && !failing

    fun summary(nowMs: Long): String {
        if (!channelEnabled) return "off — $offReason"
        fun ago(t: Long?): String {
            if (t == null) return "never"
            val s = maxOf(0L, (nowMs - t) / 1000)
            return when {
                s < 120 -> "${s}s ago"
                s < 7_200 -> "${s / 60}m ago"
                s < 172_800 -> "${s / 3_600}h ago"
                else -> "${s / 86_400}d ago"
            }
        }
        if (!keyPresent) return "DISABLED — no diag key (last ok ${ago(lastSuccessAt)})"
        if (failing) return "FAILING — ${lastError ?: "?"} (last ok ${ago(lastSuccessAt)})"
        return if (lastSuccessAt == null) "ok — no upload yet this install" else "ok — last upload ${ago(lastSuccessAt)}"
    }
}

/** Result of one PUT, classified so a 403 or a transport error is visible. */
sealed interface UploadOutcome {
    data object Ok : UploadOutcome
    data class Http(val code: Int) : UploadOutcome
    data class Transport(val message: String) : UploadOutcome

    val errorText: String?
        get() = when (this) {
            Ok -> null
            is Http -> "HTTP $code"
            is Transport -> message
        }
}
