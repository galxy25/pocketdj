package com.levi.pocketdj.screens.producer

/** The seven Producer sub-tabs (iOS StudioSubTab). */
enum class StudioSubTab(val raw: String, val label: String) {
    Samples("samples", "Samples"),
    Loops("loops", "Loops"),
    Sequencer("sequencer", "Sequencer"),
    Instruments("instruments", "Instruments"),
    Cues("cues", "Cues"),
    Demuxer("demuxer", "Demuxer"),
    Tracks("tracks", "Tracks");

    companion object {
        fun fromRaw(raw: String?): StudioSubTab = entries.firstOrNull { it.raw == raw } ?: Samples
        /** Segments go icon-only below this width (dp). */
        const val COMPACT_WIDTH_DP = 600
        fun iconOnly(widthDp: Int): Boolean = widthDp < COMPACT_WIDTH_DP
    }
}
