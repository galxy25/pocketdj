package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.browse.Genre
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

// The "Create pocket" pipeline (iOS PocketBuilder.swift), Android shape:
//   1. PARSE   brief -> structured filters (deterministic grammar; Gemini Nano when the device has it)
//   2. SEARCH  pure candidate search over the whole catalog: EXACT year range, FUZZY genre (substring or
//              Genre.category star-map), mood TOKEN OVERLAP against each song's sentiment keywords
//   3. CURATE  pick + order candidates, name the pocket (deterministic; Nano may do it)
//   4. FIT     validate ids, fit to the minute budget, persist via CollectionsStore.createPocket
// 2 and 4 are pure; the model steps hide behind [PocketBriefModel] so tests stub them and no ML Kit class is ever
// a hard dependency.

/** One catalog song, compacted for scoring + the model's candidate rows. */
data class PocketCandidate(
    val id: String,
    val title: String,
    val artist: String,
    val genre: String?,
    val year: Int?,
    val lengthMs: Long?,
    val moods: List<String>,
)

/** The curation: a pocket name + chosen song ids in play order. */
data class PocketPlan(val name: String, val songIds: List<String>)

/** The two model calls. [DeterministicPocketBriefModel] is always available; a Nano-backed one is optional. */
interface PocketBriefModel {
    suspend fun parse(brief: String, vocab: PocketVocabulary): ParsedPocketBrief
    suspend fun curate(brief: String, candidates: List<PocketCandidate>, maxSongs: Int): PocketPlan
}

/** Supplies an on-device LLM when (and only when) it is usable right now; null on every other device. */
fun interface PocketNanoProvider {
    suspend fun model(): PocketBriefModel?
}

/** A catalog snapshot, decoupled from MergedCatalog so tests build one in a line. */
class PocketCatalog(val songs: List<IndexSong>, val albumsById: Map<String, IndexAlbum>)

// ---- step 2 -----------------------------------------------------------------------------------------

object PocketCandidateSearch {
    const val MISMATCH = -1.0
    const val DEFAULT_LIMIT = 150

    /** Rank the catalog against the brief; exclusions: exact year range (unknown year = out), genre mismatch. */
    fun candidates(
        catalog: PocketCatalog,
        brief: ParsedPocketBrief,
        limit: Int = DEFAULT_LIMIT,
    ): List<PocketCandidate> {
        class Scored(val candidate: PocketCandidate, val score: Double, val order: Int)
        val scored = ArrayList<Scored>()
        val moods = brief.moods.map { it.lowercase(Locale.ROOT) }
        val yearsGiven = brief.yearFrom != null || brief.yearTo != null
        catalog.songs.forEachIndexed { i, song ->
            val album = song.albumId?.let { catalog.albumsById[it] }
            val year = song.year ?: album?.year
            if (yearsGiven) {
                if (year == null || year < (brief.yearFrom ?: Int.MIN_VALUE) || year > (brief.yearTo ?: Int.MAX_VALUE)) return@forEachIndexed
            }
            val genre = album?.genre
            val genreScore = genreScore(genre, brief.genres)
            if (genreScore == MISMATCH) return@forEachIndexed
            val keywords = song.sentimentKeywords.orEmpty()
            val moodScore = moodScore(keywords, moods)
            // Mood-only brief: a song with no mood evidence is not a match.
            if (moods.isNotEmpty() && brief.genres.isEmpty() && !yearsGiven && moodScore <= 0.0) return@forEachIndexed
            val score = 2 * moodScore + genreScore
            scored += Scored(
                PocketCandidate(song.id, song.name, song.artist, genre, year, song.length, keywords),
                score,
                i,
            )
        }
        return scored
            .sortedWith(compareByDescending<Scored> { it.score }.thenBy { it.order })
            .take(limit)
            .map { it.candidate }
    }

    /**
     * 1.0 substring hit (either direction, separators normalised), 0.5 same star-map category, [MISMATCH] when the
     * brief names genres and none match. No brief genres: neutral 0 (mood / year carry the search).
     */
    fun genreScore(genre: String?, briefGenres: List<String>): Double {
        if (briefGenres.isEmpty()) return 0.0
        val g = genre?.let(PocketBriefParser::normalize).orEmpty()
        if (g.isEmpty()) return MISMATCH
        var best = MISMATCH
        for (wantedRaw in briefGenres) {
            val wanted = PocketBriefParser.normalize(wantedRaw)
            if (wanted.isEmpty()) continue
            if (g.contains(wanted) || wanted.contains(g)) return 1.0
            val cat = Genre.category(g)
            if (cat != Genre.OTHER && cat == Genre.category(wanted)) best = maxOf(best, 0.5)
        }
        return best
    }

    /** Mood relevance: per brief mood the BEST keyword overlap, averaged. No moods or no keywords: 0. */
    fun moodScore(keywords: List<String>, briefMoods: List<String>): Double {
        if (briefMoods.isEmpty() || keywords.isEmpty()) return 0.0
        val kws = keywords.map { it.lowercase(Locale.ROOT).trim() }
        var total = 0.0
        for (mood in briefMoods) total += kws.maxOf { tokenSimilarity(it, mood) }
        return total / briefMoods.size
    }

