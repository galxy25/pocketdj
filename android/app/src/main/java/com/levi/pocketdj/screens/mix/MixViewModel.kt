package com.levi.pocketdj.screens.mix

import androidx.compose.runtime.Immutable
import com.levi.pocketdj.mix.MixSettings
import com.levi.pocketdj.mix.MixSettingsPush
import com.levi.pocketdj.mix.MixSettingsSink
import com.levi.pocketdj.mix.engine.AutoUiState
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.random.Random

// ---------------------------------------------------------------------------------------------
// Ports: the slice of the engine / downloader / collections the Mix shell drives. Interfaces so
// the shell logic is JVM-testable without audio (adapters live in di/MixGraph.kt).
// ---------------------------------------------------------------------------------------------

/** The Auto-DJ + engine facts and commands the Mix screen uses. */
interface MixEnginePort : MixSettingsSink {
    val autoMixing: Boolean
    val isRunning: Boolean
    var autoEnabled: Boolean
    val autoUi: StateFlow<AutoUiState>

    fun startAutoMix(items: List<AutoMixItem>, shuffled: Boolean, lead: Double, fade: Double, label: String?)
    fun skipToNext(fadeSeconds: Double)
    fun pauseAuto()
    fun resumeAuto()
    fun stopAutoMix()
    fun setFXGlide(on: Boolean)
    fun setMixGlide(on: Boolean)

    fun prepare()
    fun materializePendingRestore()
}

/** The collection download run (app-scoped; survives leaving the tab). */
interface MixDownloadPort {
    val isActive: Boolean
    fun begin(sources: List<MixSource>)
    fun noteAutoStarted(initialIds: Set<String>, lead: Double, fade: Double, label: String?, shuffled: Boolean)
    fun handleMixLeave(engineActive: Boolean)
}

/** Crate -> loadable tracks / display name. */
interface MixCratePort {
    fun loadables(source: MixSource): List<MixLoadable>
    /** null when the crate no longer exists. */
    fun name(source: MixSource): String?
}

// ---------------------------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------------------------

/** Skip button: SINGLE tap = the Settings skip fade, DOUBLE tap = a fast 5 s sweep. */
object SkipGesture {
    const val FAST_FADE_SECONDS = 5.0

    fun fadeSeconds(taps: Int, skipFadeSeconds: Double): Double =
        if (taps >= 2) FAST_FADE_SECONDS else skipFadeSeconds
}

/** Two-crate queue building (iOS `IntentServices.startAutoMix(deckA:deckB:)`), pure. */
object AutoMixPlan {
    const val DEFAULT_DURATION_MS = 180_000

    class Queue(val items: List<AutoMixItem>)

    /**
     * B loses every song A already holds; each crate is shuffled on its own when [shuffle];
     * rows then interleave A0,B0,A1,B1… with per-item provenance ([AutoMixItem.sourceLabel]).
     */
    fun interleave(
        a: List<MixLoadable>, b: List<MixLoadable>, nameA: String, nameB: String,
        shuffle: Boolean, random: Random,
    ): Queue {
        val aIds = a.mapTo(HashSet()) { it.songId }
        var aa = a
        var bb = b.filter { it.songId !in aIds }
        if (shuffle) { aa = aa.shuffled(random); bb = bb.shuffled(random) }
        val out = ArrayList<AutoMixItem>(aa.size + bb.size)
        for (i in 0 until maxOf(aa.size, bb.size)) {
            if (i < aa.size) out += item(aa[i], nameA)
            if (i < bb.size) out += item(bb[i], nameB)
        }
        return Queue(out)
    }

    fun item(l: MixLoadable, label: String? = null) =
        AutoMixItem(l, l.lengthMs ?: DEFAULT_DURATION_MS, label)
}

/** Nothing in the crate(s) is on this device and no download run can supply a first track. */
class NoLoadableSongsException(val crateName: String) : Exception("No songs in $crateName are on this device yet")

/** What [MixAutoStarter.start] did. [count] = queued tracks (0 ⇒ zero-start pending the first landing). */
data class MixStartOutcome(val name: String, val count: Int)

/**
 * Starts an Auto mix from one or two crates (iOS `MixView.startAuto` + `IntentServices.startAutoMix`).
 * The download run is kicked BEFORE the empty-loadables guard so an unburned crate starts pulling
 * and the mix begins on the first landing.
 */
