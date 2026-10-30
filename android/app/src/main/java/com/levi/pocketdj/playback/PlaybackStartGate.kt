package com.levi.pocketdj.playback

/**
 * Which session connects start the PLAYBACK-tier app graph inside [PlaybackService] (pure, JVM-tested).
 *
 * System UI binds the service at every device boot for its media-resumption card (`isRecent` browse). That bind is
 * answered from the snapshot file alone (PB-6: no AppGraph), so it must not build the graph, start its loops, or
 * resume a hosted jukebox party. Every other controller (the app itself, Android Auto, a Bluetooth/headset
 * media button via Media3's legacy controller, Assistant) starts it. A later play from the resume card still builds
 * the graph on demand in the resumption restore.
 */
object PlaybackStartGate {
    const val SYSTEM_UI_PACKAGE = "com.android.systemui"

    fun startsGraph(controllerPackage: String?): Boolean = controllerPackage != SYSTEM_UI_PACKAGE
}
