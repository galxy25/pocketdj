package com.levi.pocketdj.data.location

/**
 * ANS-LOC-1: which foreground-service types PlaybackService should hold. Media3 always promotes with
 * mediaPlayback only; the location type is ADDED on top only while audio is playing AND places & trips is
 * on AND a while-in-use (coarse or fine) grant exists, so the OS keeps delivering fixes while the app is
 * backgrounded and music plays. Pure so the rule is JVM-tested. (The background "Allow all the time" grant
 * is a separate, additive step - this policy never assumes it.)
 */
object LocationFgsPolicy {
    /** android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK (kept literal for JVM tests). */
    const val TYPE_MEDIA_PLAYBACK = 2
    /** android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION (API 29+). */
    const val TYPE_LOCATION = 8

    /** Whether the location type may be held right now. */
    fun wantsLocationType(playing: Boolean, placesOn: Boolean, whileInUseGranted: Boolean, sdk: Int): Boolean =
        sdk >= 29 && playing && placesOn && whileInUseGranted

    /** The type mask to pass to startForeground. */
    fun types(playing: Boolean, placesOn: Boolean, whileInUseGranted: Boolean, sdk: Int): Int =
        if (wantsLocationType(playing, placesOn, whileInUseGranted, sdk)) TYPE_MEDIA_PLAYBACK or TYPE_LOCATION else TYPE_MEDIA_PLAYBACK

    /** Coarse OR fine counts as while-in-use (an approximate-only grant still yields movement hints). */
    fun whileInUse(coarse: Boolean, fine: Boolean): Boolean = coarse || fine
}

/**
 * Tracks the type mask we last applied. Media3 re-promotes the service (mediaPlayback only) on every
 * notification update, so [onMedia3Promoted] must invalidate the cache or the location type is never re-added.
 */
class FgsTypeTracker {
    private var last = -1
    fun shouldApply(types: Int): Boolean = types != last
    fun applied(types: Int) { last = types }
    fun onMedia3Promoted() { last = -1 }
    fun reset() { last = -1 }
}
