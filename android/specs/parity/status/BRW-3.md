state: merged

BRW-3 Explicit/edition system.
- [x] IndexModels: url fields, edition ids, dateAdded, IndexArtist + IndexJson.artists, IndexSong.appleMusicId(edition)
- [x] SongVariant, EditionPolicy, CleanOnly, EditionSettings (tri-state string pref)
- [x] EditionSection registered via BrowseGraph.settingsSections (order 450)
- [x] PlayResolver.resolveForEdition (edition pick before resolve)
- [x] Tests: EditionPolicyTest (15), IndexModelsAdditiveFieldsTest (5), PlayResolverEditionTest (4)

Notes: PlaybackController is not wired to resolveForEdition (not an owned file); hook is ready for it.
Tests added: 24. Total after: 650.

## Review
fixes applied
- MAJOR resolveForEdition global-pref/nothing-stored: fixed (RipRequired for the wanted variant id; test globalExplicit_nothingStored_ripsExplicitVariantNotPrimary)
- MINOR double enqueue: fixed (lazyRipId null when action is already RipRequired(wanted); only set when degrading onto a non-wanted stored file)
- MINOR base normalization: fixed (unchanged and fallback paths use base; test variantIdPassedIn_unchangedPathUsesBase)
- MINOR PlaybackController not wired / ledger: PARTIAL. PlaybackController wiring is owned by a follow-up playback package; resolveForEdition is the ready hook, and the emulator step cannot pass until it lands.
- MINOR test file ownership: fixed (PlayResolverEditionTest moved to its own file)
- NIT caption flicker: rejected/deferred (cosmetic, first-frame only)
- NIT IndexArtist leniency: fixed via IndexArtist.valid helper (join builders should filter on it)
Tests: 652 total, 0 failures (650 + 2 new).
