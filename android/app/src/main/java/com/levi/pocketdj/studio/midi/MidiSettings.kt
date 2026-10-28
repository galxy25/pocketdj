package com.levi.pocketdj.studio.midi

import com.levi.pocketdj.data.settings.PrefKey

/**
 * Instruments-tab preferences added with MIDI/arp/overdub (STU-10). Names mirror the iOS SettingsStore fields
 * (`studioClickEnabled`, `studioCountInEnabled`, `studioArp*`, `studioOverdub*`) and are frozen once shipped.
 */
object MidiSettings {
    /** Metronome CLICK during take recording (ON by default). */
    val CLICK_ENABLED = PrefKey.boolean("studioClickEnabled", true)
    /** 1-bar COUNT-IN before a take (ON by default). */
    val COUNT_IN_ENABLED = PrefKey.boolean("studioCountInEnabled", true)
    /** MONITORING metronome for free play + overdub passes (OFF by default; never reaches a take/render/score). */
    val OVERDUB_CLICK_ENABLED = PrefKey.boolean("studioOverdubClickEnabled", false)
    /** An overdub pass LOOPS its confined region (OFF = a single pass). */
    val OVERDUB_LOOP = PrefKey.boolean("studioOverdubLoop", false)

    val ARP_ORDER = PrefKey.string("studioArpOrder", "up")
    /** ArpStepLength denominator: 4/8/16/32. */
    val ARP_LENGTH = PrefKey.int("studioArpLength", 16)
    val ARP_OCTAVES = PrefKey.int("studioArpOctaves", 1)
    val ARP_SWING = PrefKey.double("studioArpSwing", 50.0)
    val ARP_LATCH = PrefKey.boolean("studioArpLatch", true)
}
