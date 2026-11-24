package com.levi.pocketdj.remote

/**
 * The runtime permissions a Nearby Remote session needs (minSdk 35, so no pre-31 location fallback): Bluetooth
 * advertise/scan/connect for discovery and the link, and nearby Wi-Fi devices for the faster Wi-Fi upgrade. They are
 * requested when the user starts or joins a session, after a plain-language rationale ([rationale]).
 *
 * Pure (no Android types) so the policy is unit-testable: the screen passes the granted check in.
 */
object RemotePermissions {
    const val BLUETOOTH_SCAN = "android.permission.BLUETOOTH_SCAN"
    const val BLUETOOTH_ADVERTISE = "android.permission.BLUETOOTH_ADVERTISE"
    const val BLUETOOTH_CONNECT = "android.permission.BLUETOOTH_CONNECT"
    const val NEARBY_WIFI_DEVICES = "android.permission.NEARBY_WIFI_DEVICES"

    val REQUIRED: List<String> = listOf(BLUETOOTH_SCAN, BLUETOOTH_ADVERTISE, BLUETOOTH_CONNECT, NEARBY_WIFI_DEVICES)

    /** Hosting advertises; joining only scans. NEARBY_WIFI_DEVICES is optional (Bluetooth alone still connects, slower). */
    fun requiredFor(hosting: Boolean): List<String> =
        if (hosting) REQUIRED else REQUIRED - BLUETOOTH_ADVERTISE

    /** What is still ungranted, in [REQUIRED] order. */
    fun missing(hosting: Boolean, isGranted: (String) -> Boolean): List<String> = requiredFor(hosting).filterNot(isGranted)

    /** Bluetooth permissions are mandatory for a session; the Wi-Fi one only speeds it up. */
    fun canProceed(grants: Map<String, Boolean>, hosting: Boolean): Boolean =
        requiredFor(hosting).filter { it != NEARBY_WIFI_DEVICES }.all { grants[it] == true }

    fun rationale(hosting: Boolean): String =
        (if (hosting) "To invite people near you, Pocket DJ advertises this session over Bluetooth and Wi-Fi. "
        else "To find the session near you, Pocket DJ scans over Bluetooth and Wi-Fi. ") +
            "It connects phones directly, with no server and no internet, so it works in a car. " +
            "Pocket DJ doesn't use these permissions to find your location."

    const val DENIED_MESSAGE = "Nearby access is needed to start or join a session. You can allow it in Settings."
}
