package com.levi.pocketdj.onboarding

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** The three zero-to-hero stages (raw values are the iOS `Stage` ints, persisted in the marker). */
enum class OnboardingStage(val raw: Int) {
    Profile(0), AppleMusic(1), Sources(2);

    companion object {
        fun fromRaw(raw: Int?): OnboardingStage? = entries.firstOrNull { it.raw == raw }
    }
}

/** The explicit persisted state (iOS `OnboardingStore.Marker`). */
sealed interface OnboardingMarker {
    data object Pending : OnboardingMarker
    data class Started(val stage: OnboardingStage) : OnboardingMarker
    data object Completed : OnboardingMarker
}

/** What launch does with the flow (iOS `OnboardingStore.Decision`). */
sealed interface OnboardingDecision {
    data object Skip : OnboardingDecision
    data object SkipAndStamp : OnboardingDecision
    data class Show(val stage: OnboardingStage) : OnboardingDecision
}

/** Where the marker JSON lives (DataStore key `pdj.onboarding.v1`). null/blank ⇒ absent. */
interface OnboardingMarkerStorage {
    suspend fun read(): String?
    suspend fun write(json: String)
}

/**
 * The iOS `MarkerFile` JSON: `{"version":1,"state":"started","stage":1}`. Decoding tolerates
 * unknown keys and a missing `stage` / `completedAtMs`; encoding omits nils like Swift Codable.
 */
object OnboardingMarkerCodec {
    @Serializable
    private data class MarkerFile(
        val version: Int = 1,
        val state: String = "",
        val stage: Int? = null,
        val completedAtMs: Double? = null,
    )

    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
        isLenient = true
    }

    fun decode(raw: String?): OnboardingMarker? {
        if (raw.isNullOrBlank()) return null
        val file = runCatching { json.decodeFromString<MarkerFile>(raw) }.getOrNull() ?: return null
        return when (file.state) {
            "pending" -> OnboardingMarker.Pending
            "completed" -> OnboardingMarker.Completed
            "started" -> OnboardingMarker.Started(OnboardingStage.fromRaw(file.stage) ?: OnboardingStage.Profile)
            else -> null
        }
    }

    fun encode(marker: OnboardingMarker, nowMs: Long = System.currentTimeMillis()): String {
        val file = when (marker) {
            OnboardingMarker.Pending -> MarkerFile(1, "pending")
            is OnboardingMarker.Started -> MarkerFile(1, "started", marker.stage.raw)
            OnboardingMarker.Completed -> MarkerFile(1, "completed", completedAtMs = nowMs.toDouble())
        }
        return json.encodeToString(MarkerFile.serializer(), file)
    }
}

/** Thrown by [OnboardingStore.vetoIfIncomplete]: a mutating intent arrived mid-onboarding. */
class OnboardingIncompleteException :
    IllegalStateException("Finish setting up PocketDJ first")

/**
 * The ZERO-TO-HERO first-run flow's state machine (port of iOS `OnboardingStore`).
 *
 * The decision is made ONCE at load from an explicit persisted marker — never inferred from
 * the settings file alone (see [decide]). Until the marker has been read the store reports
 * `loaded = false, complete = false`: the veto stays closed and [waitUntilComplete] waits.
 *
 * LAUNCH GATING: the launch pipeline (catalog load, rips manifest, jukebox bootstrap, future
 * sync push) awaits [waitUntilComplete]; the shell renders the flow instead of the app while
 * incomplete, so no screen-driven load starts either.
 *
 * [hadPersistedSettings] MUST be captured before anything writes the settings file.
 */
