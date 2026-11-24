package com.levi.pocketdj.data.motion

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity
import com.levi.pocketdj.data.pockets.wheel.MotionToken
import java.io.File

/**
 * Registers Activity Recognition Transition updates (ENTER/EXIT of RUNNING, WALKING, ON_BICYCLE, IN_VEHICLE, STILL) to
 * [MotionTransitionReceiver] through a mutable PendingIntent. Registrations do not survive reboot or an app update, so
 * this is re-run on app start, BOOT_COMPLETED and MY_PACKAGE_REPLACED ([MotionBootReceiver]). No GPS, no FGS.
 */
class ActivityTransitionSource(private val context: Context) : ListeningMotionStore.Source {

    @SuppressLint("MissingPermission")
    override fun register() {
        if (!hasPermission(context)) return
        runCatching {
            ActivityRecognition.getClient(context).requestActivityTransitionUpdates(buildRequest(), pendingIntent(context))
        }
    }

    @SuppressLint("MissingPermission")
    override fun unregister() {
        runCatching { ActivityRecognition.getClient(context).removeActivityTransitionUpdates(pendingIntent(context)) }
    }

    companion object {
        const val ACTION = "com.levi.pocketdj.MOTION_TRANSITION"

        val TRACKED = listOf(
            DetectedActivity.RUNNING, DetectedActivity.WALKING, DetectedActivity.ON_BICYCLE,
            DetectedActivity.IN_VEHICLE, DetectedActivity.STILL,
        )

        /** DetectedActivity type -> [MotionToken]; null for types we do not request (ON_FOOT, TILTING, UNKNOWN). */
        fun tokenFor(activityType: Int): String? = when (activityType) {
            DetectedActivity.RUNNING -> MotionToken.RUNNING
            DetectedActivity.WALKING -> MotionToken.WALKING
            DetectedActivity.ON_BICYCLE -> MotionToken.CYCLING
            DetectedActivity.IN_VEHICLE -> MotionToken.AUTOMOTIVE
            DetectedActivity.STILL -> MotionToken.STATIONARY
            else -> null
        }

        fun hasPermission(context: Context): Boolean =
            context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED

        private fun buildRequest(): ActivityTransitionRequest {
            val ts = TRACKED.flatMap { a ->
                listOf(ActivityTransition.ACTIVITY_TRANSITION_ENTER, ActivityTransition.ACTIVITY_TRANSITION_EXIT).map { t ->
                    ActivityTransition.Builder().setActivityType(a).setActivityTransition(t).build()
                }
            }
            return ActivityTransitionRequest(ts)
        }

        /** Mutable: the transition result is written into the intent extras. */
        private fun pendingIntent(ctx: Context): PendingIntent {
            val i = Intent(ctx, MotionTransitionReceiver::class.java).setAction(ACTION)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            return PendingIntent.getBroadcast(ctx, 0, i, flags)
        }

        /** Boot/replace path: no graph needed. Re-registers only when opted in and permitted. */
        fun reregisterIfEnabled(context: Context) {
            if (ListeningMotionStore.readEnabled(File(context.filesDir, ListeningMotionStore.FILE_NAME))) {
                ActivityTransitionSource(context).register()
            }
        }
    }
}
