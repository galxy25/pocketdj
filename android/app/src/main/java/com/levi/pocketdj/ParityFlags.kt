package com.levi.pocketdj

/**
 * Release-safety switches for the parity-2 program (design doc section 1.3).
 *
 * A release can be cut after any wave, and some UI lands before its engine. That UI is gated on a constant
 * declared here, which stays `false` (the surface is hidden) until the ENGINE package flips it:
 *
 * | Flag | Added by | Flipped by |
 * |---|---|---|
 * | `DJ_MODE` | P2-DJ-6 | P2-DJ-8 |
 * | `POCKET_WHEEL` | P2-POC-9 | P2-POC-10 |
 * | `REMOTE` | P2-REM-7 | P2-REM-9 |
 * | `MIX_TOGETHER` | P2-REM-13 | P2-REM-13 |
 *
 * Each package adds its own `const val` line below (additive, so no two packages edit the same line) and the
 * engine package flips it. Engine-only packages (pure planners, analysers, transport) have no user-visible
 * surface and need no flag.
 */
object ParityFlags {
    /**
     * P2-DJ-6: the Now Playing DJ Mode chip and the DJ menu items. P2-DJ-8 built the transition engine + conductor, but the
     * flip to a constant `true` waits for the emulator verification (`adb logcat -s PocketDJ.dj`, one History play of the
     * incoming, `deadair cause=dj` with gap near 0). Flipped to `true` by the wave-7 integrator after the
     * emulator run (`[dj] transition`, `advance at fade start`, `deadair cause=dj gap=0.02s`). [DEBUG_FORCE_DJ_MODE] is now moot.
     */
    val DJ_MODE: Boolean get() = true

    /** Debug screen toggle ("Parity: show DJ Mode chip"): turns the DJ surface and engine on for emulator verification before [DJ_MODE] is flipped. */
    @Volatile var DEBUG_FORCE_DJ_MODE: Boolean = false

    /**
     * P2-POC-9: the Pocket wheel inside History > Pockets (Wheel | List). `false` until P2-POC-10 hosts it there.
     * Debug > "Wheel preview" ignores this flag.
     */
    val POCKET_WHEEL: Boolean get() = false

    /**
     * P2-REM-7: the Remote half of the Jukebox panel (Listen Together / Backseat). `false` until P2-REM-9 (a real
     * transport) flips it; the hub (P2-REM-8) hides the Hero | Remote switch while it is off.
     */
    val REMOTE: Boolean get() = false
}
