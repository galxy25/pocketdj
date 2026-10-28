package com.levi.pocketdj.data.transfers

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

/** Foreground-worker notification for background burn downloads. */
object TransferNotifications {
    const val CHANNEL_ID = "pdj.transfers"
    const val NOTIFICATION_ID = 7301

    fun title(p: TransferProgress): String =
        if (p.enqueued <= 1) "Downloading…" else "Downloading… ${minOf(p.finished + 1, p.enqueued)} of ${p.enqueued}"

    fun ensureChannel(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW),
            )
        }
    }

    fun build(context: Context, p: TransferProgress): Notification {
        ensureChannel(context)
        return Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title(p))
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setProgress(maxOf(p.enqueued, 1), p.finished, p.enqueued == 0)
            .build()
    }
}