class MixAutoStarter(
    private val engine: MixEnginePort,
    private val downloads: MixDownloadPort,
    private val crates: MixCratePort,
    private val random: Random = Random.Default,
) {
    suspend fun start(
        a: MixSource, b: MixSource?, shuffle: Boolean, allowPendingStart: Boolean, settings: MixSettings,
    ): MixStartOutcome {
        val lead = settings.autoMixLeadSeconds
        val fade = settings.autoMixFadeSeconds
        val nameA = crates.name(a) ?: "Set list"
        val twoCrates = b != null && b != a
        if (!twoCrates) {
            downloads.begin(listOf(a))
            val loadables = crates.loadables(a)
            val items = loadables.map { AutoMixPlan.item(it) }
            // Shuffle is applied in the engine so order/shuffle share one path.
            engine.startAutoMix(items, shuffle, lead, fade, nameA)
            downloads.noteAutoStarted(loadables.mapTo(HashSet()) { it.songId }, lead, fade, nameA, shuffle)
            return MixStartOutcome(nameA, items.size)
        }
        val bSrc = checkNotNull(b)
        val nameB = crates.name(bSrc) ?: "Set list"
        val name = "$nameA + $nameB"
        downloads.begin(listOf(a, bSrc))   // BEFORE the guard, registering BOTH crates (union run)
        val la = crates.loadables(a)
        val lb = crates.loadables(bSrc)
        if (la.isEmpty() && lb.isEmpty() ) {
            if (allowPendingStart && downloads.isActive) {
                downloads.noteAutoStarted(emptySet(), lead, fade, name, shuffle)
                return MixStartOutcome(name, 0)
            }
            throw NoLoadableSongsException(name)
        }
        val queue = AutoMixPlan.interleave(la, lb, nameA, nameB, shuffle, random)
        engine.startAutoMix(queue.items, false, lead, fade, name)
        downloads.noteAutoStarted(queue.items.mapTo(HashSet()) { it.loadable.songId }, lead, fade, name, shuffle)
        return MixStartOutcome(name, queue.items.size)
    }
}

// ---------------------------------------------------------------------------------------------
// The screen's state holder
// ---------------------------------------------------------------------------------------------

/** Per-tab view state (iOS MixView `@State`). Sources are crates the decks browse; nil = none yet. */
@Immutable
data class MixScreenState(
    /** Per-deck load source (the track loader's list). */
    val sourceA: MixSource? = null,
    val sourceB: MixSource? = null,
    /** The GLOBAL crate Auto plays end-to-end. */
    val autoSource: MixSource? = null,
    /** Crate B for a two-crate Auto mix; nil or == A ⇒ "Same as Crate A". */
    val autoSourceB: MixSource? = null,
    val autoStartError: String? = null,
    /** Auto/Manual toggle (top bar). */
    val autoEnabled: Boolean = false,
    /** Which deck's track-loader sheet is open. */
    val loaderDeck: Deck? = null,
) {
    /** B is a real second crate only when it differs from A. */
    val autoCrateB: MixSource? get() = autoSourceB?.takeIf { it != autoSource }

    /** Every crate the auto mix pulls from; the downloader tracks the UNION. */
    val autoDownloadSources: List<MixSource>
        get() = autoSource?.let { a -> autoCrateB?.let { listOf(a, it) } ?: listOf(a) } ?: emptyList()
}

/**
 * Mix-tab logic: crate selection funnels (auto crates -> sync deck sources + begin download; deck
 * sources -> begin download), Auto start, settings pushes, tab-leave rule. App-scoped (held by
 * MixGraph) so selections survive tab switches and rotation. The download PROGRESS is deliberately
 * not here: only `DownloadBar` collects the downloader's state, so a progress tick never
 * recomposes the screen or an open crate menu.
 */
