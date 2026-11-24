package com.levi.pocketdj.data.motion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Activity transition registrations vanish on reboot and app update: re-register when opted in and permitted. */
class MotionBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
                runCatching { ActivityTransitionSource.reregisterIfEnabled(context) }
        }
    }
}
