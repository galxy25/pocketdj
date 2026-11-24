state: implemented

# P2-SURF-11 status: Create a pocket from a spoken/typed brief
- [x] PocketBriefParser: years, ranges, 2-digit range end, decades (90s / '90s / nineties), early/mid/late, length ("45 minute", "2 hours"), catalog + Genre-table genres (ambiguous words stay moods), built-in mood words + synonyms + catalog sentiment vocabulary
- [x] PocketCandidateSearch (exact years, fuzzy genre via substring / Genre.category, mood token overlap), PocketFitter (greedy minute fit, default 90), DeterministicPocketBriefModel (artist cap), PocketBuilderService (async, Phase flow, one build at a time, validates ids + fits before CollectionsStore.createPocket, falls back to the grammar if the optional model throws / matches nothing)
- [x] Doors: in-app CreatePocketSheet (typed or dictated via RecognizerIntent, length chips) + Collections banner; `pocketdj://create-pocket[?brief=]` (no brief opens the sheet); static launcher shortcut "Create pocket" (STATIC_COUNT 5); App Actions capability CREATE_POCKET (best-effort); ShellActions.createPocket (veto + ensureReady)
- [x] Tests: PocketBuilderTest (25). Full run: 7680 tests, 0 failures; testDebugUnitTest + assembleDebug + assembleRelease green.

## Files touched outside owned list
- shell/ShellActions.kt (pocketBuilder field, createPocket, createPocketLinkSeam), shell/DeepLinkDispatcher.kt (createPocket seam + CreatePocket case), di/ShellGraph.kt (pocketBuilder + wiring), assistant/ShortcutsPublisher.kt (STATIC_COUNT 4 -> 5), screens/playlists/PlaylistsScreen.kt (toolbar button, sheet, banner), res/values/shortcut_strings.xml.

## Deviations / notes
- Gemini Nano: NOT linked. The ML Kit GenAI Prompt API artifact is not in the offline Gradle cache and I will not add an unverified dependency to a live Play build. The seam is complete (`PocketNanoProvider` -> `PocketBriefModel`, with automatic fallback to the grammar); ShellGraph passes none, so every device uses the deterministic path today. Device-only follow-up: add `com.google.mlkit:genai-prompt` at an exact pinned version + an availability-gated provider.
- Mood similarity is token overlap + stem (iOS's NLEmbedding fallback), no vectors.
- App Actions: query patterns bind `$brief` to the free text; unverified on a device.
- Emulator step not run (emulator is the integrator's).

## Questions for Levi
- Add the ML Kit GenAI Prompt (Gemini Nano) dependency now (which exact version to pin) or keep the deterministic-only path until a Pixel 9+ can verify it?