class MixViewModel(
    private val engine: MixEnginePort,
    private val downloads: MixDownloadPort,
    private val crates: MixCratePort,
    private val settingsFlow: Flow<MixSettings>,
    private val scope: CoroutineScope,
    random: Random = Random.Default,
) {
    private val starter = MixAutoStarter(engine, downloads, crates, random)
    private val _state = MutableStateFlow(MixScreenState(autoEnabled = engine.autoEnabled))
    val state: StateFlow<MixScreenState> = _state.asStateFlow()
    val autoUi: StateFlow<AutoUiState> get() = engine.autoUi

    private val _settings = MutableStateFlow(MixSettings())
    val settings: StateFlow<MixSettings> = _settings.asStateFlow()

    init {
        scope.launch { settingsFlow.collect { _settings.value = it } }
    }

    // ---- first composition / settings pushes -------------------------------------------------

    /**
     * iOS `MixView.task` + the `.onChange(settings.*)` pushes. Warms the engine, pushes the four
     * settings, THEN materializes a launch-parked restore (so restored decks honour the prefs),
     * and afterwards pushes each changed setting immediately. Suspends for the screen's lifetime.
     */
    suspend fun run() {
        engine.prepare()
        var prev = settingsFlow.first()
        MixSettingsPush.pushAll(prev, engine)
        engine.materializePendingRestore()
        settingsFlow.collect { s ->
            if (s != prev) {
                MixSettingsPush.pushChanges(prev, s, engine)
                prev = s
            }
        }
    }

    // ---- crate selection funnels --------------------------------------------------------------

    fun setAutoSource(s: MixSource?) {
        if (s == null || s == _state.value.autoSource) return
        _state.update { it.copy(autoSource = s) }
        syncDeckSourcesToAuto()
        beginDownload(s)
    }

    /** null ⇒ "Same as Crate A". */
    fun setAutoSourceB(s: MixSource?) {
        if (s == _state.value.autoSourceB) return
        _state.update { it.copy(autoSourceB = s) }
        syncDeckSourcesToAuto()
        beginDownload(_state.value.autoSource)
    }

    fun setAutoEnabled(on: Boolean) {
        engine.autoEnabled = on
        _state.update { it.copy(autoEnabled = on) }
        syncDeckSourcesToAuto()
    }

    fun setSourceA(s: MixSource?) {
        if (s == _state.value.sourceA) return
        _state.update { it.copy(sourceA = s) }
        beginDownload(s)
    }

    fun setSourceB(s: MixSource?) {
        if (s == _state.value.sourceB) return
        _state.update { it.copy(sourceB = s) }
        beginDownload(s)
    }

    fun setSource(deck: Deck, s: MixSource?) = if (deck == Deck.A) setSourceA(s) else setSourceB(s)

    fun openLoader(deck: Deck) = _state.update { it.copy(loaderDeck = deck) }
    fun closeLoader() = _state.update { it.copy(loaderDeck = null) }

    /**
     * With Auto on + a crate chosen, mirror it onto BOTH decks' load source so hand-loading more
     * tracks during a Pause needs no per-deck source picking. Only mirrors while Auto is enabled.
     */
    fun syncDeckSourcesToAuto() {
        val st = _state.value
        val s = st.autoSource ?: return
        if (!st.autoEnabled) return
        setSourceA(s)
        setSourceB(st.autoCrateB ?: s)
    }

    /** Kick the download pipeline for a freshly-picked crate (nil-safe funnel). */
    fun beginDownload(source: MixSource?) {
        if (source == null) return
        val st = _state.value
        // Auto with two crates: ALWAYS the union set, from every funnel (a single-source begin
        // would cancel the union run).
        if (st.autoEnabled && st.autoCrateB != null) { downloads.begin(st.autoDownloadSources); return }
        downloads.begin(listOf(source))
    }

    // ---- auto start / transport ---------------------------------------------------------------

    fun startAuto(shuffled: Boolean) {
        val src = _state.value.autoSource ?: return
        _state.update { it.copy(autoStartError = null) }
        val b = _state.value.autoCrateB
        // Decks browse the auto crates (for hand-loading on Pause).
        setSourceA(src); setSourceB(b ?: src)
        scope.launch {
            try {
                starter.start(src, b, shuffled, allowPendingStart = true, settings = settingsFlow.first())
            } catch (e: NoLoadableSongsException) {
                _state.update { it.copy(autoStartError = e.message) }
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                _state.update { it.copy(autoStartError = "Those crates can’t start a mix right now.") }
            }
        }
    }

    /** [taps] 1 = skip fade from Settings, 2 = fast 5 s sweep. */
    fun skip(taps: Int) = engine.skipToNext(SkipGesture.fadeSeconds(taps, _settings.value.skipFadeSeconds))

    fun pauseAuto() = engine.pauseAuto()
    fun resumeAuto() = engine.resumeAuto()
    fun stopAuto() = engine.stopAutoMix()
    fun setFXGlide(on: Boolean) = engine.setFXGlide(on)
    fun setMixGlide(on: Boolean) = engine.setMixGlide(on)

    fun loadables(source: MixSource?): List<MixLoadable> = source?.let { crates.loadables(it) }.orEmpty()
    fun crateName(source: MixSource?): String? = source?.let { crates.name(it) }

    // ---- leave --------------------------------------------------------------------------------

    /**
     * Screen DISPOSED (tab left). Cancels the download run ONLY when no mix is live; a live mix
     * (auto or manual decks) keeps its downloads feeding the queue. Touches ONLY the downloader:
     * the engine's no-teardown-on-leave rule stands.
     */
    fun handleMixLeave() = downloads.handleMixLeave(engine.autoMixing || engine.isRunning)
}