    /** exact 1.0, substring 0.7, shared 5-char stem 0.5 ("optimism" ~ "optimistic"), else 0. */
    fun tokenSimilarity(keyword: String, mood: String): Double = when {
        keyword == mood -> 1.0
        keyword.contains(mood) || mood.contains(keyword) -> 0.7
        keyword.length >= 5 && mood.length >= 5 && keyword.take(5) == mood.take(5) -> 0.5
        else -> 0.0
    }
}

// ---- deterministic model ----------------------------------------------------------------------------

/** No-LLM implementation of both model steps; the path every device has. */
class DeterministicPocketBriefModel(private val maxPerArtist: Int = 3) : PocketBriefModel {
    override suspend fun parse(brief: String, vocab: PocketVocabulary) = PocketBriefParser.parse(brief, vocab)

    /** Ranked order kept, at most [maxPerArtist] per artist so one band can't be the whole pocket. */
    override suspend fun curate(brief: String, candidates: List<PocketCandidate>, maxSongs: Int): PocketPlan {
        val perArtist = HashMap<String, Int>()
        val picked = ArrayList<String>()
        for (c in candidates) {
            if (picked.size >= maxSongs) break
            val key = c.artist.lowercase(Locale.ROOT)
            val n = perArtist.getOrDefault(key, 0)
            if (n >= maxPerArtist) continue
            perArtist[key] = n + 1
            picked += c.id
        }
        // Too few distinct artists to fill: top up with the skipped ones rather than return a thin pocket.
        if (picked.size < maxSongs) {
            val have = picked.toHashSet()
            for (c in candidates) { if (picked.size >= maxSongs) break; if (have.add(c.id)) picked += c.id }
        }
        return PocketPlan(nameFor(brief), picked)
    }

    companion object {
        private val LEAD_RE = Regex(
            """^\s*(?:please\s+)?(?:(?:create|make|build|give)\s+(?:me\s+)?)?(?:a\s+|an\s+|the\s+)?(?:new\s+)?(?:pocket|playlist)?\s*(?:of|with|for|called|named|from)?\s*""",
            RegexOption.IGNORE_CASE,
        )
        private val TAIL_RE = Regex("""\s+(?:songs|tracks|music)\s*$""", RegexOption.IGNORE_CASE)

        /** "Create a pocket of 90s chill hip hop" -> "90s Chill Hip Hop". Never blank. */
        fun nameFor(brief: String): String {
            var s = brief.trim().replaceFirst(LEAD_RE, "").replace(TAIL_RE, "").trim().trim('.', '!', '?', '"', '“', '”')
            if (s.isEmpty()) s = brief.trim()
            if (s.isEmpty()) return "New Pocket"
            val titled = s.split(Regex("\\s+")).joinToString(" ") { w ->
                if ('&' in w) w.uppercase(Locale.ROOT)
                else if (w.length > 1 && w.all { it.isLetterOrDigit() && it.isUpperCase() || it.isDigit() }) w
                else w.replaceFirstChar { it.titlecase(Locale.ROOT) }
            }
            return if (titled.length > 48) titled.take(47).trimEnd() + "…" else titled
        }
    }
}

// ---- the async build service ------------------------------------------------------------------------

/**
 * Runs the pipeline off the caller's critical path ([kickOff] returns at once; the pocket appears in Collections
 * when the build lands). [phase] drives the Collections-tab banner. App-scoped.
 */
