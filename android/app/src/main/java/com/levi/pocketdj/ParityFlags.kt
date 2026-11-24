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
     * P2-DJ-6: the Now Playing DJ Mode chip and the DJ menu items. `false` until P2-DJ-8 (the transition engine +
     * conductor) lands, so a release cut after the session shell shows nothing the engine can't back.
     */
    val DJ_MODE: Boolean get() = DEBUG_FORCE_DJ_MODE

    /** Debug screen toggle ("Parity: show DJ Mode chip"): lets the emulator drive the DJ-6 shell before P2-DJ-8 flips [DJ_MODE]. */
    @Volatile var DEBUG_FORCE_DJ_MODE: Boolean = false

    /**
     * P2-POC-9: the Pocket wheel inside History > Pockets (Wheel | List). `false` until P2-POC-10 hosts it there.
     * Debug > "Wheel preview" ignores this flag.
     */
    val POCKET_WHEEL: Boolean get() = false
}