class OnboardingStore(
    private val storage: OnboardingMarkerStorage,
    private val hadPersistedSettings: Boolean,
    scope: CoroutineScope,
    private val environment: Map<String, String> = emptyMap(),
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    data class State(
        val loaded: Boolean = false,
        val complete: Boolean = false,
        val stage: OnboardingStage = OnboardingStage.Profile,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    /** Fired once when the user finishes the last stage (the app wires the catalog load). */
    @Volatile var onComplete: (() -> Unit)? = null

    val isComplete: Boolean get() = _state.value.let { it.loaded && it.complete }

    private var completion = CompletableDeferred<Unit>()
    private var forced = false
    private val lock = Any()

    // Marker writes are applied strictly in submission order.
    private val writes = Channel<OnboardingMarker>(Channel.UNLIMITED)

    init {
        scope.launch {
            for (marker in writes) runCatching { storage.write(OnboardingMarkerCodec.encode(marker, nowMs())) }
        }
        scope.launch { load() }
    }

    private suspend fun load() {
        val marker = runCatching { OnboardingMarkerCodec.decode(storage.read()) }.getOrNull()
        synchronized(lock) {
            apply(decide(marker, hadPersistedSettings, effectiveEnv()))
        }
    }

    private fun effectiveEnv(): Map<String, String> =
        if (forced) environment + (SHOW_ENV to "1") else environment

    private fun apply(decision: OnboardingDecision) {
        when (decision) {
            OnboardingDecision.Skip -> finishLoaded(complete = true)
            OnboardingDecision.SkipAndStamp -> {
                writes.trySend(OnboardingMarker.Completed)
                finishLoaded(complete = true)
            }
            is OnboardingDecision.Show -> {
                // Stamp `started` the moment the flow first presents so a force-quit resumes HERE.
                writes.trySend(OnboardingMarker.Started(decision.stage))
                if (completion.isCompleted) completion = CompletableDeferred()
                _state.value = State(loaded = true, complete = false, stage = decision.stage)
            }
        }
    }

    private fun finishLoaded(complete: Boolean) {
        _state.value = State(loaded = true, complete = complete, stage = _state.value.stage)
        if (complete) completion.complete(Unit)
    }

    /**
     * Debug/emulator seam (`pdj.showOnboarding` intent extra): show the flow at stage Profile
     * even on an existing install. Safe to call before or after the marker has loaded.
     */
    fun forceShow() {
        synchronized(lock) {
            forced = true
            if (_state.value.loaded) apply(OnboardingDecision.Show(OnboardingStage.Profile))
        }
    }

    /** Move to the next stage, or finish after the last. Persists so a force-quit resumes here. */
    fun advance() {
        synchronized(lock) {
            val s = _state.value
            if (!s.loaded || s.complete) return
            val next = OnboardingStage.fromRaw(s.stage.raw + 1)
            if (next != null) {
                _state.value = s.copy(stage = next)
                writes.trySend(OnboardingMarker.Started(next))
            } else {
                completeLocked()
            }
        }
    }

    /** Step back one stage (never past the first). */
    fun back() {
        synchronized(lock) {
            val s = _state.value
            if (!s.loaded || s.complete) return
            val prev = OnboardingStage.fromRaw(s.stage.raw - 1) ?: return
            _state.value = s.copy(stage = prev)
            writes.trySend(OnboardingMarker.Started(prev))
        }
    }

    /** Finish the flow: persist `completed`, release the launch pipeline, run the hook. */
    fun complete() {
        synchronized(lock) { completeLocked() }
    }

    private fun completeLocked() {
        val s = _state.value
        if (!s.loaded || s.complete) return
        _state.value = s.copy(complete = true)
        writes.trySend(OnboardingMarker.Completed)
        completion.complete(Unit)
        runCatching { onComplete?.invoke() }
    }

    /** Suspend until the flow completes (returns immediately when it never shows). */
    suspend fun waitUntilComplete() {
        while (true) {
            val d = synchronized(lock) { completion }
            d.await()
            if (isComplete) return
        }
    }

    /** Mutating-intent veto (iOS R4): throws while the flow is incomplete. */
    fun vetoIfIncomplete() {
        if (!isComplete) throw OnboardingIncompleteException()
    }

    /**
     * SET-1's Reset everything: write `pending` so the flow re-runs on the next launch even
     * though Settings is re-persisted afterwards. Live state is untouched (presentation is
     * launch-only).
     */
    fun forcePending() {
        writes.trySend(OnboardingMarker.Pending)
    }

    companion object {
        const val SHOW_ENV = "PDJ_SHOW_ONBOARDING"
        const val FIXTURE_ENV = "PDJ_USE_FIXTURE"
        const val SHOW_INTENT_EXTRA = "pdj.showOnboarding"

        /**
         * Pure decision tree. Order is load-bearing:
         * force-seam → fixture suppression → marker → upgrade-stamp → fresh.
         */
        fun decide(
            marker: OnboardingMarker?,
            hadPersistedSettings: Boolean,
            environment: Map<String, String>,
        ): OnboardingDecision {
            if (environment[SHOW_ENV] == "1") return OnboardingDecision.Show(OnboardingStage.Profile)
            if (environment[FIXTURE_ENV] != null) return OnboardingDecision.Skip
            return when (marker) {
                OnboardingMarker.Completed -> OnboardingDecision.Skip
                OnboardingMarker.Pending -> OnboardingDecision.Show(OnboardingStage.Profile)
                is OnboardingMarker.Started -> OnboardingDecision.Show(marker.stage)
                null -> if (hadPersistedSettings) OnboardingDecision.SkipAndStamp
                else OnboardingDecision.Show(OnboardingStage.Profile)
            }
        }

        /** Static reset hook (iOS `markPendingAfterReset(in:)`): write `pending` straight to storage. */
        suspend fun markPendingAfterReset(storage: OnboardingMarkerStorage) {
            storage.write(OnboardingMarkerCodec.encode(OnboardingMarker.Pending))
        }
    }
}