class PocketBuilderService(
    private val scope: CoroutineScope,
    /** The catalog to search; null = not loaded (the build fails with an honest line). */
    private val catalog: suspend () -> PocketCatalog?,
    /** Persist the pocket (CollectionsStore.createPocket): returns its id. */
    private val persist: (name: String, songIds: List<String>, description: String) -> String,
    private val nano: PocketNanoProvider = PocketNanoProvider { null },
    private val deterministic: PocketBriefModel = DeterministicPocketBriefModel(),
    private val compute: CoroutineDispatcher = Dispatchers.Default,
) {
    sealed interface Phase {
        data object Idle : Phase
        data class Building(val brief: String) : Phase
        data class Done(val pocketId: String, val name: String, val songCount: Int, val minutes: Int) : Phase
        data class Failed(val message: String) : Phase
    }

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase

    /** Dismiss a terminal phase (the banner's OK / x). Building is not dismissable. */
    fun acknowledge() {
        if (_phase.value is Phase.Building) return
        _phase.value = Phase.Idle
    }

    /** @return the build job, or null when one is already running (one build at a time). */
    fun kickOff(brief: String, targetMinutes: Int = PocketFitter.DEFAULT_MINUTES): Job? {
        if (!claim(brief)) return null
        return scope.launch { execute(brief, targetMinutes) }
    }

    /** Test / direct entry: the full pipeline, result on [phase]. */
    suspend fun build(brief: String, targetMinutes: Int = PocketFitter.DEFAULT_MINUTES) {
        if (!claim(brief)) return
        execute(brief, targetMinutes)
    }

    private fun claim(brief: String): Boolean {
        if (_phase.value is Phase.Building) return false
        _phase.value = Phase.Building(brief.trim())
        return true
    }

    private suspend fun execute(rawBrief: String, targetMinutes: Int) {
        val brief = rawBrief.trim()
        try {
            if (brief.isEmpty()) {
                _phase.value = Phase.Failed("Describe the pocket you want, like “90s chill hip hop”.")
                return
            }
            val snapshot = catalog()
            if (snapshot == null || snapshot.songs.isEmpty()) {
                _phase.value = Phase.Failed("Your library isn't loaded yet. Try again in a moment.")
                return
            }
            val vocab = withContext(compute) { vocabularyOf(snapshot) }

            var model: PocketBriefModel = nano.runCatchingModel() ?: deterministic
            var parsed = parseWith(model, brief, vocab) ?: run { model = deterministic; deterministic.parse(brief, vocab) }
            if (parsed.isEmptyFilter() && model !== deterministic) {
                model = deterministic
                parsed = deterministic.parse(brief, vocab)
            }
            if (parsed.isEmptyFilter()) {
                _phase.value = Phase.Failed("I couldn't tell what kind of music you meant. Try a mood, genre or decade.")
                return
            }
            val minutes = (parsed.minutes ?: targetMinutes).coerceIn(5, 600)

            var candidates = withContext(compute) { PocketCandidateSearch.candidates(snapshot, parsed) }
            if (candidates.isEmpty() && model !== deterministic) {
                // The LLM's reading matched nothing: fall back to the grammar before giving up.
                model = deterministic
                parsed = deterministic.parse(brief, vocab)
                candidates = withContext(compute) { PocketCandidateSearch.candidates(snapshot, parsed) }
            }
            if (candidates.isEmpty()) {
                _phase.value = Phase.Failed("No songs in your library match “$brief”.")
                return
            }

            val maxSongs = maxOf(40, minutes / 2 + 10) // generous: the fitter trims to the budget
            val plan = try {
                model.curate(brief, candidates, maxSongs)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                deterministic.curate(brief, candidates, maxSongs)
            }

            val fitted = validateAndFit(plan.songIds, candidates, minutes)
            if (fitted.isEmpty()) {
                _phase.value = Phase.Failed("Couldn't pick usable songs for “$brief”.")
                return
            }
            val name = plan.name.trim().ifEmpty { DeterministicPocketBriefModel.nameFor(brief) }
            val id = persist(name, fitted, "Created from: “$brief”")
            val byId = candidates.associateBy { it.id }
            val totalMs = fitted.sumOf { byId[it]?.lengthMs?.takeIf { l -> l > 0 } ?: PocketFitter.FALLBACK_LENGTH_MS }
            _phase.value = Phase.Done(id, name, fitted.size, (totalMs / 60_000L).toInt())
        } catch (e: CancellationException) {
            _phase.value = Phase.Idle
            throw e
        } catch (e: Exception) {
            _phase.value = Phase.Failed(e.message ?: "Couldn't build that pocket.")
        }
    }

    private fun ParsedPocketBrief.isEmptyFilter() =
        genres.isEmpty() && moods.isEmpty() && yearFrom == null && yearTo == null

    private suspend fun PocketNanoProvider.runCatchingModel(): PocketBriefModel? =
        try { model() } catch (e: CancellationException) { throw e } catch (_: Throwable) { null }

    private suspend fun parseWith(m: PocketBriefModel, brief: String, vocab: PocketVocabulary): ParsedPocketBrief? =
        try { m.parse(brief, vocab) } catch (e: CancellationException) { throw e } catch (_: Throwable) { null }

    companion object {
        /** Only ids the model was actually shown count; order-preserving dedup; then the minute fit. */
        fun validateAndFit(ids: List<String>, candidates: List<PocketCandidate>, minutes: Int): List<String> {
            val byId = candidates.associateBy { it.id }
            val seen = HashSet<String>()
            val valid = ids.filter { byId.containsKey(it) && seen.add(it) }
            return PocketFitter.fit(valid, { byId[it]?.lengthMs }, PocketFitter.budgetMs(minutes))
        }

        /** The catalog's own genre + sentiment strings: the parser's open vocabulary. */
        fun vocabularyOf(c: PocketCatalog): PocketVocabulary {
            val genres = HashSet<String>()
            c.albumsById.values.forEach { a -> a.genre?.takeIf { it.isNotBlank() }?.let { genres += it } }
            val moods = HashSet<String>()
            c.songs.forEach { s -> s.sentimentKeywords?.forEach { k -> if (k.isNotBlank() && ' ' !in k.trim()) moods += k } }
            return PocketVocabulary(genres, moods)
        }
    }
}

/** "Open the Create pocket sheet" requests from doors that route to the Collections tab (shortcut, empty brief). */
object CreatePocketRequests {
    private val _open = MutableStateFlow(false)
    val open: StateFlow<Boolean> = _open
    fun request() { _open.value = true }
    fun consume() { _open.value = false }
}
